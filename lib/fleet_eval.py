#!/usr/bin/env python3
"""Evaluate, update, and retire agents from claude -p output.

Takes JSON string (claude -p output) as argv[1] and CWD as argv[2].
Handles:
- Connect to ChromaDB (col=None guard)
- Persist evaluations as agent_eval type
- Update agents (with .bak backup, path validation)
- Retire agents (knowledge extraction to vmem, move to .retired/)
- Path traversal protection using os.path.realpath()
"""
import sys
import json
import os
import re
import time
import warnings

warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"

DB_PATH = os.path.expanduser("~/.claude/vector-memory-db")
ACTIVITY_FILE = os.path.expanduser("~/.claude/.vmem_activity")


def strip_code_fences(raw):
    """Remove markdown code fences from raw text."""
    raw = raw.strip()
    if raw.startswith("```"):
        lines = raw.split("\n")
        raw = "\n".join(l for l in lines if not l.startswith("```"))
    return raw


def parse_json_object(raw):
    """Parse JSON object from raw text, with regex fallback."""
    raw = strip_code_fences(raw)
    try:
        return json.loads(raw)
    except Exception:
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except Exception:
                return None
        return None


def get_allowed_dirs(cwd):
    """Return list of allowed agent directories (realpath'd)."""
    return [
        os.path.realpath(os.path.expanduser("~/.claude/agents")),
        os.path.realpath(os.path.join(cwd, ".claude", "agents")),
    ]


def is_path_allowed(path, cwd):
    """Check if path is within allowed agent directories using realpath."""
    real_path = os.path.realpath(path)
    allowed_dirs = get_allowed_dirs(cwd)
    return any(real_path.startswith(d + os.sep) for d in allowed_dirs)


def persist_evaluations(result, col, ts):
    """Store evaluation results in ChromaDB."""
    if col is None:
        return
    try:
        for ev in result.get("evaluations", []):
            if not isinstance(ev, dict):
                continue
            name = ev.get("name", "?")
            score = ev.get("score", 0)
            notes = ev.get("notes", "")
            usage = ev.get("usage_count", "?")

            eval_content = (
                f"Agent '{name}' eval: {score}/5 (usage: {usage}). {notes}"
            )
            eval_id = f"agent_eval_{name}_{ts[:10]}"

            col.upsert(
                ids=[eval_id],
                documents=[eval_content],
                metadatas={
                    "type": "agent_eval",
                    "timestamp": ts,
                    "tags": f"agent,eval,{name}",
                    "agent_name": name,
                    "score": str(score),
                    "source": "compact_save.sh",
                },
            )
            print(
                f"[vmem fleet] Eval {name}: {score}/5 (usage: {usage}) -- {notes}"
            )
    except Exception as e:
        print(f"[vmem fleet] Eval storage error: {e}")


def update_agents(result, cwd):
    """Update existing agents with backup."""
    updated = 0
    for agent in result.get("update", []):
        if not isinstance(agent, dict):
            continue
        path = agent.get("path", "")
        content = agent.get("content", "")
        reason = agent.get("reason", "")

        if not path or not content or not os.path.exists(path):
            continue

        if not is_path_allowed(path, cwd):
            print(
                f"[vmem fleet] Blocked update to path outside agent dirs: {path}"
            )
            continue

        backup_path = path + f".bak.{int(time.time())}"
        try:
            with open(path, "r") as f:
                old_content = f.read()
            if old_content.strip() == content.strip():
                continue
            with open(backup_path, "w") as f:
                f.write(old_content)
            with open(path, "w") as f:
                f.write(content)
            updated += 1
            print(f"[vmem fleet] Updated {os.path.basename(path)}: {reason}")
        except Exception as e:
            print(f"[vmem fleet] Failed to update {path}: {e}")
    return updated


