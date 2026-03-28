#!/bin/bash
# Auto-learn: called by Stop hook
# Strategy: non-blocking — check if session had meaningful content,
# spawn background process to extract learnings via claude -p.
# Status shown live in the status line via .cortex_learning_status file.
#
# Flow:
# 1. Stop hook fires → script checks transcript for meaningful content
# 2. If enough content → spawns background extraction process
# 3. Returns immediately (non-blocking) — user exits right away
# 4. Background process: parse transcript → claude -p → store_memories.py
# 5. Status line shows live progress via status file

INPUT=$(cat)
LIB="$(dirname "$0")/lib"
LEARNING_STATUS="$HOME/.claude/.cortex_learning_status"
CORTEX_CONFIG="$HOME/.claude/.cortex_config"

# Pre-check: verify dependencies importable
if ! /usr/bin/python3 -W ignore -c "import mcp, chromadb" 2>/dev/null; then
    exit 0
fi

# Check if auto_learn is disabled in config
if grep -q '"auto_learn":false' "$CORTEX_CONFIG" 2>/dev/null; then
    exit 0
fi

# Check if session had enough meaningful content to learn from
SHOULD_LEARN=$(/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, re

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)

transcript_path = d.get("transcript_path", "")
cwd = d.get("cwd", "")
if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(1)

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
    sys.exit(1)

# Need at least 4 meaningful messages (2 exchanges)
if msg_count < 4:
    sys.exit(1)

# Build topic hint
clean_msgs = [re.sub(r'<[^>]+>', '', m).strip() for m in user_msgs[:3]]
clean_msgs = [m for m in clean_msgs if len(m) > 10]
topic_hint = " | ".join(clean_msgs)[:300]

# Output as JSON for the shell to parse
print(json.dumps({
    "transcript_path": transcript_path,
    "cwd": cwd,
    "topic_hint": topic_hint,
    "msg_count": msg_count,
}))
PYEOF
)

# If python exited non-zero, not enough content
if [ $? -ne 0 ] || [ -z "$SHOULD_LEARN" ]; then
    rm -f "$LEARNING_STATUS" 2>/dev/null
    exit 0
fi

# Parse values from python output
TRANSCRIPT=$(echo "$SHOULD_LEARN" | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('transcript_path',''),end='')" 2>/dev/null)
CWD=$(echo "$SHOULD_LEARN" | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('cwd',''),end='')" 2>/dev/null)
TOPICS=$(echo "$SHOULD_LEARN" | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('topic_hint',''),end='')" 2>/dev/null)

