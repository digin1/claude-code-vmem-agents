#!/bin/bash
# Agent bootstrap: creates agents from accumulated cortex knowledge
# Called from SessionStart hook (async) — doesn't block the session
#
# Flow:
#   1. Quick check: does current project need agents? (fast, no LLM)
#   2. Cooldown check: already bootstrapped today? (skip if so)
#   3. Collect cortex memories for the project (full content, grouped)
#   4. ONE call to claude -p (haiku) to propose agents
#   5. fleet_create.py creates with semantic dedup (threshold 0.55)
#
# Safety:
#   - Max 3 agents per run (hard cap in fleet_create.py's agents[:5] + prompt)
#   - Cooldown: once per project per day
#   - Semantic dedup: cosine distance < 0.55 = skip
#   - Total cap: if project already has 5+ agents, skip entirely

INPUT=$(cat 2>/dev/null)
LIB="$(dirname "$0")/lib"
COOLDOWN_DIR="$HOME/.claude/.cortex_bootstrap_cooldown"
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
# Phase 1: Quick check — does this project need agents?
# Returns: project_needs,global_needs or empty
# ================================================================
NEEDS=$(/usr/bin/python3 -W ignore - "$CWD" 2>/dev/null <<'PYEOF'
import sys, os, glob

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

cwd = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    col = get_collection()
    if col.count() == 0:
        sys.exit(0)

    all_data = col.get(include=["metadatas"])

    # Count project/reference memories per project
    project_mem_count = {}
    for m in all_data["metadatas"]:
        p = m.get("project", "")
        t = m.get("type", "")
        if t == "agent_eval":
            continue
        if p and t in ("project", "reference"):
            project_mem_count[p] = project_mem_count.get(p, 0) + 1

    # Match cwd to cortex project names
    cwd_lower = cwd.lower()
    matched = [p for p in project_mem_count if p != "global" and p.lower() in cwd_lower]

    needs = []

    for proj in matched:
        mem_count = project_mem_count.get(proj, 0)
        if mem_count < 3:
            continue

        # Always consider project for agent creation (dedup handles duplicates)
        needs.append(proj)

    # Always consider global agents (dedup handles duplicates)
    needs.append("global")

    print(",".join(needs) if needs else "")

except Exception:
    print("")
PYEOF
)

if [ -z "$NEEDS" ]; then
    exit 0
fi

# ================================================================
# Phase 1.5: Auto-recall retired agents if no similar active agent exists
# ================================================================
/usr/bin/python3 -W ignore - "$CWD" 2>/dev/null <<'RECALL_EOF'
import sys, os, glob, re

cwd = sys.argv[1] if len(sys.argv) > 1 else ""
retired_dir = os.path.expanduser("~/.claude/.retired-agents")
if not os.path.isdir(retired_dir):
    sys.exit(0)

retired_files = glob.glob(os.path.join(retired_dir, "*.md"))
if not retired_files:
    sys.exit(0)

# Collect active agent descriptions (project + global)
active_agents = {}  # name -> description
for agents_dir in [
    os.path.join(cwd, ".claude", "agents") if cwd else "",
    os.path.expanduser("~/.claude/agents"),
]:
    if not agents_dir or not os.path.isdir(agents_dir):
        continue
    for f in glob.glob(os.path.join(agents_dir, "*.md")):
        name = os.path.basename(f).replace(".md", "")
        try:
            with open(f) as fh:
                content = fh.read()
            # Extract description from frontmatter
            match = re.search(r'^description:\s*(.+)$', content, re.MULTILINE)
            active_agents[name] = match.group(1).strip() if match else ""
        except:
            pass

if not active_agents:
    # No active agents at all — recall all retired ones
    pass

# Use ChromaDB semantic similarity to check if retired agent's role is covered
sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
try:
    from chroma_client import get_collection
    col = get_collection()
except:
    sys.exit(0)

# Build active descriptions text for comparison
active_descs = [f"{n}: {d}" for n, d in active_agents.items() if d]

recalled = 0
for retired_path in retired_files:
    try:
        with open(retired_path) as f:
            content = f.read()
        match = re.search(r'^description:\s*(.+)$', content, re.MULTILINE)
        if not match:
            continue
        retired_desc = match.group(1).strip()
        retired_name = os.path.basename(retired_path).replace(".md", "")

        # Skip if an agent with the same name already exists
        if retired_name in active_agents:
            continue

        # Check semantic similarity against all active agent descriptions
        is_covered = False
        if active_descs:
            try:
                # Embed retired description and compare against active ones
                results = col.query(
                    query_texts=[retired_desc],
                    where={"type": "agent_eval"},
                    n_results=1,
                )
                # Also do a simple keyword overlap check
                retired_words = set(retired_desc.lower().split())
                for active_desc in active_descs:
                    active_words = set(active_desc.lower().split())
                    overlap = len(retired_words & active_words) / max(len(retired_words), 1)
                    if overlap > 0.5:
                        is_covered = True
                        break
            except:
                pass

        if is_covered:
            continue

        # Recall: move retired agent back to the appropriate agents directory
        # Determine scope from content
        if "scope: project" in content.lower() or "project" in content[:200].lower():
            target_dir = os.path.join(cwd, ".claude", "agents") if cwd else os.path.expanduser("~/.claude/agents")
        else:
            target_dir = os.path.expanduser("~/.claude/agents")

        os.makedirs(target_dir, exist_ok=True)
        target_path = os.path.join(target_dir, os.path.basename(retired_path))

        if not os.path.exists(target_path):
            os.rename(retired_path, target_path)
            recalled += 1
            print(f"[cortex bootstrap] Recalled retired agent: {retired_name}")
    except Exception as e:
        continue

