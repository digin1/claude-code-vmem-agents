#!/bin/bash
# PreToolUse hook: enrich cortex operations with project context + audit trail
# For memory_store/update: auto-detect project from cwd, inject via updatedInput
# For ALL cortex tools: log operation to audit trail

INPUT=$(cat)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

OPS_LOG = os.path.expanduser("~/.claude/.cortex_ops_log.jsonl")

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

tool_name = d.get("tool_name", "")
tool_input = d.get("tool_input", {})
cwd = d.get("cwd", "") or os.getcwd()

if not tool_name.startswith("mcp__cortex__"):
    sys.exit(0)

# Extract the specific tool (memory_store, memory_search, etc.)
tool_short = tool_name.replace("mcp__cortex__", "")

# ================================================================
# Audit: log every cortex operation
# ================================================================
try:
    entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "tool": tool_short,
        "cwd": cwd,
    }
    # Include memory_id if available
    if "memory_id" in tool_input:
        entry["memory_id"] = tool_input["memory_id"]
    if "query" in tool_input:
        entry["query"] = tool_input["query"][:100]

    with open(OPS_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")
    # Rotate if >500KB (keep last 7 days)
    if os.path.getsize(OPS_LOG) > 500_000:
        cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - 7 * 86400))
        with open(OPS_LOG) as f:
            lines = [l for l in f if l[16:26] >= cutoff]  # timestamp prefix
        with open(OPS_LOG, "w") as f:
            f.writelines(lines)
except Exception:
    pass

# ================================================================
# Enrich: auto-detect project for store/update if not set
# ================================================================
if tool_short in ("memory_store", "memory_update"):
    current_project = tool_input.get("project", "")

    if not current_project:
        # Detect project dynamically from cwd path components
        parts = cwd.replace("\\", "/").split("/")
        detected = ""
        skip = {"home", "Users", "projects", "src", "work", "dev", "repos", "code", ".claude", ""}
        for p in reversed(parts):
            if p not in skip and len(p) > 2 and not p.startswith("."):
                detected = p
                break

        if detected:
            updated_input = dict(tool_input)
            updated_input["project"] = detected

            output = json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": updated_input
                }
            })
            print(output)
            sys.exit(0)

# For non-enriched calls, just allow
output = json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow"
    }
})
print(output)
PYEOF
