#!/bin/bash
# SessionEnd hook: save session summary + cleanup
# Default timeout is 1.5s — Phase 1 runs sync, Phase 2 runs in background
#
# Phase 1 (sync, < 500ms): write session marker, clean temp files
# Phase 2 (background): parse transcript, store session summary

INPUT=$(cat 2>/dev/null)
LIB="$(dirname "$0")/lib"
SESSIONS_LOG="$HOME/.claude/.cortex_sessions.jsonl"
ACTIVITY_FILE="$HOME/.claude/.cortex_activity"

# Parse hook input — separate calls to handle paths with spaces
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('session_id',''),end='')" 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('transcript_path',''),end='')" 2>/dev/null)
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('cwd',''),end='')" 2>/dev/null)
REASON=$(echo "$INPUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('reason',''),end='')" 2>/dev/null)

# ================================================================
# Phase 1: Quick cleanup (sync, < 500ms)
# ================================================================

# Write session marker
TS=$(date -Iseconds)
echo "{\"timestamp\":\"$TS\",\"session_id\":\"$SESSION_ID\",\"reason\":\"$REASON\",\"cwd\":\"$CWD\"}" >> "$SESSIONS_LOG" 2>/dev/null

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

        if [ -n "$CONTEXT" ] && [ ${#CONTEXT} -gt 100 ]; then
            # Store a one-line session summary
            SUMMARY=$(echo "$CONTEXT" | claude -p --model haiku "Summarize this session in ONE sentence (max 100 words). Focus on what was accomplished, not the process. If nothing notable, output: SKIP" 2>/dev/null)

            if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "SKIP" ]; then
                # Use python to safely JSON-encode the summary to avoid quote injection
                SAFE_JSON=$(python3 -c "
import json, sys
s = sys.stdin.read().strip()
print(json.dumps([{'type':'project','id':'session_$(date +%Y%m%d_%H%M)','content':s,'tags':'session-summary,auto'}]))
" <<< "$SUMMARY" 2>/dev/null)
                if [ -n "$SAFE_JSON" ]; then
                    "$LIB/store_memories.py" "$SAFE_JSON"
                fi
            fi
        fi
    ) &
    disown
fi

exit 0
