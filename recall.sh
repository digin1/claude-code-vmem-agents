#!/bin/bash
# Auto-recall: searches vector memory for context relevant to user's prompt
# Called by UserPromptSubmit hook — reads JSON from stdin
# Outputs JSON with additionalContext for silent injection into Claude's context
#
# Safety: process lock prevents concurrent instances, timeout prevents hangs

INPUT=$(cat)

# ── Process lock: only one recall instance at a time ──
LOCKFILE="/tmp/cortex-recall.lock"
exec 200>"$LOCKFILE" 2>/dev/null
if ! flock -n 200 2>/dev/null; then
    exit 0
fi

# ── Timeout: kill process group after 8 seconds (ensures Python child dies too) ──
( sleep 8; kill -- -$$ 2>/dev/null; kill $$ 2>/dev/null ) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null; exit 0' EXIT

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

raw = sys.argv[1] if len(sys.argv) > 1 else ""

# Parse hook input
try:
    d = json.loads(raw)
except:
    d = {}

user_prompt = d.get("prompt", "") or d.get("content", "") or raw
transcript_path = d.get("transcript_path", "")
cwd = d.get("cwd", "") or os.getcwd()

# Skip recall for automated claude -p subprocess prompts
_skip_patterns = [
    "you are a memory extraction system",
    "you identify reusable workflow patterns",
    "you evaluate and reconcile an existing fleet",
    "you are an agent architect",
    "summarize this session in one sentence",
    "extract learnings from this coding session",
    "analyze this coding session for skill",
    "analyze this coding session for specialized agent",
    "output a json array of memories",
    "output a json array of agents",
    "output only the json array",
]
_prompt_lower = user_prompt[:500].lower()
for _pat in _skip_patterns:
    if _pat in _prompt_lower:
        sys.exit(0)

# Skip very short or empty prompts
if len(user_prompt.strip()) < 5:
    sys.exit(0)

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

ACTIVITY_FILE = os.path.expanduser("~/.claude/.cortex_activity")

# Connect to ChromaDB
try:
    col = get_collection()
    if col.count() == 0:
        sys.exit(0)
except Exception:
    sys.exit(0)


