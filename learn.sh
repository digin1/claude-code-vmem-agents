#!/bin/bash
# Auto-learn: called by Stop hook
# Strategy: block the stop and let Claude (Opus) extract learnings, suggest
# skills, create agents, and optionally generate docs — using its full
# session context and MCP tools directly.
#
# Flow:
# 1. Stop hook fires (stop_hook_active=false) → check transcript for content
# 2. If enough content → return {"decision":"block"} with instructions
# 3. Claude continues: stores memories, suggests skills, creates agents
# 4. Stop hook fires again (stop_hook_active=true) → exit cleanly
# 5. Session ends

INPUT=$(cat)
CORTEX_CONFIG="$HOME/.claude/.cortex_config"

# Second pass — Claude already processed, let it exit
STOP_HOOK_ACTIVE=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('stop_hook_active',False))" 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "True" ] || [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Pre-check: verify MCP server can connect
if ! /usr/bin/python3 -W ignore -c "import mcp, chromadb" 2>/dev/null; then
    exit 0
fi

# Check if auto_learn is disabled
if grep -q '"auto_learn":false' "$CORTEX_CONFIG" 2>/dev/null; then
    exit 0
fi

# Check transcript for meaningful content and build instructions
/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, re

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

transcript_path = d.get("transcript_path", "")
cwd = d.get("cwd", "")
if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(0)

# Count meaningful messages
msg_count = 0
user_msgs = []
assistant_tool_uses = 0
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
                    if isinstance(part, dict):
                        if part.get('type') == 'text':
                            t = part.get('text', '').strip()
                            if t:
                                text += t + ' '
                        elif part.get('type') == 'tool_use':
                            assistant_tool_uses += 1
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

# Build topic hint
clean_msgs = [re.sub(r'<[^>]+>', '', m).strip() for m in user_msgs[:5]]
clean_msgs = [m for m in clean_msgs if len(m) > 10]
topic_hint = " | ".join(clean_msgs)[:400]

project_name = os.path.basename(cwd) if cwd else "unknown"

# Read config for enabled features
config = {}
config_path = os.path.expanduser("~/.claude/.cortex_config")
try:
    with open(config_path) as f:
        config = json.load(f)
except Exception:
    pass

auto_skills = config.get("auto_skills", True)
auto_agents = config.get("auto_agents", True)

# Build instructions for Claude
instructions = []

# Phase 1: Learnings (always)
instructions.append(
    "1. LEARNINGS: Review this session and store NEW learnings via mcp__cortex__memory_store. "
    "Types: feedback (user corrections/preferences), project (decisions/architecture), "
    "reference (external resources/configs), user (role/expertise). "
    "Use descriptive memory_id (e.g., feedback_no_mocks), add relevant tags, "
    f"set project=\"{project_name}\". Skip anything already stored or derivable from code. "
    "Max 5 learnings."
)

# Phase 2: Skills
if auto_skills:
    instructions.append(
        "2. SKILLS: If you noticed repeated multi-step workflows or debugging patterns "
        "during this session that aren't covered by existing skills, create new skill files "
        "in .claude/commands/ (project-specific) or ~/.claude/commands/ (global). "
        "Use YAML frontmatter with description:. Max 2 skills. Skip if nothing needed."
    )

# Phase 3: Agents
if auto_agents:
    instructions.append(
        "3. AGENTS: If the session revealed a recurring domain-specific need not covered by "
        "existing agents, create a new agent .md file in .claude/agents/ (project) or "
        "~/.claude/agents/ (global). Include detailed system prompt with actual knowledge "
        "from this session. Max 1 agent. Skip if nothing needed."
    )

instruction_text = "\n".join(instructions)

output = json.dumps({
    "decision": "block",
    "reason": "[cortex] Extracting session learnings",
    "systemMessage": (
        f"[cortex] Session review for project: {project_name}\n"
        f"Topics: {topic_hint}\n\n"
        f"{instruction_text}\n\n"
        "After completing all applicable phases, briefly summarize what you stored/created. "
        "If nothing new to store, say so in one line."
    )
})
print(output)

PYEOF
