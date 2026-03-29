#!/bin/bash
# SessionEnd hook: save session summary + cleanup
# Default timeout is 1.5s — Phase 1 runs sync, Phase 2 runs in background
#
# Phase 1 (sync, < 500ms): write session marker, clean temp files
# Phase 2 (background): parse transcript, store session summary
#
# Note: Learning extraction is handled by learn.sh (Stop hook) which spawns
# its own background process. This hook only handles summary + cleanup.

INPUT=$(cat 2>/dev/null)
LIB="$(dirname "$0")/lib"
SESSIONS_LOG="$HOME/.claude/.cortex_sessions.jsonl"
ACTIVITY_FILE="$HOME/.claude/.cortex_activity"

# Parse hook input — separate calls to handle paths with spaces
SESSION_ID=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('session_id',''),end='')" 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('transcript_path',''),end='')" 2>/dev/null)
CWD=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('cwd',''),end='')" 2>/dev/null)
REASON=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('reason',''),end='')" 2>/dev/null)

# ================================================================
# Phase 1: Quick cleanup (sync, < 500ms)
# ================================================================

# Write session marker (use Python for safe JSON encoding)
/usr/bin/python3 - "$SESSION_ID" "$REASON" "$CWD" "$SESSIONS_LOG" 2>/dev/null <<'PYEOF'
import json, sys, time
ts = time.strftime('%Y-%m-%dT%H:%M:%S%z')
entry = {'timestamp': ts, 'session_id': sys.argv[1], 'reason': sys.argv[2], 'cwd': sys.argv[3]}
with open(sys.argv[4], 'a') as f:
    f.write(json.dumps(entry) + '\n')
PYEOF

# Clean activity file
rm -f "$ACTIVITY_FILE" 2>/dev/null

# Clean temp files older than 24h
find /tmp -maxdepth 1 -name "cortex-*" -mtime +1 -delete 2>/dev/null

# ================================================================
# Phase 2: Session summary (background fork)
# ================================================================
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    (
        # Parse last 20 entries from transcript
        CONTEXT=$("$LIB/parse_transcript.py" "$TRANSCRIPT" 2>/dev/null | tail -c 2000)

        if [ -n "$CONTEXT" ] && [ ${#CONTEXT} -gt 100 ] && [ -n "$ANTHROPIC_API_KEY" ]; then
            # Store a one-line session summary
            # NOTE: Requires ANTHROPIC_API_KEY — claude -p with OAuth invalidates the user's session token
            SUMMARY=$(echo "$CONTEXT" | claude -p --bare --model haiku "Summarize this session in ONE sentence (max 100 words). Focus on what was accomplished, not the process. If nothing notable, output: SKIP" 2>/dev/null)

            if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "SKIP" ]; then
                # Use python to safely JSON-encode the summary to avoid quote injection
                SESSION_TS=$(date +%Y%m%d_%H%M)
                SAFE_JSON=$(printf '%s' "$SUMMARY" | /usr/bin/python3 -W ignore -c "
import json, sys
s = sys.stdin.read().strip()
session_ts = sys.argv[1] if len(sys.argv) > 1 else 'unknown'
print(json.dumps([{'type':'project','id':f'session_{session_ts}','content':s,'tags':'session-summary,auto'}]))
" "$SESSION_TS" 2>/dev/null)
                if [ -n "$SAFE_JSON" ]; then
                    "$LIB/store_memories.py" "$SAFE_JSON"
                fi
            fi
        fi
    ) &
    disown
fi

exit 0
