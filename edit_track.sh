#!/bin/bash
# PostToolUse hook for Edit/Write: track which files were modified this session
# Builds a session-level file list for compact_guide.sh and recall context

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

EDIT_LOG = os.path.expanduser("~/.claude/.cortex_edit_log")

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

tool_name = d.get("tool_name", "")
tool_input = d.get("tool_input", {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except Exception:
        tool_input = {}

file_path = tool_input.get("file_path", "")
if not file_path:
    sys.exit(0)

# Log the edit
entry = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "tool": tool_name,
    "file": file_path,
    "cwd": d.get("cwd", ""),
}

try:
    with open(EDIT_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")
        f.flush()
except Exception:
    pass

# Silent — no output to user
print(json.dumps({"suppressOutput": True}))
PYEOF