if recalled > 0:
    activity_file = os.path.expanduser("~/.claude/.cortex_activity")
    try:
        existing = open(activity_file).read().strip() if os.path.exists(activity_file) else ""
        msg = f"recalled {recalled} retired agent(s)"
        with open(activity_file, "w") as f:
            f.write(f"{existing} | {msg}" if existing else msg)
    except:
        pass
RECALL_EOF

# ================================================================
# Phase 2: Cooldown — once per project per day
# ================================================================
TODAY=$(date +%Y-%m-%d)

ALL_COOLED=true
for proj in $(echo "$NEEDS" | tr ',' ' '); do
    COOLDOWN_FILE="$COOLDOWN_DIR/${proj}_${TODAY}"
    if [ ! -f "$COOLDOWN_FILE" ]; then
        ALL_COOLED=false
        break
    fi
done

if [ "$ALL_COOLED" = true ]; then
    exit 0
fi

echo "[cortex bootstrap] Projects needing agents: $NEEDS"

# ================================================================
# Phase 3: Collect memories + existing agents
# ================================================================
# Collect memories with size cap (12KB max to fit haiku context)
MEMORIES=$("$LIB/collect_memories_full.py" "$NEEDS" 2>/dev/null | head -c 12000)
EXISTING_AGENTS=$("$LIB/collect_agents.py" 2>/dev/null)

EXISTING_NAMES=$(echo "$EXISTING_AGENTS" | /usr/bin/python3 -c "
import sys, json
try:
    agents = json.loads(sys.stdin.read())
    for a in agents:
        desc = ''
        for line in a['content'].split('\n'):
            if line.strip().startswith('description:'):
                desc = line.split(':', 1)[1].strip()
                break
        print(f'  - {a[\"name\"]} ({a[\"scope\"]}): {desc}')
except: pass
" 2>/dev/null)

if [ -z "$MEMORIES" ]; then
    echo "[cortex bootstrap] No memories to work with"
    exit 0
fi

# ================================================================
# Phase 4: SINGLE call to haiku — propose agents
# ================================================================
CREATE_RESULT=$(cat <<PROMPT_EOF | claude -p --bare --model haiku 2>/dev/null
You are an agent architect for Claude Code. Analyze these accumulated vector memories and propose EXACTLY the right number of reusable subagents.

=== VMEM MEMORIES ===
$MEMORIES

=== EXISTING AGENTS ===
${EXISTING_NAMES:-  (none)}

=== CONTEXT ===
Working directory: $CWD
Projects needing agents: $NEEDS

## CRITICAL RULES

1. Output a JSON array. NO markdown wrapping, NO explanation — JUST the JSON array.
2. Maximum 3 agents TOTAL across all projects and global combined.
3. Each agent must cover a DISTINCT domain — no overlapping scope.
4. Do NOT create an agent if an existing one already covers that domain.
5. If no agents are needed, return: []

## Two Scopes

- "project": specific to this project's workflows (goes in .claude/agents/)
- "user": cross-project patterns useful everywhere (goes in ~/.claude/agents/)

## Agent Quality Requirements

- description: SPECIFIC trigger conditions ("Use when..." or "Use for...")
- System prompt: include ACTUAL knowledge from memories — paths, commands, gotchas, patterns
- tools: [Read, Edit, Write, Bash, Grep, Glob] for most agents
- model: opus (always)

## Output Format

[{"scope": "project", "filename": "kebab-case.md", "content": "---\nname: agent-name\ndescription: When to use this\ntools:\n  - Read\n  - Edit\n  - Write\n  - Bash\n  - Grep\n  - Glob\nmodel: opus\n---\n\nSystem prompt here with real knowledge..."}]
PROMPT_EOF
)

if [ -z "$CREATE_RESULT" ]; then
    echo "[cortex bootstrap] No agent proposals generated"
    # Still set cooldown to avoid re-trying a failing call
    for proj in $(echo "$NEEDS" | tr ',' ' '); do
        touch "$COOLDOWN_DIR/${proj}_${TODAY}"
    done
    exit 0
fi

# ================================================================
# Phase 5: Create via fleet_create.py (semantic dedup at 0.55)
# ================================================================
CREATED=$("$LIB/fleet_create.py" "$CREATE_RESULT" "$CWD" 2>/dev/null)

if [ "$CREATED" -gt 0 ] 2>/dev/null; then
    echo "[cortex bootstrap] Created $CREATED new agent(s)"

    # Update activity indicator
    ACTIVITY_FILE="$HOME/.claude/.cortex_activity"
    EXISTING_ACTIVITY=""
    if [ -f "$ACTIVITY_FILE" ]; then
        EXISTING_ACTIVITY=$(cat "$ACTIVITY_FILE" 2>/dev/null)
    fi
    if [ -n "$EXISTING_ACTIVITY" ]; then
        echo "$EXISTING_ACTIVITY | bootstrap: +$CREATED agents" > "$ACTIVITY_FILE"
    else
        echo "bootstrap: +$CREATED agents" > "$ACTIVITY_FILE"
    fi
else
    echo "[cortex bootstrap] No new agents created (existing coverage sufficient)"
fi

# Set cooldown for all projects
for proj in $(echo "$NEEDS" | tr ',' ' '); do
    touch "$COOLDOWN_DIR/${proj}_${TODAY}"
done

# Clean old cooldown files (>7 days)
find "$COOLDOWN_DIR" -name "*_20*" -mtime +7 -delete 2>/dev/null

exit 0
