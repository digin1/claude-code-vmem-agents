#!/bin/bash
# PreToolUse hook for Bash: block dangerous/destructive commands
# Exit 2 = block the tool call, exit 0 = allow
#
# Safety: strips heredocs, quoted strings, and inline scripts before checking
# so that commit messages, echo statements, and python -c code don't false-positive

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, re

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


def strip_data_content(cmd):
    """Remove all data/string content that isn't an executable command.

    Strips: heredocs, double-quoted strings, single-quoted strings,
    python/ruby/perl -c inline scripts, $(...) substitutions containing strings.
    What remains is the actual shell command structure.
    """
    # 1. Strip heredocs: <<'EOF' ... EOF and <<EOF ... EOF
    for marker in re.findall(r"<<-?\s*'?(\w+)'?", cmd):
        pattern = r"<<-?\s*'?" + re.escape(marker) + r"'?.*?" + re.escape(marker)
        cmd = re.sub(pattern, " __HEREDOC__ ", cmd, flags=re.DOTALL)

    # 2. Strip python3/python/ruby/perl -c "..." inline scripts (the quoted code is data)
    cmd = re.sub(r'(python3?|ruby|perl|node)\s+-[a-z]*c\s+"[^"]*"', r'\1 -c __INLINE__', cmd, flags=re.DOTALL)
    cmd = re.sub(r"(python3?|ruby|perl|node)\s+-[a-z]*c\s+'[^']*'", r"\1 -c __INLINE__", cmd, flags=re.DOTALL)

    # 3. Strip double-quoted strings (but preserve the command around them)
    cmd = re.sub(r'"[^"]*"', ' __STR__ ', cmd)

    # 4. Strip single-quoted strings
    cmd = re.sub(r"'[^']*'", " __STR__ ", cmd)

    # 5. Strip $(...) command substitutions that might contain string literals
    # (conservative: only strip if it looks like it contains echo/cat/printf)
    cmd = re.sub(r'\$\(cat\s+<<[^)]+\)', ' __SUBST__ ', cmd, flags=re.DOTALL)

    return cmd


def block(reason):
    print(json.dumps({"decision": "block", "reason": f"[cortex] {reason}"}))
    sys.exit(0)


# Strip data content, then check the remaining shell commands
cleaned = strip_data_content(command).lower().strip()

# Dangerous exact patterns
DANGEROUS = [
    "rm -rf /",
    "rm -rf /*",
    "rm -rf ~",
    "rm -rf ~/",
    "rm -rf $home",
    "rm -rf .",
    "rm -rf ..",
    ":(){:|:&};:",
    "dd if=/dev/zero of=/dev/sda",
    "format c:",
    "> /dev/sda",
    "chmod -r 777 /",
]

# Regex patterns (applied per-line)
DANGEROUS_RE = [
    r"^\s*rm\s+(-[a-z]*f[a-z]*\s+)?/(?!tmp|dev/shm|remote|home)",
    r"^\s*rm\s+(-[a-z]*f[a-z]*\s+)?\.\s*$",
    r">\s*/dev/sd[a-z]",
    r"^\s*dd\s+.*of=/dev/sd",
    r"^\s*mkfs\.\w+\s+/dev/",
]

# Check each command segment
for line in re.split(r'[;&|]+', cleaned):
    line = line.strip()
    if not line:
        continue

    for pat in DANGEROUS:
        if pat in line:
            block(f"Blocked: '{pat}'")

    for pat in DANGEROUS_RE:
        if re.search(pat, line):
            block("Blocked: dangerous command pattern")

# Allow
sys.exit(0)
PYEOF
