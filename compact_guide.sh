#!/bin/bash
# PreCompact hook: inject compaction guidance so Claude preserves important context
# Must be FAST (< 2s) — runs before the slower compact_save.sh
# Tells Claude what files were modified, tools used, and key decisions to preserve

INPUT=$(cat 2>/dev/null)

python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os
from collections import Counter

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

transcript_path = d.get("transcript_path", "")
if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(0)

# Quick-parse transcript for files and tools (no LLM needed)
files_modified = set()
files_read = set()
tools_used = Counter()
user_decisions = []

try:
    with open(transcript_path, "r") as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
            except Exception:
                continue

            msg = entry.get("message", entry)
            role = msg.get("role", "")
            content = msg.get("content", "")

            if role == "assistant" and isinstance(content, list):
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "tool_use":
                        tool_name = part.get("name", "")
                        tool_input = part.get("input", {})
                        if not isinstance(tool_input, dict):
                            continue

                        tools_used[tool_name] += 1

                        fp = tool_input.get("file_path", "")
                        if fp:
                            if tool_name in ("Edit", "Write", "NotebookEdit"):
                                files_modified.add(fp)
                            elif tool_name == "Read":
                                files_read.add(fp)

                        # Track Bash commands
                        cmd = tool_input.get("command", "")
                        if cmd and tool_name == "Bash":
                            # Extract file paths from git/docker commands
                            for word in cmd.split():
                                if word.startswith("/") and "." in word:
                                    files_read.add(word)

            # Track user decisions/preferences from short user messages
            elif role == "user" and isinstance(content, str):
                lower = content.lower().strip()
                if any(kw in lower for kw in ["don't", "always", "never", "prefer", "instead", "use", "fix"]):
                    if 10 < len(content) < 200:
                        user_decisions.append(content.strip()[:150])
except Exception:
    pass

# Build preservation guidance
lines = []

if files_modified:
    sorted_files = sorted(files_modified)[:20]
    lines.append("FILES MODIFIED: " + ", ".join(sorted_files))

if files_read:
    # Only show read files not also modified (reduce noise)
    read_only = sorted(files_read - files_modified)[:10]
    if read_only:
        lines.append("FILES READ: " + ", ".join(read_only))

if tools_used:
    top_tools = [f"{t}({c})" for t, c in tools_used.most_common(10)]
    lines.append("TOOLS USED: " + ", ".join(top_tools))

if user_decisions:
    lines.append("USER DECISIONS/PREFERENCES:")
    for dec in user_decisions[-5:]:
        lines.append(f"  - {dec}")

if not lines:
    sys.exit(0)

guidance = "[cortex] COMPACTION GUIDANCE — preserve these in the summary:\n" + "\n".join(lines)

output = json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreCompact",
        "additionalContext": guidance
    }
})
print(output)
PYEOF
