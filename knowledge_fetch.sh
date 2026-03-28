#!/bin/bash
# Knowledge acquisition: downloads framework docs on session start
# Called from SessionStart hook (async: true) — doesn't block the session
#
# Flow:
# 1. Detect tech stack via skill_detect.py
# 2. Check freshness via knowledge_check.py
# 3. Fetch missing docs via knowledge_fetch.py (parallel, max 3)
# 4. Index in cortex via knowledge_index.py
# 5. Set weekly cooldown

INPUT=$(timeout 2 cat 2>/dev/null || true)
LIB="$(dirname "$0")/lib"

# Process lock: only one knowledge_fetch at a time
LOCKFILE="/tmp/cortex-knowledge-fetch.lock"
exec 201>"$LOCKFILE" 2>/dev/null
if ! flock -n 201 2>/dev/null; then
    exit 0
fi
COOLDOWN_DIR="$HOME/.claude/.cortex_docs_cooldown"
DOCS_ROOT="$HOME/.claude/docs"
CORTEX_CONFIG="$HOME/.claude/.cortex_config"
ACTIVITY="$HOME/.claude/.cortex_activity"

mkdir -p "$COOLDOWN_DIR" "$DOCS_ROOT"

# Check if auto_docs is disabled
if grep -q '"auto_docs":false' "$CORTEX_CONFIG" 2>/dev/null; then
    exit 0
fi

# Parse cwd from hook input
CWD=$(/usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(d.get('cwd', ''), end='')
except: pass
" "$INPUT" 2>/dev/null)

if [ -z "$CWD" ]; then
    CWD=$(pwd)
fi

# Detect project name
PROJECT_NAME=$(basename "$CWD" 2>/dev/null)
if [ -z "$PROJECT_NAME" ]; then
    exit 0
fi

# Cooldown: once per project per week
WEEK=$(date +%Y-W%V)
COOLDOWN_FILE="$COOLDOWN_DIR/${PROJECT_NAME}_${WEEK}"
if [ -f "$COOLDOWN_FILE" ]; then
    exit 0
fi

# Timeout: kill self after 180 seconds
( sleep 180; kill $$ 2>/dev/null ) &
WATCHDOG=$!
trap 'kill $WATCHDOG 2>/dev/null; wait $WATCHDOG 2>/dev/null; exit 0' EXIT

# Phase 1: Detect tech stack
STACK=$(/usr/bin/python3 -W ignore "$LIB/skill_detect.py" "$CWD" 2>/dev/null)
if [ -z "$STACK" ]; then
    touch "$COOLDOWN_FILE"
    exit 0
fi

# Check how many frameworks detected
FW_COUNT=$(/usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(len(d.get('frameworks', [])), end='')
except: print(0, end='')
" "$STACK" 2>/dev/null)

if [ "$FW_COUNT" = "0" ]; then
    touch "$COOLDOWN_FILE"
    exit 0
fi

# Phase 2: Check which frameworks need docs
NEEDED=$(/usr/bin/python3 -W ignore "$LIB/knowledge_check.py" "$STACK" 2>/dev/null)
NEEDED_COUNT=$(/usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(len(d) if isinstance(d, list) else 0, end='')
except: print(0, end='')
" "$NEEDED" 2>/dev/null)

if [ "$NEEDED_COUNT" = "0" ]; then
    touch "$COOLDOWN_FILE"
    exit 0
fi

# Phase 3: Fetch docs
echo "fetching docs for $NEEDED_COUNT frameworks" > "$ACTIVITY" 2>/dev/null
FETCH_RESULT=$(echo "$NEEDED" | /usr/bin/python3 -W ignore "$LIB/knowledge_fetch.py" 2>/dev/null)

FETCHED_COUNT=$(/usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(len(d.get('fetched', [])), end='')
except: print(0, end='')
" "$FETCH_RESULT" 2>/dev/null)

# Phase 4: Index in cortex
if [ "$FETCHED_COUNT" -gt 0 ] 2>/dev/null; then
    echo "indexing $FETCHED_COUNT doc caches" > "$ACTIVITY" 2>/dev/null
    /usr/bin/python3 -W ignore "$LIB/knowledge_index.py" 2>/dev/null
fi

# Set cooldown
touch "$COOLDOWN_FILE"

# Final status
if [ "$FETCHED_COUNT" -gt 0 ] 2>/dev/null; then
    echo "cached docs for $FETCHED_COUNT frameworks" > "$ACTIVITY" 2>/dev/null
fi

exit 0
