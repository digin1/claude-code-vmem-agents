#!/bin/bash
# Auto-skill discovery: detects project tech stack and generates skill commands
# Called from SessionStart hook (async) — doesn't block the session
#
# Flow:
#   1. Detect tech stack (fast Python scan, no LLM)
#   2. Check cooldown (once per project per week)
#   3. Check which frameworks already have skills
#   4. ONE call to claude -p (sonnet) to generate skill definitions
#   5. skill_create.py writes .md command files
#
# Safety:
#   - Max 5 skills per run (prompt cap)
#   - Cooldown: once per project per week
#   - Won't overwrite existing skill files
#   - Total cap: 10 project + 10 global skills
#   - Validates frontmatter structure before writing

INPUT=$(cat 2>/dev/null)
LIB="$(dirname "$0")/lib"
COOLDOWN_DIR="$HOME/.claude/.cortex_skill_cooldown"
mkdir -p "$COOLDOWN_DIR"

# Extract cwd from hook input
CWD=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
try: print(json.loads(sys.stdin.read()).get('cwd', ''))
except: print('')
" 2>/dev/null)

if [ -z "$CWD" ]; then
    CWD=$(pwd)
fi

# ================================================================
# Phase 1: Detect tech stack (fast, no LLM)
# ================================================================
STACK=$(/usr/bin/python3 "$LIB/skill_detect.py" "$CWD" 2>/dev/null)

if [ -z "$STACK" ]; then
    exit 0
fi