def retire_agents(result, cwd, col, ts):
    """Retire agents with knowledge extraction to vmem."""
    retired = 0
    for agent in result.get("retire", []):
        if not isinstance(agent, dict):
            continue
        path = agent.get("path", "")
        reason = agent.get("reason", "")

        if not path or not os.path.exists(path):
            continue

        if not is_path_allowed(path, cwd):
            print(
                f"[vmem fleet] Blocked retire of path outside agent dirs: {path}"
            )
            continue

        # Extract knowledge from agent before retiring (only if vmem connected)
        if col is not None:
            try:
                with open(path, "r") as f:
                    agent_content = f.read()

                # Parse agent name from frontmatter
                agent_name = os.path.basename(path).replace(".md", "")
                for line in agent_content.split("\n"):
                    if line.strip().startswith("name:"):
                        agent_name = line.split(":", 1)[1].strip()
                        break

                # Extract the system prompt (everything after the closing ---)
                parts = agent_content.split("---", 2)
                system_prompt = (
                    parts[2].strip() if len(parts) >= 3 else agent_content
                )

                # Store the agent's accumulated knowledge in vmem
                knowledge_id = f"retired_agent_knowledge_{agent_name}"
                knowledge_content = f"Knowledge from retired agent '{agent_name}': {system_prompt[:1500]}"

                col.upsert(
                    ids=[knowledge_id],
                    documents=[knowledge_content],
                    metadatas={
                        "type": "reference",
                        "timestamp": ts,
                        "tags": f"agent,retired,knowledge,{agent_name}",
                        "source": "agent_retire",
                        "original_agent": agent_name,
                        "retire_reason": reason[:200],
                    },
                )
                print(
                    f"[vmem fleet] Preserved knowledge from '{agent_name}' before retiring"
                )
            except Exception as e:
                print(
                    f"[vmem fleet] Knowledge extraction failed for {path}: {e}"
                )

        # Move to .retired/
        retired_dir = os.path.join(os.path.dirname(path), ".retired")
        os.makedirs(retired_dir, exist_ok=True)
        retired_path = os.path.join(retired_dir, os.path.basename(path))
        try:
            os.rename(path, retired_path)
            retired += 1
            print(f"[vmem fleet] Retired {os.path.basename(path)}: {reason}")
        except Exception as e:
            print(f"[vmem fleet] Failed to retire {path}: {e}")
    return retired


def write_activity(result, updated, retired):
    """Write activity summary, appending to existing activity."""
    parts = []
    if updated:
        parts.append(f"~{updated}")
    if retired:
        parts.append(f"-{retired}")
    evals = len(result.get("evaluations", []))
    if evals:
        parts.append(f"eval:{evals}")

    if parts:
        existing = ""
        try:
            with open(ACTIVITY_FILE) as f:
                existing = f.read().strip()
        except Exception:
            pass

        activity = f"fleet: {' '.join(parts)}"
        if existing:
            activity = f"{existing} | {activity}"

        with open(ACTIVITY_FILE, "w") as af:
            af.write(activity)


def evaluate_fleet(raw, cwd):
    """Main evaluation pipeline."""
    result = parse_json_object(raw)
    if not isinstance(result, dict):
        return

    ts = time.strftime("%Y-%m-%dT%H:%M:%S")

    # Connect to ChromaDB (col=None guard)
    col = None
    try:
        import chromadb

        client = chromadb.PersistentClient(path=DB_PATH)
        col = client.get_or_create_collection("claude_memories")
    except Exception as e:
        print(f"[vmem fleet] ChromaDB connection failed: {e}")

    # Persist evaluations
    persist_evaluations(result, col, ts)

    # Update agents
    updated = update_agents(result, cwd)

    # Retire agents
    retired = retire_agents(result, cwd, col, ts)

    # Write activity summary
    write_activity(result, updated, retired)

    evals = len(result.get("evaluations", []))
    print(
        f"[vmem fleet] Reconciliation: {updated} updated, {retired} retired, {evals} evaluated"
    )


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    if not raw:
        sys.exit(0)
    evaluate_fleet(raw, cwd)


if __name__ == "__main__":
    main()
