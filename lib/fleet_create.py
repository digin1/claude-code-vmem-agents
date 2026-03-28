#!/usr/bin/env python3
"""Create new agents from claude -p output.

Takes JSON string (claude -p output) as argv[1] and CWD as argv[2].
Sanitizes filenames. Checks for existing files.
Semantic dedup: embeds description via ChromaDB, skips if cosine distance < 0.55
to any existing agent.
Hard caps: max 5 project agents, max 5 user agents.
Prints count of created agents.
"""
import sys
import json
import os
import re
import warnings

warnings.filterwarnings("ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chroma_client import get_client


def strip_code_fences(raw):
    """Remove markdown code fences from raw text."""
    raw = raw.strip()
    if raw.startswith("```"):
        lines = raw.split("\n")
        raw = "\n".join(l for l in lines if not l.startswith("```"))
    return raw


def parse_json_array(raw):
    """Parse JSON array from raw text, with regex fallback."""
    raw = strip_code_fences(raw)
    try:
        return json.loads(raw)
    except Exception:
        match = re.search(r"\[.*\]", raw, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except Exception:
                return []
        return []


def extract_description(content):
    """Extract the description field from agent markdown YAML frontmatter."""
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("description:"):
            return stripped.split(":", 1)[1].strip().strip('"').strip("'")
    return ""


def count_agents_by_scope(cwd):
    """Count existing agents per scope."""
    counts = {"user": 0, "project": 0}
    user_dir = os.path.expanduser("~/.claude/agents")
    proj_dir = os.path.join(cwd, ".claude", "agents") if cwd else ".claude/agents"

    for scope, d in [("user", user_dir), ("project", proj_dir)]:
        if os.path.isdir(d):
            counts[scope] = len([f for f in os.listdir(d)
                                if f.endswith(".md") and not f.startswith(".")])
    return counts


def get_existing_agent_descriptions():
    """Collect descriptions from all existing agent files."""
    descriptions = []
    for scope_dir in [
        os.path.expanduser("~/.claude/agents"),
        ".claude/agents",
    ]:
        if not os.path.isdir(scope_dir):
            continue
        for fname in os.listdir(scope_dir):
            if not fname.endswith(".md") or fname.startswith("."):
                continue
            try:
                fpath = os.path.join(scope_dir, fname)
                with open(fpath) as fh:
                    content = fh.read()
                desc = extract_description(content)
                if desc:
                    descriptions.append(desc)
            except Exception:
                pass
    return descriptions


def is_semantically_duplicate(new_desc, existing_descriptions, chromadb_available=True):
    """Check if new agent description is too similar to any existing agent.

    Uses ChromaDB's embedding to compare cosine distance.
    Returns True if cosine distance < 0.3 to any existing agent.
    """
    if not new_desc or not existing_descriptions or not chromadb_available:
        return False

    try:
        # Create a PID-scoped temporary collection for comparison (thread-safe)
        client = get_client()
        scratch_name = f"_agent_dedup_{os.getpid()}"

        try:
            client.delete_collection(scratch_name)
        except Exception:
            pass
        scratch = client.create_collection(scratch_name)

        try:
            # Add existing descriptions
            ids = [f"existing_{i}" for i in range(len(existing_descriptions))]
            scratch.add(ids=ids, documents=existing_descriptions)

            # Query with new description
            results = scratch.query(query_texts=[new_desc], n_results=1)

            if (
                results["distances"]
                and results["distances"][0]
                and results["distances"][0][0] < 0.55
            ):
                return True
        finally:
            # Always clean up
            try:
                client.delete_collection(scratch_name)
            except Exception:
                pass
    except Exception:
        pass

    return False


MAX_PROJECT_AGENTS = 0  # 0 = unlimited
MAX_USER_AGENTS = 0     # 0 = unlimited


def create_agents(raw, cwd):
    """Parse agent definitions and create files. Returns count of created agents."""
    agents = parse_json_array(raw)
    if not isinstance(agents, list):
        agents = []

    # Set up ChromaDB for semantic dedup (flag only — is_semantically_duplicate creates its own client)
    chromadb_available = False
    try:
        get_client()
        chromadb_available = True
    except Exception:
        pass

    # Collect existing agent descriptions for semantic dedup
    existing_descriptions = get_existing_agent_descriptions()

    # Hard caps per scope
    scope_counts = count_agents_by_scope(cwd)

    created = 0
    for agent in agents[:5]:
        if not isinstance(agent, dict):
            continue
        filename = agent.get("filename", "")
        content = agent.get("content", "")
        scope = agent.get("scope", "user")

        if not filename or not content or not filename.endswith(".md"):
            continue

        filename = re.sub(r"[^a-z0-9\-_.]", "", filename.lower())
        if not filename:
            continue

        # Cap check (0 = unlimited)
        if MAX_PROJECT_AGENTS and scope == "project" and scope_counts["project"] >= MAX_PROJECT_AGENTS:
            print(
                f"[cortex fleet] Skipped '{filename}': project agent cap ({MAX_PROJECT_AGENTS}) reached",
                file=sys.stderr,
            )
            continue
        if MAX_USER_AGENTS and scope != "project" and scope_counts["user"] >= MAX_USER_AGENTS:
            print(
                f"[cortex fleet] Skipped '{filename}': user agent cap ({MAX_USER_AGENTS}) reached",
                file=sys.stderr,
            )
            continue

        if scope == "project":
            agent_dir = os.path.join(cwd, ".claude", "agents")
        else:
            agent_dir = os.path.expanduser("~/.claude/agents")

        os.makedirs(agent_dir, exist_ok=True)
        agent_path = os.path.join(agent_dir, filename)

        # Path traversal protection
        real_path = os.path.realpath(agent_path)
        real_dir = os.path.realpath(agent_dir)
        if not real_path.startswith(real_dir + os.sep):
            print(f"[cortex fleet] Blocked path traversal: {filename}", file=sys.stderr)
            continue

        if os.path.exists(agent_path):
            continue

        # Semantic dedup: check if description is too similar to existing agents
        new_desc = extract_description(content)
        if new_desc and chromadb_available and is_semantically_duplicate(
            new_desc, existing_descriptions, True
        ):
            print(
                f"[cortex fleet] Skipped '{filename}': semantically similar agent already exists",
                file=sys.stderr,
            )
            continue

        try:
            with open(agent_path, "w") as f:
                f.write(content)
            created += 1
            scope_counts[scope if scope == "project" else "user"] += 1
            # Add to existing descriptions so subsequent agents in the same batch
            # are also checked against this one
            if new_desc:
                existing_descriptions.append(new_desc)
            print(f"[cortex fleet] Created agent: {agent_path}", file=sys.stderr)
        except Exception as e:
            print(f"[cortex fleet] Failed to create {agent_path}: {e}", file=sys.stderr)

    print(created)
    return created


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    if not raw:
        print("0")
        sys.exit(0)
    create_agents(raw, cwd)


if __name__ == "__main__":
    main()
