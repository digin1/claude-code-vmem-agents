#!/bin/bash
# PreToolUse hook for Bash: block dangerous/destructive commands
# Exit 2 = block the tool call, exit 0 = allow

INPUT=$(cat 2>/dev/null)

python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, re

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

tool_input = d.get("tool_input", {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except Exception:
        tool_input = {}

command = tool_input.get("command", "")
if not command:
    sys.exit(0)

# Extract only the executable portion — strip heredocs, quoted strings in commit messages, etc.
# Heredocs (<<'EOF' ... EOF or <<EOF ... EOF) contain user content, not commands
cmd_to_check = command
for heredoc_marker in re.findall(r"<<-?\s*'?(\w+)'?", command):
    # Remove everything between <<MARKER and MARKER (inclusive)
    pattern = r"<<-?\s*'?" + re.escape(heredoc_marker) + r"'?.*?" + re.escape(heredoc_marker)
    cmd_to_check = re.sub(pattern, " ", cmd_to_check, flags=re.DOTALL)

cmd_lower = cmd_to_check.lower().strip()

# Exact dangerous patterns — checked against executable portion only
DANGEROUS_EXACT = [
    "rm -rf /",
    "rm -rf /*",
    "rm -rf ~",
    "rm -rf ~/",
    "rm -rf $home",
    "rm -rf .",
    "rm -rf ..",
    ":(){:|:&};:",      # fork bomb
    "dd if=/dev/zero of=/dev/sda",
    "format c:",
    "> /dev/sda",
    "chmod -r 777 /",
]

# Regex patterns for dangerous commands
DANGEROUS_REGEX = [
    r"^\s*rm\s+(-[a-z]*f[a-z]*\s+)?/(?!tmp|dev/shm|remote)",  # rm -rf / (allow /tmp, /dev/shm, /remote)
    r"^\s*rm\s+(-[a-z]*f[a-z]*\s+)?\.\s*$",                    # rm -rf .
    r">\s*/dev/sd[a-z]",                                         # overwrite disk
    r"^\s*dd\s+.*of=/dev/sd",                                    # dd to disk
    r"^\s*mkfs\.\w+\s+/dev/",                                    # format filesystem
]

# Check each line of the command separately (multi-line commands with && or ;)
for line in re.split(r'[;&|]+', cmd_lower):
    line = line.strip()
    if not line:
        continue

    # Check exact matches
    for pattern in DANGEROUS_EXACT:
        if pattern in line:
            reason = f"Blocked dangerous command: '{pattern}'"
            print(json.dumps({"decision": "block", "reason": reason}))
            sys.exit(0)

    # Check regex patterns
    for pattern in DANGEROUS_REGEX:
        if re.search(pattern, line):
            reason = f"Blocked dangerous command pattern"
            print(json.dumps({"decision": "block", "reason": reason}))
            sys.exit(0)

# Allow — no output needed for PreToolUse pass-through
sys.exit(0)
PYEOF
