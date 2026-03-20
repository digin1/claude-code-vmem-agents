#!/bin/bash
# PreToolUse hook: enrich vmem operations with project context + audit trail
# For memory_store/update: auto-detect project from cwd, inject via updatedInput
# For ALL vmem tools: log operation to audit trail

INPUT=$(cat)

python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

OPS_LOG = os.path.expanduser("~/.claude/.vmem_ops_log.jsonl")

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

tool_name = d.get("tool_name", "")
tool_input = d.get("tool_input", {})
cwd = d.get("cwd", "") or os.getcwd()

if not tool_name.startswith("mcp__vector-memory__"):
    sys.exit(0)

# Extract the specific tool (memory_store, memory_search, etc.)
tool_short = tool_name.replace("mcp__vector-memory__", "")

# ================================================================
# Audit: log every vmem operation
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
except Exception:
    pass

# ================================================================
# Enrich: auto-detect project for store/update if not set
# ================================================================
if tool_short in ("memory_store", "memory_update"):
    current_project = tool_input.get("project", "")

    if not current_project:
        # Detect project from cwd path
        # Known project names from common paths
        cwd_lower = cwd.lower()
        detected = ""
        for proj in ["grantlab-dockerswarm", "glabheatmap", "ulkuanalysis",
                      "ulkusubtype", "comfyui", "ollama-calls"]:
            if proj in cwd_lower:
                detected = proj
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