# Spawn background extraction — completely detached from this process
(
    # Status helpers — write to file + notify on completion
    _PID=${BASHPID}
    _START=$(date +%s)
    _status() {
        echo "pid:${_PID}:${_START}:$1" > "$LEARNING_STATUS" 2>/dev/null
    }
    _done() {
        echo "pid:${_PID}:${_START}:done:$1" > "$LEARNING_STATUS" 2>/dev/null
        # Desktop notification (unless disabled in config)
        if ! grep -q '"notify":false' "$CORTEX_CONFIG" 2>/dev/null; then
            notify-send -i info -t 5000 "Cortex" "$1" 2>/dev/null || true
        fi
    }
    _status "extracting learnings"

    PROJECT_NAME=""
    if [ -n "$CWD" ]; then
        PROJECT_NAME=$(basename "$CWD")
    fi

    # Parse transcript
    CONTEXT=$("$LIB/parse_transcript.py" "$TRANSCRIPT" 2>/dev/null | tail -c 4000)

    if [ -z "$CONTEXT" ] || [ ${#CONTEXT} -lt 100 ]; then
        _done "no new learnings"
        sleep 60 && rm -f "$LEARNING_STATUS" 2>/dev/null
        exit 0
    fi

    # Extract learnings via claude -p
    LEARNINGS=$(echo "$CONTEXT" | claude -p --bare --no-session-persistence --model haiku "
Extract learnings from this coding session for a persistent memory system.
Project: ${PROJECT_NAME:-unknown} (dir: ${CWD:-unknown})
Topics discussed: ${TOPICS:-unknown}

Output a JSON array of memories to store. Each memory object:
{\"type\": \"feedback|project|reference|user\", \"id\": \"descriptive_snake_case_id\", \"content\": \"the learning (max 500 chars)\", \"tags\": \"comma,separated\", \"project\": \"${PROJECT_NAME:-}\"}

Rules:
- Only extract NON-OBVIOUS learnings that would help in future sessions
- Skip ephemeral details, task progress, or things derivable from code
- Types: feedback (user corrections/preferences), project (decisions/architecture), reference (external resources/configs), user (role/expertise)
- Max 5 learnings. If nothing notable, output: []
- Output ONLY the JSON array, no markdown fences or explanation
" 2>/dev/null)

    STORED_COUNT=0
    if [ -z "$LEARNINGS" ] || [ "$LEARNINGS" = "[]" ]; then
        _status "no new learnings"
    else

    # Store via store_memories.py (has built-in dedup)
    _status "storing learnings"
    RESULT=$("$LIB/store_memories.py" "$LEARNINGS" 2>&1)
    STORED_COUNT=$(echo "$RESULT" | grep -c "Stored" 2>/dev/null || echo "0")

    _status "${STORED_COUNT} learnings stored"

    fi  # end learnings if/else

    # ── Phase 2: Skill improvement (if enabled) ──
    SKILL_COUNT=0
    if ! grep -q '"auto_skills":false' "$CORTEX_CONFIG" 2>/dev/null; then
    sleep 2
    _status "checking skills"

    # Detect existing skills
    PROJ_SKILLS=""
    GLOBAL_SKILLS=""
    if [ -d "$CWD/.claude/commands" ]; then
        PROJ_SKILLS=$(ls "$CWD/.claude/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
    fi
    if [ -d "$HOME/.claude/commands" ]; then
        GLOBAL_SKILLS=$(ls "$HOME/.claude/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
    fi

    SKILL_RESULT=$(echo "$CONTEXT" | claude -p --bare --no-session-persistence --model haiku "
Analyze this coding session for skill improvement opportunities.
Project: ${PROJECT_NAME:-unknown} (dir: ${CWD:-unknown})
Existing project skills: ${PROJ_SKILLS:-none}
Existing global skills: ${GLOBAL_SKILLS:-none}

Look for:
1. Repeated multi-step workflows that could be a slash command
2. Complex debugging patterns with specific diagnostic steps
3. Gaps in existing skills (things done manually that a skill should cover)

Output a JSON array of skill changes. Each object:
{\"action\": \"create|update\", \"name\": \"skill-name\", \"scope\": \"local|global\", \"description\": \"one-line for command palette\", \"reason\": \"why this skill is needed\"}

Scope rules:
- local: references project-specific paths, containers, tables, architecture
- global: generic CLI wrapper, reusable across projects

Rules:
- Max 2 skills per session
- Skip trivial one-liner commands
- Only suggest if the pattern occurred 2+ times OR was notably complex
- If nothing to improve, output: []
- Output ONLY the JSON array, no markdown fences
" 2>/dev/null)

    if [ -n "$SKILL_RESULT" ] && [ "$SKILL_RESULT" != "[]" ]; then
        SKILL_COUNT=$(echo "$SKILL_RESULT" | /usr/bin/python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read().strip())
    print(len(data) if isinstance(data, list) else 0, end='')
except: print(0, end='')
" 2>/dev/null)

        if [ "$SKILL_COUNT" -gt 0 ] 2>/dev/null; then
            _status "skills:${SKILL_COUNT} suggested"
            # Store suggestions as a cortex memory for next session to act on
            "$LIB/store_memories.py" "$(echo "$SKILL_RESULT" | /usr/bin/python3 -c "
import sys, json
try:
    skills = json.loads(sys.stdin.read().strip())
    if not isinstance(skills, list) or not skills:
        sys.exit(0)
    content = 'Skill suggestions from session:\\n'
    for s in skills[:2]:
        content += f\"- {s.get('action','create')} /{s.get('name','?')} ({s.get('scope','local')}): {s.get('description','')}\\n\"
        content += f\"  Reason: {s.get('reason','')}\\n\"
    print(json.dumps([{
        'type': 'project',
        'id': 'skill_suggestions_$(date +%Y%m%d)',
        'content': content[:1000],
        'tags': 'skills,auto-suggest',
        'project': '${PROJECT_NAME:-}'
    }]))
except: sys.exit(0)
" 2>/dev/null)" 2>/dev/null
        fi
    fi

    fi  # end auto_skills check

    # ── Phase 3: Agent creation (if enabled) ──
    AGENT_COUNT=0
    if ! grep -q '"auto_agents":false' "$CORTEX_CONFIG" 2>/dev/null; then
    sleep 2
    _status "checking agents"

    # Collect existing agents info
    EXISTING_AGENTS=""
    for AGENT_DIR in "$HOME/.claude/agents" "$CWD/.claude/agents"; do
        if [ -d "$AGENT_DIR" ]; then
            for F in "$AGENT_DIR"/*.md; do
                [ -f "$F" ] && EXISTING_AGENTS="${EXISTING_AGENTS}$(basename "$F" .md): $(head -5 "$F" | grep 'description:' | sed 's/description: *//')\n"
            done
        fi
    done

    AGENT_RESULT=$(echo "$CONTEXT" | claude -p --bare --no-session-persistence --model haiku "
Analyze this coding session for specialized agent opportunities.
Project: ${PROJECT_NAME:-unknown} (dir: ${CWD:-unknown})
Existing agents:
${EXISTING_AGENTS:-none}

An agent is a reusable specialist with a system prompt, used via the Agent tool.
Look for: repeated domain-specific tasks that benefit from focused context injection (e.g., debugging a specific subsystem, managing a specific workflow, analyzing specific data).

Output a JSON array of agents to create. Each object:
{\"filename\": \"agent-name.md\", \"scope\": \"project|user\", \"content\": \"---\nname: agent-name\ndescription: When to use this agent\nmodel: sonnet\n---\n\nSystem prompt with detailed instructions...\"}

Scope rules:
- project: domain-specific to this codebase (references project files, services, architecture)
- user: generic specialist reusable across projects (git workflow, code review, performance analysis)

Rules:
- Max 1 agent per session
- Only create if the session revealed a clear recurring need not covered by existing agents
- Agent must be meaningfully different from existing ones (not just a renamed version)
- If nothing needed, output: []
- Output ONLY the JSON array, no markdown fences
" 2>/dev/null)

    if [ -n "$AGENT_RESULT" ] && [ "$AGENT_RESULT" != "[]" ]; then
        _status "creating agents"
        AGENT_COUNT=$("$LIB/fleet_create.py" "$AGENT_RESULT" "$CWD" 2>/dev/null | tail -1)
    fi
    fi  # end auto_agents check

    # Final status — combine all results
    PARTS=""
    if [ "$STORED_COUNT" -gt 0 ] 2>/dev/null; then
        PARTS="${STORED_COUNT} learnings"
    fi
    if [ "$SKILL_COUNT" -gt 0 ] 2>/dev/null; then
        [ -n "$PARTS" ] && PARTS="${PARTS}, "
        PARTS="${PARTS}${SKILL_COUNT} skill suggestions"
    fi
    if [ "$AGENT_COUNT" -gt 0 ] 2>/dev/null; then
        [ -n "$PARTS" ] && PARTS="${PARTS}, "
        PARTS="${PARTS}${AGENT_COUNT} agents created"
    fi

    if [ -n "$PARTS" ]; then
        _done "${PARTS}"
    else
        _done "no new learnings"
    fi

    # Clean up status file after 2 minutes
    sleep 120 && rm -f "$LEARNING_STATUS" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown

exit 0
