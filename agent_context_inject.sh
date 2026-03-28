#!/bin/bash
# SubagentStart hook: inject cortex context into agents when they spawn
# Uses claude -p --model haiku for query expansion (~2s) + ChromaDB search
# Returns additionalContext with domain-relevant memories

INPUT=$(cat)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    d = {}

agent_type = d.get("agent_type", "")
agent_prompt = d.get("prompt", "")
cwd = d.get("cwd", "") or os.getcwd()

# Skip general-purpose agents (too broad) and very short names
if not agent_type or agent_type in ("general-purpose", "Explore", "Plan"):
    sys.exit(0)

try:
    col = get_collection()
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

    # ── LLM query expansion via claude -p (DISABLED) ───────────────
    # BUG: claude -p returns empty stdout on v2.1.83.
    # Tracked: https://github.com/anthropics/claude-code/issues/38774
    # TODO: Re-enable when fixed.
    expanded_query = ""

    # ── Multi-query ChromaDB search ────────────────────────────────
    n_results = min(8, col.count())

    # Primary search: agent type + prompt excerpt
    primary_query = agent_type
    if agent_prompt:
        primary_query = f"{agent_type} {agent_prompt[:200]}"
    results = col.query(
        query_texts=[primary_query],
        n_results=n_results
    )

    # Secondary search: LLM-expanded keywords
    expanded_results = None
    if expanded_query:
        try:
            expanded_results = col.query(
                query_texts=[expanded_query],
                n_results=n_results
            )
        except Exception:
            pass

    # Merge results: keep best (lowest) distance per memory ID
    best = {}
    for src in [results, expanded_results]:
        if src is None:
            continue
        for i in range(len(src["ids"][0])):
            mid = src["ids"][0][i]
            dist = src["distances"][0][i] if src.get("distances") else 1.0
            if mid not in best or dist < best[mid][0]:
                best[mid] = (dist, i, src)

    relevant = []
    for mid, (dist, i, src) in best.items():
        meta = src["metadatas"][0][i]
        mtype = meta.get("type", "general")
        mproject = meta.get("project", "")

        if mtype == "agent_eval":
            continue

        # Tighter threshold for project-matching, normal for others
        threshold = 0.55 if mproject in matched_projects else 0.45
        if dist < threshold:
            relevant.append({
                "id": mid,
                "content": src["documents"][0][i][:400],
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
