#!/bin/bash
# CwdChanged hook: preload project memories when user changes directory
# Outputs additionalContext with project-specific memories for the new cwd

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings
warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["ONNXRUNTIME_SESSION_THREAD_POOL_SIZE"] = "2"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2)
os.close(_dn)
try:
    import onnxruntime
    onnxruntime.set_default_logger_severity(3)
except: pass
os.dup2(_fd, 2)
os.close(_fd)

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

new_cwd = d.get("cwd", "") or d.get("newCwd", "")
if not new_cwd or len(new_cwd) < 3:
    sys.exit(0)

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
try:
    from chroma_client import get_collection
    col = get_collection()
    if col.count() == 0:
        sys.exit(0)
except:
    sys.exit(0)

# Detect project from new cwd
all_data = col.get(include=["metadatas"])
known_projects = set()
for m in all_data["metadatas"]:
    p = m.get("project", "")
    if p and p != "global":
        known_projects.add(p)

cwd_lower = new_cwd.lower()
matched = [p for p in known_projects if p.lower() in cwd_lower]

if not matched:
    sys.exit(0)

# Fetch project-specific memories
project_mems = []
for i in range(len(all_data["ids"])):
    meta = all_data["metadatas"][i]
    if meta.get("project", "") in matched and meta.get("type", "") in ("project", "reference"):
        if meta.get("type") != "agent_eval":
            project_mems.append(all_data["ids"][i])

if not project_mems:
    sys.exit(0)

# Get full content for matched memories (max 10)
result = col.get(ids=project_mems[:10], include=["documents", "metadatas"])

lines = [f"[cortex] Switched to project: {', '.join(matched)} — preloaded context:"]
for i in range(len(result["ids"])):
    mid = result["ids"][i]
    doc = result["documents"][i][:200]
    mtype = result["metadatas"][i].get("type", "")
    lines.append(f"  [{mtype}] {mid}: {doc}")

if len(lines) > 1:
    output = json.dumps({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "CwdChanged",
            "additionalContext": "\n".join(lines)
        }
    })
    print(output)

PYEOF
