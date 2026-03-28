#!/usr/bin/env python3
"""Agent fleet dashboard — aggregates agent inventory, usage, and evaluations."""

import json
import os
import sys
import glob
import warnings
from collections import Counter

warnings.filterwarnings("ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.chroma_client import get_collection as _get_collection

LEDGER_PATH = os.path.expanduser("~/.claude/agent-usage.jsonl")


def get_agents():
    """Collect all active and retired agents."""
    agents = []
    dirs = [
        ("user", os.path.expanduser("~/.claude/agents")),
        ("project", ".claude/agents"),
    ]

    for scope, d in dirs:
        for f in sorted(glob.glob(os.path.join(d, "*.md"))):
            try:
                with open(f) as fh:
                    content = fh.read()
                meta = parse_frontmatter(content)
                agents.append({
                    "path": os.path.abspath(f),
                    "filename": os.path.basename(f),
                    "name": meta.get("name", os.path.basename(f).replace(".md", "")),
                    "scope": scope,
                    "model": meta.get("model", "inherit"),
                    "description": meta.get("description", ""),
                    "tools": meta.get("tools", []),
                    "status": "active",
                })
            except:
                pass

        # Also check retired (in cortex dir, not agents/ — avoids Claude Code discovery)
        retired_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), ".retired")
        if os.path.isdir(retired_dir):
            for f in sorted(glob.glob(os.path.join(retired_dir, "*.md"))):
                try:
                    with open(f) as fh:
                        content = fh.read()
                    meta = parse_frontmatter(content)
                    agents.append({
                        "path": os.path.abspath(f),
                        "filename": os.path.basename(f),
                        "name": meta.get("name", os.path.basename(f).replace(".md", "")),
                        "scope": scope,
                        "model": meta.get("model", "inherit"),
                        "description": meta.get("description", "")[:80],
                        "status": "retired",
                    })
                except:
                    pass

    return agents


def parse_frontmatter(content):
    """Extract YAML frontmatter fields."""
    meta = {}
    if not content.startswith("---"):
        return meta
    parts = content.split("---", 2)
    if len(parts) < 3:
        return meta
    for line in parts[1].strip().split("\n"):
        if ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key == "tools":
                continue  # multi-line, skip
            meta[key] = val
    return meta


def get_usage_stats():
    """Read agent usage ledger."""
    counts = Counter()
    last_used = {}
    first_used = {}

    if not os.path.exists(LEDGER_PATH):
        return counts, last_used, first_used

    try:
        with open(LEDGER_PATH) as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    name = e.get("agent", "?")
                    ts = e.get("timestamp", "")
                    counts[name] += 1
                    last_used[name] = ts
                    if name not in first_used:
                        first_used[name] = ts
                except:
                    pass
    except:
        pass

    return counts, last_used, first_used


def get_eval_scores():
    """Fetch latest evaluation scores from cortex."""
    scores = {}
    try:
        col = _get_collection()
        data = col.get(where={"type": "agent_eval"})
        if not data or not data.get("ids") or not data.get("metadatas") or not data.get("documents"):
            return scores

        metadatas = data["metadatas"] or []
        documents = data["documents"] or []

        for i in range(len(data["ids"])):
            meta = metadatas[i]
            name = meta.get("agent_name", "?")
            score = meta.get("score", "?")
            ts = meta.get("timestamp", "")
            content = documents[i]

            # Keep only the latest eval per agent
            if name not in scores or ts > scores[name]["timestamp"]:
                scores[name] = {
                    "score": score,
                    "timestamp": ts,
                    "notes": content,
                }
    except:
        pass

    return scores


def health_indicator(score, usage_count):
    """Determine health based on score + usage."""
    try:
        s = int(score)
    except:
        return "unknown"

    if s >= 4 and usage_count >= 5:
        return "healthy"
    elif s >= 4 and usage_count < 5:
        return "underused"
    elif s == 3:
        return "needs-attention"
    elif s == 2:
        return "degraded"
    elif s <= 1:
        return "critical"
    return "unknown"


def main():
    filter_name = sys.argv[1] if len(sys.argv) > 1 else None

    agents = get_agents()
    usage_counts, last_used, first_used = get_usage_stats()
    eval_scores = get_eval_scores()

    report = {
        "summary": {
            "total_active": sum(1 for a in agents if a["status"] == "active"),
            "total_retired": sum(1 for a in agents if a["status"] == "retired"),
            "total_usage_events": sum(usage_counts.values()),
            "ledger_exists": os.path.exists(LEDGER_PATH),
        },
        "agents": [],
    }

    for agent in agents:
        name = agent["name"]

        if filter_name and filter_name.lower() not in name.lower():
            continue

        usage = usage_counts.get(name, 0)
        evals = eval_scores.get(name, {})
        score = evals.get("score", "none")

        entry = {
            "name": name,
            "scope": agent["scope"],
            "model": agent["model"],
            "status": agent["status"],
            "description": agent.get("description", "")[:100],
            "path": agent["path"],
            "usage_count": usage,
            "last_used": last_used.get(name, "never"),
            "first_used": first_used.get(name, "never"),
            "eval_score": score,
            "eval_notes": evals.get("notes", "")[:150],
            "eval_date": evals.get("timestamp", "never"),
            "health": health_indicator(score, usage),
        }
        report["agents"].append(entry)

    # Sort: active first, then by usage desc
    report["agents"].sort(key=lambda a: (a["status"] != "active", -a["usage_count"]))

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
