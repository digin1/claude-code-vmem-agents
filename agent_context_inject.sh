#!/bin/bash
# SubagentStart hook: inject cortex context into agents when they spawn
# Must be FAST (< 500ms) — pure ChromaDB query, no LLM calls
# Returns additionalContext with domain-relevant memories

INPUT=$(cat)

python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings
warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"

_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2); os.close(_dn)
try:
    import onnxruntime
    onnxruntime.set_default_logger_severity(3)
    import chromadb
finally:
    os.dup2(_fd, 2); os.close(_fd)

DB_PATH = os.path.expanduser("~/.claude/vector-memory-db")

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    d = {}

agent_type = d.get("agent_type", "")
cwd = d.get("cwd", "") or os.getcwd()

# Skip general-purpose agents (too broad) and very short names
if not agent_type or agent_type in ("general-purpose", "Explore", "Plan"):
    sys.exit(0)

try:
    client = chromadb.PersistentClient(path=DB_PATH)
    col = client.get_or_create_collection("claude_memories")
    if col.count() == 0:
        sys.exit(0)

    # Detect project from cwd
    all_data = col.get(include=["metadatas"])
    known_projects = set()
    for m in all_data["metadatas"]:
        p = m.get("project", "")
        if p and p != "global":
            known_projects.add(p)

    cwd_lower = cwd.lower()
    matched_projects = set()
    for proj in known_projects:
        if proj.lower() in cwd_lower:
            matched_projects.add(proj)

    # Semantic search: find memories relevant to this agent type
    results = col.query(
        query_texts=[agent_type],
        n_results=min(5, col.count())
    )

    relevant = []
    for i in range(len(results["ids"][0])):
        dist = results["distances"][0][i] if results.get("distances") else 1.0
        meta = results["metadatas"][0][i]
        mtype = meta.get("type", "general")
        mproject = meta.get("project", "")

        if mtype == "agent_eval":
            continue

        # Tighter threshold for project-matching, normal for others
        threshold = 0.55 if mproject in matched_projects else 0.45
        if dist < threshold:
            relevant.append({
                "id": results["ids"][0][i],
                "content": results["documents"][0][i][:400],
                "type": mtype,
            })

    # Also grab top 3 feedback memories (cross-project rules)
    feedback_data = col.get(
        where={"type": "feedback"},
        include=["documents", "metadatas"]
    )
    feedback_items = []
    for i in range(min(3, len(feedback_data["ids"]))):
        fid = feedback_data["ids"][i]
        # Don't duplicate if already in semantic results
        if fid not in {r["id"] for r in relevant}:
            feedback_items.append({
                "id": fid,
                "content": feedback_data["documents"][i][:300],
                "type": "feedback",
            })

    all_items = relevant + feedback_items

    if all_items:
        lines = [f"[cortex] Context for agent '{agent_type}':"]
        for item in all_items:
            lines.append(f"  [{item['type']}] {item['id']}: {item['content']}")

        context_text = '\n'.join(lines)
        output = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {
                "hookEventName": "SubagentStart",
                "additionalContext": context_text
            }
        })
        print(output)

except Exception:
    sys.exit(0)
PYEOF
