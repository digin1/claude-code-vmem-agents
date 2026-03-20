#!/bin/bash
# Status line for vector memory — multi-line, clear labels, visual indicators

DB_PATH="$HOME/.claude/vector-memory-db"
ACTIVITY_FILE="$HOME/.claude/.vmem_activity"
OPS_LOG="$HOME/.claude/.vmem_ops_log.jsonl"
SESSIONS_LOG="$HOME/.claude/.vmem_sessions.jsonl"

# ── Line 1: Memory stats ──
MEMORY_LINE=$(python3 -W ignore - "$DB_PATH" 2>/dev/null <<'PYEOF'
import os, sys
os.environ["ORT_LOG_LEVEL"] = "ERROR"
_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2); os.close(_dn)
try:
    import onnxruntime
    onnxruntime.set_default_logger_severity(3)
    import chromadb
finally:
    os.dup2(_fd, 2); os.close(_fd)

try:
    client = chromadb.PersistentClient(path=sys.argv[1])
    col = client.get_or_create_collection("claude_memories")
    c = col.count()
    if c == 0:
        print("empty")
    else:
        data = col.get()
        types = {}
        projects = set()
        for m in data["metadatas"]:
            t = m.get("type", "?")
            if t == "agent_eval":
                continue
            types[t] = types.get(t, 0) + 1
            p = m.get("project", "")
            if p and p != "global":
                projects.add(p)

        # Build readable breakdown
        type_names = {
            "project": "project",
            "feedback": "feedback",
            "reference": "reference",
            "user": "user",
            "general": "general"
        }
        parts = []
        for t in ["project", "feedback", "reference", "user", "general"]:
            if t in types:
                parts.append(f"{types[t]} {type_names.get(t, t)}")

        breakdown = ", ".join(parts)
        proj_count = len(projects)
        proj_text = f" across {proj_count} project{'s' if proj_count != 1 else ''}" if proj_count > 0 else ""
        print(f"{c} memories ({breakdown}){proj_text}")
except Exception:
    print("offline")
PYEOF
)

# ── Line 2: Agent fleet ──
FLEET_LINE=$(python3 -W ignore -c "
import os, glob, json, warnings
warnings.filterwarnings('ignore')
os.environ['ONNXRUNTIME_DISABLE_TELEMETRY'] = '1'
os.environ['ORT_LOG_LEVEL'] = 'ERROR'

user_dir = os.path.expanduser('~/.claude/agents')
proj_dir = '.claude/agents'
user_count = len(glob.glob(os.path.join(user_dir, '*.md'))) if os.path.isdir(user_dir) else 0
proj_count = len(glob.glob(os.path.join(proj_dir, '*.md'))) if os.path.isdir(proj_dir) else 0
total = user_count + proj_count

if total == 0:
    exit(0)

parts = []
if proj_count:
    parts.append(f'{proj_count} project')
if user_count:
    parts.append(f'{user_count} global')

# Usage stats from ledger
usage_total = 0
usage_today = 0
today = __import__('time').strftime('%Y-%m-%d')
ledger = os.path.expanduser('~/.claude/agent-usage.jsonl')
if os.path.exists(ledger):
    try:
        with open(ledger) as f:
            for line in f:
                usage_total += 1
                try:
                    e = json.loads(line.strip())
                    if e.get('timestamp', '').startswith(today):
                        usage_today += 1
                except: pass
    except: pass

# Eval scores
avg_score = ''
try:
    _fd = os.dup(2)
    _dn = os.open(os.devnull, os.O_WRONLY)
    os.dup2(_dn, 2); os.close(_dn)
    try:
        import chromadb
    finally:
        os.dup2(_fd, 2); os.close(_fd)
    client = chromadb.PersistentClient(path=os.path.expanduser('~/.claude/vector-memory-db'))
    col = client.get_or_create_collection('claude_memories')
    data = col.get(where={'type': 'agent_eval'})
    latest = {}
    for i in range(len(data['ids'])):
        m = data['metadatas'][i]
        name = m.get('agent_name', '?')
        ts = m.get('timestamp', '')
        if name not in latest or ts > latest[name]['ts']:
            latest[name] = {'ts': ts, 'score': m.get('score', '0')}
    if latest:
        scores = [int(v['score']) for v in latest.values() if v['score'].isdigit()]
        if scores:
            avg = sum(scores) / len(scores)
            avg_score = f' | health {avg:.1f}/5'
except: pass

scope_text = ' + '.join(parts)
usage_text = ''
if usage_today > 0:
    usage_text = f' | {usage_today} spawns today'
elif usage_total > 0:
    usage_text = f' | {usage_total} total spawns'

print(f'{total} agents ({scope_text}){usage_text}{avg_score}')
" 2>/dev/null)

# ── Line 3: Today's operations ──
OPS_LINE=""
if [ -f "$OPS_LOG" ]; then
    TODAY=$(date +%Y-%m-%d)
    OPS_TODAY=$(grep -c "\"$TODAY" "$OPS_LOG" 2>/dev/null || echo 0)
    if [ "$OPS_TODAY" -gt 0 ]; then
        OPS_LINE="$OPS_TODAY ops today"
    fi
fi

# ── Line 4: Recent activity (last 30 seconds) ──
ACTIVITY=""
if [ -f "$ACTIVITY_FILE" ]; then
    LAST_MOD=$(stat -c %Y "$ACTIVITY_FILE" 2>/dev/null || stat -f %m "$ACTIVITY_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LAST_MOD ))
    if [ "$AGE" -le 30 ]; then
        ACTIVITY=$(cat "$ACTIVITY_FILE" 2>/dev/null)
    fi
fi

# ── Assemble output ──
OUTPUT="\U0001f9e0 ${MEMORY_LINE}"

if [ -n "$FLEET_LINE" ]; then
    OUTPUT="${OUTPUT}\n\U0001f916 ${FLEET_LINE}"
fi

# Combine ops + activity on one line if both exist
EXTRA=""
if [ -n "$OPS_LINE" ] && [ -n "$ACTIVITY" ]; then
    EXTRA="\U000026a1 ${OPS_LINE} | ${ACTIVITY}"
elif [ -n "$OPS_LINE" ]; then
    EXTRA="\U000026a1 ${OPS_LINE}"
elif [ -n "$ACTIVITY" ]; then
    EXTRA="\U000026a1 ${ACTIVITY}"
fi

if [ -n "$EXTRA" ]; then
    OUTPUT="${OUTPUT}\n${EXTRA}"
fi

echo -e "$OUTPUT"
