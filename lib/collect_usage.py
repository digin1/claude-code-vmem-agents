#!/usr/bin/env python3
"""Read ~/.claude/agent-usage.jsonl ledger and output usage stats text."""
import json
import os
import warnings
from collections import Counter

warnings.filterwarnings("ignore")

LEDGER = os.path.expanduser("~/.claude/agent-usage.jsonl")


def collect_usage():
    """Read usage ledger and return formatted stats string."""
    if not os.path.exists(LEDGER):
        return "No usage data yet"

    counts = Counter()
    last_used = {}
    try:
        with open(LEDGER) as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    name = e.get("agent", "?")
                    counts[name] += 1
                    last_used[name] = e.get("timestamp", "?")
                except Exception:
                    pass
        lines = []
        for name, count in counts.most_common(20):
            lines.append(f"{name}: {count} uses, last={last_used.get(name, '?')}")
        return "\n".join(lines) if lines else "No usage data yet"
    except Exception:
        return "Error reading ledger"


def main():
    print(collect_usage())


if __name__ == "__main__":
    main()