# ================================================================
# Detect first message (no assistant replies in transcript yet)
# ================================================================
def is_first_message(transcript_path):
    if not transcript_path or not os.path.exists(transcript_path):
        return True
    try:
        with open(transcript_path, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                except:
                    continue
                msg = entry.get('message', entry)
                if msg.get('role') != 'assistant':
                    continue
                content = msg.get('content', '')
                if isinstance(content, str) and len(content) > 10:
                    return False
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get('type') == 'text':
                            if len(part.get('text', '')) > 10:
                                return False
    except:
        return True
    return True


# ================================================================
# Detect project from cwd
# ================================================================
def detect_project(cwd):
    """Derive project name(s) from cwd path components."""
    projects = set()
    parts = cwd.replace("\\", "/").split("/")
    for p in parts:
        if p and p not in ("home", "Users", "projects", "src", "work", "dev", "repos", "code", ".claude"):
            if len(p) > 2 and not p.startswith("."):
                projects.add(p)
    return projects


first_msg = is_first_message(transcript_path)
projects = detect_project(cwd)

# Remember keywords trigger more aggressive search
remember_kw = any(k in user_prompt.lower() for k in
    ["remember", "recall", "did we", "last time", "do you know", "previously", "earlier session"])


# ================================================================
# FIRST MESSAGE: comprehensive context load
# ================================================================
if first_msg:
    all_data = col.get(include=["documents", "metadatas"])
    results = []

    for i in range(len(all_data["ids"])):
        meta = all_data["metadatas"][i]
        mtype = meta.get("type", "general")
        proj = meta.get("project", "")

        # Skip agent evals and inventory memories (injected separately from filesystem)
        if mtype == "agent_eval":
            continue
        if all_data["ids"][i].startswith("inventory_"):
            continue

        # Always include: user, feedback, preferences (cross-project)
        if mtype in ("user", "feedback", "preferences"):
            results.append({"id": all_data["ids"][i], "type": mtype, "project": proj,
                           "content": all_data["documents"][i][:250]})
            continue

        # Include project memories if project matches
        if proj and any(proj.lower() in p.lower() or p.lower() in proj.lower() for p in projects):
            results.append({"id": all_data["ids"][i], "type": mtype, "project": proj,
                           "content": all_data["documents"][i][:250]})
            continue

        # Include global/untagged project and reference memories
        if not proj and mtype in ("project", "reference"):
            results.append({"id": all_data["ids"][i], "type": mtype, "project": proj,
                           "content": all_data["documents"][i][:250]})
            continue

        # Include all reference memories (they're high-value, few in number)
        if mtype == "reference":
            results.append({"id": all_data["ids"][i], "type": mtype, "project": proj,
                           "content": all_data["documents"][i][:250]})

    # Also do a semantic search for anything the above might have missed
    n_search = 10 if remember_kw else 5
    threshold = 0.8 if remember_kw else 0.65
    try:
        search = col.query(query_texts=[user_prompt[:400]], n_results=min(n_search, col.count()))
        existing_ids = {r["id"] for r in results}
        for i in range(len(search["ids"][0])):
            sid = search["ids"][0][i]
            if sid in existing_ids:
                continue
            dist = search["distances"][0][i] if search.get("distances") else 1.0
            if dist < threshold:
                meta = search["metadatas"][0][i]
                if meta.get("type") == "agent_eval":
                    continue
                if sid.startswith("inventory_"):
                    continue
                results.append({
                    "id": sid, "type": meta.get("type", "general"),
                    "project": meta.get("project", ""),
                    "content": search["documents"][0][i][:250],
                })
    except:
        pass

    # Track recalls — use log file (same as subsequent path) to avoid N+1 DB writes
    try:
        now = time.strftime("%Y-%m-%dT%H:%M:%S")
        recall_ids = [r["id"] for r in results]
        if recall_ids:
            with open(os.path.expanduser("~/.claude/.cortex_recall_log"), "a") as f:
                f.write(f"{now} {','.join(recall_ids)}\n")
    except:
        pass

    # ── Collect agent & skill inventory (first message only) ──
    import glob

    def scan_agents():
        """Scan agent .md files, extract name + description from frontmatter."""
        agents = []
        for scope, d in [("project", os.path.join(cwd, ".claude", "agents")),
                         ("global", os.path.expanduser("~/.claude/agents"))]:
            if not os.path.isdir(d):
                continue
            for f in sorted(glob.glob(os.path.join(d, "*.md"))):
                name = os.path.splitext(os.path.basename(f))[0]
                desc = ""
                try:
                    with open(f) as fh:
                        in_front = False
                        for line in fh:
                            line = line.strip()
                            if line == "---" and not in_front:
                                in_front = True
                                continue
                            if line == "---" and in_front:
                                break
                            if in_front and line.lower().startswith("description:"):
                                desc = line.split(":", 1)[1].strip().strip('"').strip("'")
                except Exception:
                    pass
                agents.append(f"  [{scope}] {name}: {desc[:120]}")
        return agents

    def scan_skills():
        """Scan skill .md files, extract description from frontmatter."""
        skills = []
        for scope, d in [("project", os.path.join(cwd, ".claude", "commands")),
                         ("global", os.path.expanduser("~/.claude/commands"))]:
            if not os.path.isdir(d):
                continue
            for f in sorted(glob.glob(os.path.join(d, "*.md"))):
                name = os.path.splitext(os.path.basename(f))[0]
                desc = ""
                try:
                    with open(f) as fh:
                        in_front = False
                        for line in fh:
                            line = line.strip()
                            if line == "---" and not in_front:
                                in_front = True
                                continue
                            if line == "---" and in_front:
                                break
                            if in_front and line.lower().startswith("description:"):
                                desc = line.split(":", 1)[1].strip().strip('"').strip("'")
                except Exception:
                    pass
                skills.append(f"  [{scope}] /{name}: {desc[:120]}")
        return skills

    def scan_cached_docs():
        """Scan ~/.claude/docs/ for cached documentation."""
        doc_root = os.path.expanduser("~/.claude/docs")
        if not os.path.isdir(doc_root):
            return []
        docs = []
        for fid in sorted(os.listdir(doc_root)):
            manifest_path = os.path.join(doc_root, fid, ".manifest.json")
            if not os.path.isfile(manifest_path):
                continue
            try:
                with open(manifest_path) as f:
                    m = json.load(f)
                count = m.get("file_count", "?")
                docs.append(f"  {fid}: {count} files at ~/.claude/docs/{fid}/")
            except Exception:
                docs.append(f"  {fid}: ~/.claude/docs/{fid}/")
        return docs

    agent_lines = scan_agents()
    skill_lines = scan_skills()
    doc_lines = scan_cached_docs()

    lines = []
    if results:
        lines.append("[cortex] Recalled memories:")
        for r in results:
            proj_tag = f" [{r['project']}]" if r.get("project") else ""
            lines.append(f"  [{r['type']}] {r['id']}{proj_tag}: {r['content']}")

    if agent_lines:
        lines.append("\n[cortex] Available agents (use via Agent tool with subagent_type):")
        lines.extend(agent_lines)

    if skill_lines:
        lines.append("\n[cortex] Available skills (use via /command or Skill tool):")
        lines.extend(skill_lines)

    if doc_lines:
        lines.append("\n[cortex] Cached documentation (read files directly for reference):")
        lines.extend(doc_lines)

    if lines:
        output = json.dumps({
            "hookSpecificOutput": {
                "additionalContext": "\n".join(lines)
            }
        })
        print(output)

# ================================================================
# SUBSEQUENT: targeted semantic search
# ================================================================
else:
    n_search = 8 if remember_kw else 5
    threshold = 0.85 if remember_kw else 0.75

    try:
        search = col.query(query_texts=[user_prompt[:400]], n_results=min(n_search, col.count()))
    except:
        sys.exit(0)

    results = []
    for i in range(len(search["ids"][0])):
        dist = search["distances"][0][i] if search.get("distances") else 1.0
        if dist < threshold:
            meta = search["metadatas"][0][i]
            if meta.get("type") == "agent_eval":
                continue
            sid = search["ids"][0][i]
            if sid.startswith("inventory_"):
                continue
            results.append({
                "id": sid,
                "type": meta.get("type", "general"),
                "project": meta.get("project", ""),
                "content": search["documents"][0][i][:200],
            })

    # Detect library mentions and check doc cache
    doc_hints = []
    doc_root = os.path.expanduser("~/.claude/docs")
    registry_path = os.path.expanduser("~/.claude/skills/cortex/lib/knowledge_registry.json")
    try:
        with open(registry_path) as f:
            _reg = json.load(f)
        prompt_lower = user_prompt.lower()
        for fid, entry in _reg.get("frameworks", {}).items():
            name = entry.get("name", "").lower()
            if name in prompt_lower or fid.replace("-", " ") in prompt_lower:
                doc_dir = os.path.join(doc_root, fid)
                if os.path.isdir(doc_dir) and os.path.isfile(os.path.join(doc_dir, ".manifest.json")):
                    doc_hints.append(f"  Read ~/.claude/docs/{fid}/ for {entry['name']} reference")
                else:
                    doc_hints.append(f"  {entry['name']}: not cached — use context7 query-docs tool")
    except Exception:
        pass

    lines = []
    if results:
        # Track recalls
        try:
            now = time.strftime("%Y-%m-%dT%H:%M:%S")
            recall_ids = [r["id"] for r in results]
            with open(os.path.expanduser("~/.claude/.cortex_recall_log"), "a") as f:
                f.write(f"{now} {','.join(recall_ids)}\n")
        except:
            pass

        lines.append("[cortex] Recalled memories relevant to this message:")
        for r in results:
            proj_tag = f" [{r['project']}]" if r.get("project") else ""
            lines.append(f"  [{r['type']}] {r['id']}{proj_tag}: {r['content']}")

    if doc_hints:
        lines.append("\n[cortex] Relevant documentation:")
        lines.extend(doc_hints)

    if lines:
        output = json.dumps({
            "hookSpecificOutput": {
                "additionalContext": "\n".join(lines)
            }
        })
        print(output)

PYEOF
