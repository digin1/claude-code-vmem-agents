#!/bin/bash
# PostToolUseFailure hook: store error patterns as cortex memories
# When tools fail repeatedly, the error pattern becomes searchable knowledge

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings, hashlib
warnings.filterwarnings("ignore")

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

tool_name = d.get("tool_name", "")
tool_input = d.get("tool_input", {})
error = d.get("error", "") or d.get("tool_error", "") or d.get("result", "")
cwd = d.get("cwd", "")

if not tool_name or not error:
    sys.exit(0)

# Skip noisy/uninteresting failures
if tool_name in ("Read", "Glob", "Grep"):
    sys.exit(0)

error_str = str(error)[:500]

# Dedup: check if we already logged this error pattern recently
FAILURE_LOG = os.path.expanduser("~/.claude/.cortex_failure_log")
error_hash = hashlib.md5(f"{tool_name}:{error_str[:100]}".encode()).hexdigest()[:12]

try:
    if os.path.exists(FAILURE_LOG):
        with open(FAILURE_LOG) as f:
            recent = f.readlines()[-20:]  # last 20 entries
        for line in recent:
            if error_hash in line:
                sys.exit(0)  # already logged recently
except:
    pass

# Log this failure
try:
    import stat
    fd = os.open(FAILURE_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {error_hash} {tool_name}\n")
except:
    pass

# Detect project
project_name = ""
if cwd:
    parts = cwd.rstrip("/").split("/")
    skip = {"home", "Users", "projects", "src", "work", "dev", "repos", "code", ".claude", ""}
    for p in reversed(parts):
        if p not in skip:
            project_name = p
            break

# Build context summary for Claude
cmd_info = ""
if tool_name == "Bash":
    cmd_info = f" Command: {str(tool_input.get('command', ''))[:150]}"
elif tool_name in ("Edit", "Write"):
    cmd_info = f" File: {tool_input.get('file_path', '')}"

context = (
    f"[cortex] Tool failure detected — {tool_name}{cmd_info}\n"
    f"  Error: {error_str[:300]}\n"
    f"  If this is a recurring issue, consider storing the fix as a cortex memory."
)

output = json.dumps({
    "suppressOutput": True,
    "hookSpecificOutput": {
        "hookEventName": "PostToolUseFailure",
        "additionalContext": context
    }
})
print(output)

PYEOF
