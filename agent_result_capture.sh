#!/bin/bash
# SubagentStop hook: capture key findings when agents finish
# Logs agent completion and injects a reminder to store useful findings

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

agent_type = d.get("agent_type", "") or d.get("subagent_type", "")
cwd = d.get("cwd", "")

# Skip built-in agents — they're routine
if agent_type in ("general-purpose", "Explore", "Plan", "Bash", "statusline-setup", "claude-code-guide", ""):
    sys.exit(0)

# Log completion to usage ledger
USAGE_LOG = os.path.expanduser("~/.claude/agent-usage.jsonl")
try:
    import stat
    fd = os.open(USAGE_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "a") as f:
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "event": "stop",
            "agent": agent_type,
            "cwd": cwd,
        }
        f.write(json.dumps(entry) + "\n")
except:
    pass

# Inject reminder to store findings
context = (
    f"[cortex] Agent '{agent_type}' completed. "
    f"If it produced useful findings, store them as a cortex memory "
    f"(type: project or reference) so future sessions can recall them."
)

output = json.dumps({
    "suppressOutput": True,
    "hookSpecificOutput": {
        "hookEventName": "SubagentStop",
        "additionalContext": context
    }
})
print(output)

PYEOF