# Check if any frameworks were detected
FRAMEWORK_COUNT=$(echo "$STACK" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    # Only count primary frameworks, skip generic tools like typescript, make
    skip = {'typescript', 'make', 'docker', 'vite'}
    fws = [f for f in d.get('frameworks', []) if f['id'] not in skip]
    print(len(fws))
except: print('0')
" 2>/dev/null)

if [ "$FRAMEWORK_COUNT" = "0" ]; then
    exit 0
fi

# ================================================================
# Phase 2: Cooldown — once per project per week
# ================================================================
PROJECT_NAME=$(echo "$STACK" | /usr/bin/python3 -c "
import sys, json
try: print(json.loads(sys.stdin.read()).get('project_name', 'unknown'))
except: print('unknown')
" 2>/dev/null)

WEEK=$(date +%Y-W%V)
COOLDOWN_FILE="$COOLDOWN_DIR/${PROJECT_NAME}_${WEEK}"

if [ -f "$COOLDOWN_FILE" ]; then
    exit 0
fi

# ================================================================
# Phase 3: Check which frameworks already have skill commands
# ================================================================
UNCOVERED=$(/usr/bin/python3 -W ignore - "$CWD" "$STACK" 2>/dev/null <<'PYEOF'
import sys, os, json

cwd = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    stack = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
except:
    stack = {}

frameworks = stack.get("frameworks", [])
if not frameworks:
    print("")
    sys.exit(0)

# Skip generic tools — not worth generating skills for
skip_ids = {"typescript", "make", "docker", "vite", "cmake"}

# Collect all existing skill filenames from both scopes
existing_names = set()
for cmd_dir in [
    os.path.expanduser("~/.claude/commands"),
    os.path.join(cwd, ".claude", "commands") if cwd else "",
]:
    if cmd_dir and os.path.isdir(cmd_dir):
        for f in os.listdir(cmd_dir):
            if f.endswith(".md"):
                existing_names.add(f.replace(".md", "").lower())

# A framework is "covered" if any existing skill filename contains its id
uncovered = []
for fw in frameworks:
    fid = fw["id"]
    if fid in skip_ids:
        continue
    has_skill = any(fid.lower() in name for name in existing_names)
    if not has_skill:
        uncovered.append(fw)

# Output as JSON array of uncovered frameworks
print(json.dumps(uncovered))
PYEOF
)

# Parse uncovered count
UNCOVERED_COUNT=$(echo "$UNCOVERED" | /usr/bin/python3 -c "
import sys, json
try: print(len(json.loads(sys.stdin.read())))
except: print('0')
" 2>/dev/null)

if [ "$UNCOVERED_COUNT" = "0" ] || [ -z "$UNCOVERED" ] || [ "$UNCOVERED" = "[]" ]; then
    touch "$COOLDOWN_FILE"
    exit 0
fi

echo "[skill-discover] Uncovered frameworks in $PROJECT_NAME: $UNCOVERED"

# ================================================================
# Phase 4: Build framework details for the prompt
# ================================================================
FRAMEWORK_DETAILS=$(echo "$UNCOVERED" | /usr/bin/python3 -c "
import sys, json
try:
    fws = json.loads(sys.stdin.read())
    for f in fws:
        eco = f.get('ecosystem', 'unknown')
        ver = f.get('version', '')
        ver_str = f' v{ver}' if ver else ''
        print(f'- {f[\"name\"]} ({f[\"id\"]}){ver_str}: ecosystem={eco}')
except: pass
" 2>/dev/null)

# Collect existing skill names for the prompt
EXISTING_SKILLS=""
if [ -d "$HOME/.claude/commands" ]; then
    EXISTING_SKILLS=$(ls "$HOME/.claude/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | head -20)
fi
if [ -d "$CWD/.claude/commands" ]; then
    PROJECT_SKILLS=$(ls "$CWD/.claude/commands/"*.md 2>/dev/null | xargs -I{} basename {} .md | head -20)
    if [ -n "$PROJECT_SKILLS" ]; then
        EXISTING_SKILLS="$EXISTING_SKILLS
$PROJECT_SKILLS"
    fi
fi

# ================================================================
# Phase 5: ONE call to claude -p (sonnet) — generate skill definitions
# ================================================================
SKILL_RESULT=$(cat <<PROMPT_EOF | claude -p --model sonnet --mcp-config '{}' --strict-mcp-config 2>/dev/null
You are a skill architect for Claude Code. Generate reusable slash-command skill files (.md) for the detected frameworks.

=== DETECTED FRAMEWORKS (need skills) ===
$FRAMEWORK_DETAILS

=== PROJECT ===
Name: $PROJECT_NAME
Directory: $CWD

=== EXISTING SKILL COMMANDS (don't duplicate) ===
${EXISTING_SKILLS:-(none)}

## RULES

1. Output a JSON array. NO markdown wrapping, NO explanation — JUST the JSON array.
2. Maximum 5 skills TOTAL across all frameworks.
3. Pick the MOST USEFUL skills: scaffolding, testing, debugging, common patterns.
4. Each skill must be DISTINCT and actionable — not generic advice.
5. Skip overly generic skills like "lint" or "format" — those are editor-level.

## Scope

- "project": framework-specific (goes in project .claude/commands/)
- "global": cross-project utility (goes in ~/.claude/commands/)
- Default to "project" unless truly generic across all projects.

## Skill .md Format

\`\`\`
---
description: One-line description shown in command palette
---

Detailed instructions for Claude when user invokes this command.
Use \$ARGUMENTS to capture user input after the command name.
\`\`\`

## Quality — IMPORTANT

The skill body must contain SPECIFIC, ACTIONABLE instructions, not vague platitudes. Include:

- Framework-specific conventions and patterns (e.g., FastAPI uses async def, Depends() for DI)
- File structure conventions (e.g., Next.js app router uses app/ directory)
- Testing patterns (e.g., use TestClient for FastAPI, @testing-library for React)
- Error handling idioms specific to the framework
- The prompt should tell Claude HOW to implement, not just WHAT to implement

Example of a GOOD skill body (FastAPI endpoint):
"Create a new FastAPI endpoint. Follow these conventions:
1. Use async def for the route handler
2. Define Pydantic models for request body and response
3. Use Depends() for any shared dependencies (db session, auth, etc.)
4. Add proper HTTP status codes (201 for creation, 404 for not found)
5. Include OpenAPI metadata: summary, description, response_model
6. Add the route to the appropriate router in app/api/
7. Write a test using TestClient that covers success + error cases
8. Use \$ARGUMENTS as the endpoint description/purpose"

## Output

[{"scope": "project", "filename": "kebab-case-name.md", "content": "---\ndescription: What it does\n---\n\nDetailed instructions..."}]
PROMPT_EOF
)

if [ -z "$SKILL_RESULT" ]; then
    echo "[skill-discover] No skill proposals generated"
    touch "$COOLDOWN_FILE"
    exit 0
fi

# ================================================================
# Phase 6: Create skill files via skill_create.py
# ================================================================
CREATED=$(/usr/bin/python3 "$LIB/skill_create.py" "$SKILL_RESULT" "$CWD" 2>/dev/null)

if [ "$CREATED" -gt 0 ] 2>/dev/null; then
    echo "[skill-discover] Created $CREATED new skill(s) for $PROJECT_NAME"

    # Store discovery record in cortex
    /usr/bin/python3 -W ignore - "$PROJECT_NAME" "$UNCOVERED" "$CREATED" 2>/dev/null <<'PYEOF'
import sys, os, json, time, warnings
warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"

_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2); os.close(_dn)
try:
    import chromadb
finally:
    os.dup2(_fd, 2); os.close(_fd)

project = sys.argv[1] if len(sys.argv) > 1 else "unknown"
try:
    uncovered = json.loads(sys.argv[2]) if len(sys.argv) > 2 else []
except:
    uncovered = []
count = sys.argv[3] if len(sys.argv) > 3 else "0"

framework_names = ", ".join(f.get("name", f.get("id", "?")) for f in uncovered) if uncovered else "unknown"

DB_PATH = os.path.expanduser("~/.claude/cortex-db")
try:
    client = chromadb.PersistentClient(path=DB_PATH)
    col = client.get_or_create_collection("claude_memories")

    memory_id = f"skill_discovery_{project}"
    content = (
        f"Auto-discovered {count} skill command(s) for project '{project}'. "
        f"Frameworks: {framework_names}. "
        f"Generated on {time.strftime('%Y-%m-%d')}. "
        f"Skills are in {project}/.claude/commands/ (project) or ~/.claude/commands/ (global)."
    )

    col.upsert(
        ids=[memory_id],
        documents=[content],
        metadatas=[{
            "type": "project",
            "project": project,
            "tags": "skill-discovery,auto-generated",
            "created": time.strftime("%Y-%m-%dT%H:%M:%S")
        }]
    )
except Exception:
    pass
PYEOF

    # Update activity indicator
    ACTIVITY_FILE="$HOME/.claude/.cortex_activity"
    EXISTING_ACTIVITY=""
    if [ -f "$ACTIVITY_FILE" ]; then
        EXISTING_ACTIVITY=$(cat "$ACTIVITY_FILE" 2>/dev/null)
    fi
    if [ -n "$EXISTING_ACTIVITY" ]; then
        echo "$EXISTING_ACTIVITY | skills: +$CREATED ($PROJECT_NAME)" > "$ACTIVITY_FILE"
    else
        echo "skills: +$CREATED ($PROJECT_NAME)" > "$ACTIVITY_FILE"
    fi
else
    echo "[skill-discover] No new skills created (existing coverage sufficient)"
fi

# Set cooldown
touch "$COOLDOWN_FILE"

# Clean old cooldown files (>30 days)
find "$COOLDOWN_DIR" -name "*_20*" -mtime +30 -delete 2>/dev/null

exit 0
