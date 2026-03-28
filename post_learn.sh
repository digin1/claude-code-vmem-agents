#!/bin/bash
# PostToolUse hook: periodic learning extraction during the session
# Runs learn.sh with a cooldown (max once per 5 minutes) to avoid
# blocking every tool call. Only triggers after meaningful exchanges.

INPUT=$(cat 2>/dev/null)

COOLDOWN_FILE="/tmp/cortex-postlearn-cooldown"
COOLDOWN_SECONDS=300  # 5 minutes

# Quick cooldown check (no Python, fast exit)
if [ -f "$COOLDOWN_FILE" ]; then
    LAST_RUN=$(stat -c %Y "$COOLDOWN_FILE" 2>/dev/null || stat -f %m "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_RUN ))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        exit 0
    fi
fi

# Touch cooldown immediately to prevent concurrent runs
touch "$COOLDOWN_FILE"

# Forward input to learn.sh (it handles transcript parsing, content check, etc.)
echo "$INPUT" | bash "$(dirname "$0")/learn.sh" 2>/dev/null

exit 0
