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

LIB="$(dirname "$0")/lib"
COOLDOWN_DIR="$HOME/.claude/.cortex_hygiene_cooldown"
ACTIVITY_FILE="$HOME/.claude/.cortex_activity"
mkdir -p "$COOLDOWN_DIR"

# Daily cooldown
TODAY=$(date +%Y-%m-%d)
COOLDOWN_FILE="$COOLDOWN_DIR/hygiene_${TODAY}"

if [ -f "$COOLDOWN_FILE" ]; then
    exit 0
fi

echo "[cortex hygiene] Starting memory hygiene..."

# Run hygiene
RESULT=$(/usr/bin/python3 -W ignore "$LIB/memory_hygiene.py" 2>&1)

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

# Set cooldown
touch "$COOLDOWN_FILE"

# Clean old cooldown files (>7 days)
find "$COOLDOWN_DIR" -name "hygiene_*" -mtime +7 -delete 2>/dev/null

exit 0
