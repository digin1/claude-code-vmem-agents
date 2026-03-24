#!/bin/bash
# Memory hygiene: dedup, path validation, recall tracking, consolidation
# Called from SessionStart hook (async) — doesn't block the session
#
# Design for long-running projects:
#   - NEVER deletes based on age alone
#   - Merges near-duplicates (keeps longer/better version)
#   - Flags broken file paths (doesn't delete)
#   - Tracks recall usage for relevance scoring
#   - Consolidates 3+ related memories into 1 comprehensive one
#   - Daily cooldown to avoid running every session
#   - flock ensures only one instance runs at a time (prevents stampede)

LIB="$(dirname "$0")/lib"
COOLDOWN_DIR="$HOME/.claude/.cortex_hygiene_cooldown"
ACTIVITY_FILE="$HOME/.claude/.cortex_activity"
LOCK_FILE="$HOME/.claude/.cortex_hygiene.lock"
mkdir -p "$COOLDOWN_DIR"

# Daily cooldown — check BEFORE acquiring lock to fast-exit
TODAY=$(date +%Y-%m-%d)
COOLDOWN_FILE="$COOLDOWN_DIR/hygiene_${TODAY}"

if [ -f "$COOLDOWN_FILE" ]; then
    exit 0
fi

# Acquire exclusive lock (non-blocking) — if another instance is running, exit immediately
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[cortex hygiene] Another instance is already running, skipping"
    exit 0
fi

# Re-check cooldown after acquiring lock (another instance may have just finished)
if [ -f "$COOLDOWN_FILE" ]; then
    exit 0
fi

# Set cooldown BEFORE running so concurrent starters see it immediately
touch "$COOLDOWN_FILE"

echo "[cortex hygiene] Starting memory hygiene..."

# Run hygiene with a 5-minute timeout to prevent runaway processes
RESULT=$(timeout 300 /usr/bin/python3 -W ignore "$LIB/memory_hygiene.py" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 124 ]; then
    echo "[cortex hygiene] Timed out after 5 minutes"
    exit 0
fi

# Parse result for activity update
MERGED=$(echo "$RESULT" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read().split('\n')[-1])
    parts = []
    if d.get('duplicates_merged', 0) > 0:
        parts.append(f\"-{d['duplicates_merged']} dupes\")
    if d.get('llm_duplicates_merged', 0) > 0:
        parts.append(f\"-{d['llm_duplicates_merged']} llm-dupes\")
    if d.get('stale_paths_flagged', 0) > 0:
        parts.append(f\"{d['stale_paths_flagged']} stale\")
    if d.get('recall_stats_updated', 0) > 0:
        parts.append(f\"{d['recall_stats_updated']} tracked\")
    if d.get('memories_consolidated', 0) > 0:
        parts.append(f\"-{d['memories_consolidated']} consolidated\")
    if parts:
        print('hygiene: ' + ', '.join(parts))
    else:
        print('')
except: print('')
" 2>/dev/null)

if [ -n "$MERGED" ]; then
    EXISTING=""
    if [ -f "$ACTIVITY_FILE" ]; then
        EXISTING=$(cat "$ACTIVITY_FILE" 2>/dev/null)
    fi
    if [ -n "$EXISTING" ]; then
        echo "$EXISTING | $MERGED" > "$ACTIVITY_FILE"
    else
        echo "$MERGED" > "$ACTIVITY_FILE"
    fi
    echo "[cortex hygiene] $MERGED"
else
    echo "[cortex hygiene] No changes needed"
fi

# Clean old cooldown files (>7 days)
find "$COOLDOWN_DIR" -name "hygiene_*" -mtime +7 -delete 2>/dev/null

exit 0
