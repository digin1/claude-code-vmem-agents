#!/bin/bash
# Auto-learn: called by Stop hook
# Strategy: check if session had meaningful content, if so block the stop
# and ask Claude to extract + store learnings via MCP tools.
# No subprocess LLM needed — Claude itself does the extraction.
#
# Flow:
# 1. Stop hook fires (stop_hook_active=false) → script checks transcript
# 2. If enough content → returns {"decision":"block"} with reason containing instructions
# 3. Claude continues working, stores memories via mcp__cortex__memory_store
# 4. Claude finishes → Stop hook fires again (stop_hook_active=true) → script exits
# 5. Session ends

INPUT=$(cat)

# Prevent infinite loops — second pass after Claude stored memories
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Pre-check: verify MCP server can actually start (mcp + chromadb importable)
if ! /usr/bin/python3 -W ignore -c "import mcp, chromadb" 2>/dev/null; then
    exit 0
fi

# Check if session had enough meaningful content to learn from
/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

transcript_path = d.get("transcript_path", "")
if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(0)

# Count meaningful messages
msg_count = 0
user_msgs = []
try:
    with open(transcript_path, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
            except Exception:
                continue
            msg = entry.get('message', entry)
            role = msg.get('role', '')
            if role not in ('user', 'assistant'):
                continue
            content = msg.get('content', '')
            text = ''
            if isinstance(content, str):
                text = content.strip()
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get('type') == 'text':
                        t = part.get('text', '').strip()
                        if t:
                            text += t + ' '
            text = text.strip()
            if len(text) > 20:
                msg_count += 1
                if role == 'user':
                    user_msgs.append(text[:200])
except Exception:
    sys.exit(0)

# Need at least 4 meaningful messages (2 exchanges)
if msg_count < 4:
    sys.exit(0)

# Build a hint of what the session was about (first few user messages)
topic_hint = " | ".join(user_msgs[:3])[:400]

# Block the stop — short reason (shown in UI) + detailed systemMessage (read by Claude)
output = json.dumps({
    "decision": "block",
    "reason": "Saving session learnings",
    "systemMessage": (
        "[cortex auto-learn] Store any NEW learnings from this conversation "
        "using mcp__cortex__memory_store. "
        "Look for: (1) feedback — user corrections or preferences, "
        "(2) project — decisions, constraints, bugs discovered, "
        "(3) reference — file paths, external resources, "
        "(4) user — new info about user's role or expertise. "
        "Skip ephemeral task details and things obvious from the code. "
        "Use descriptive memory_id values with appropriate memory_type and tags. "
        "Add project tag if project-specific. "
        "If nothing new was learned, just say so briefly. "
        "IMPORTANT: After storing memories, call mcp__cortex__memory_stats to verify "
        "the count increased. If it shows 0, report that MCP storage failed. "
        f"Session topics: {topic_hint}"
    )
})
print(output)

PYEOF
