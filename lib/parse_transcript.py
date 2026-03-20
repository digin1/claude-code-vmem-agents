#!/usr/bin/env python3
"""Extract messages from Claude Code transcript JSONL.

Takes transcript path as argv[1], prints context to stdout.
Handles entry.message.role format (not entry.role).
Includes tool_use summaries. Last 80 entries.
"""
import sys
import json
import warnings

warnings.filterwarnings("ignore")


def parse_transcript(path):
    """Parse a Claude Code transcript JSONL file and return recent messages."""
    messages = []
    try:
        with open(path, "r") as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                except Exception:
                    continue

                # Transcript wraps messages: entry.message.role / entry.message.content
                msg = entry.get("message", entry)  # fallback to entry itself
                role = msg.get("role", entry.get("role", ""))
                raw_content = msg.get("content", entry.get("content"))

                if role == "user":
                    content = ""
                    if isinstance(raw_content, str):
                        content = raw_content
                    elif isinstance(raw_content, list):
                        for part in raw_content:
                            if isinstance(part, dict) and part.get("type") == "text":
                                content += part.get("text", "") + " "
                    content = content.strip()
                    if 5 < len(content) < 2000:
                        messages.append(f"[user]: {content[:500]}")

                elif role == "assistant":
                    if isinstance(raw_content, str):
                        text = raw_content.strip()
                        if 10 < len(text) < 2000:
                            messages.append(f"[assistant]: {text[:500]}")
                    elif isinstance(raw_content, list):
                        text_parts = []
                        tool_parts = []
                        for part in raw_content:
                            if not isinstance(part, dict):
                                continue
                            ptype = part.get("type", "")
                            if ptype == "text":
                                t = part.get("text", "").strip()
                                if t:
                                    text_parts.append(t[:300])
                            elif ptype == "tool_use":
                                tool_name = part.get("name", "?")
                                tool_input = part.get("input", {})
                                # Extract meaningful summary from tool input
                                desc = ""
                                if isinstance(tool_input, dict):
                                    desc = (
                                        tool_input.get("description", "")
                                        or (tool_input.get("prompt") or "")[:100]
                                        or (tool_input.get("command") or "")[:100]
                                        or tool_input.get("file_path", "")
                                        or tool_input.get("pattern", "")
                                        or tool_input.get("query", "")
                                        or tool_input.get("skill", "")
                                        or ""
                                    )
                                if desc:
                                    tool_parts.append(f"{tool_name}({desc[:80]})")
                                else:
                                    tool_parts.append(tool_name)
                            # Skip 'thinking' blocks -- not useful for memory extraction
                        if text_parts:
                            messages.append(
                                f"[assistant]: {' '.join(text_parts)[:500]}"
                            )
                        if tool_parts:
                            messages.append(f"[tools]: {', '.join(tool_parts)}")
    except Exception:
        pass

    return messages[-80:]


def main():
    if len(sys.argv) < 2:
        print("Usage: parse_transcript.py <transcript_path>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    messages = parse_transcript(path)
    print("\n".join(messages))


if __name__ == "__main__":
    main()
