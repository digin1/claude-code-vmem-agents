#!/bin/bash
# Auto-learn: called by Stop hook
# Uses systemMessage (the only context injection Stop hooks support)

cat <<'EOF'
{"systemMessage": "[cortex] Session ending. If you learned anything new about the user, their preferences, project decisions, or useful references — store it using the mcp__cortex__memory_store tool. Use descriptive memory_id values and appropriate memory_type (user/feedback/project/reference)."}
EOF
