#!/bin/bash
# PostCompact hook: extract knowledge from the compact summary
# Complements PreCompact (compact_save.sh) which processes the full transcript
# This processes the COMPRESSED summary — what the compactor deemed important

INPUT=$(cat 2>/dev/null)
LIB="$(dirname "$0")/lib"

# Extract compact_summary and cwd from hook input
read -r SUMMARY CWD < <(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    summary = d.get('compact_summary', '') or ''
    cwd = d.get('cwd', '')
    print(summary[:3000], cwd)
except: print(' ')
" 2>/dev/null)

if [ -z "$SUMMARY" ] || [ ${#SUMMARY} -lt 50 ]; then
    exit 0
fi

echo "[cortex post-compact] Processing compact summary (${#SUMMARY} chars)..."

# Extract memories from the compact summary using haiku
EXTRACTED=$(echo "$SUMMARY" | claude -p --model haiku "You are a memory extraction system. This is a COMPRESSED conversation summary. Extract ONLY items worth remembering for future sessions.

Output a valid JSON array. Each item: {\"type\": \"feedback|project|reference\", \"id\": \"short_snake_id\", \"content\": \"one sentence\", \"tags\": \"comma,separated\"}

Rules:
- feedback: user corrections, preferences, workflow rules
- project: technical decisions, architecture, deployment notes
- reference: file paths, commands, endpoints
- Skip routine work, things obvious from code
- Max 3 items (this is already compressed — only key insights)
- Content must be self-contained
- If nothing worth remembering, return: []" 2>/dev/null)

if [ -n "$EXTRACTED" ]; then
    "$LIB/store_memories.py" "$EXTRACTED"
fi
