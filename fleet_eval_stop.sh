#!/bin/bash
# Fleet evaluation on Stop hook — lightweight check for long sessions
# Only fires when >= 5 agent spawns today; reads ChromaDB directly (no claude -p)
# Output: systemMessage (the only injection Stop hooks support)

INPUT=$(cat 2>/dev/null)

VMEM_HOOK_INPUT="$INPUT" /usr/bin/python3 -W ignore - 2>/dev/null <<'PYEOF'
import sys, json, os, time
from datetime import datetime, timedelta
from collections import Counter

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

LEDGER = os.path.expanduser("~/.claude/agent-usage.jsonl")
TODAY = datetime.now().strftime("%Y-%m-%d")
SEVEN_DAYS_AGO = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%dT00:00:00")

def suppress():
    print(json.dumps({"suppressOutput": True}))
    sys.exit(0)

# ── Step 1: Check agent usage ledger for today's activity ──
if not os.path.exists(LEDGER):
    suppress()

today_count = 0
usage_7d = Counter()   # agent_name -> count in last 7 days
total_usage = Counter() # agent_name -> all-time count

try:
    with open(LEDGER, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except:
                continue
            ts = entry.get("timestamp", "")
            agent = entry.get("agent", "unknown")
            total_usage[agent] += 1

            if ts.startswith(TODAY):
                today_count += 1

            if ts >= SEVEN_DAYS_AGO:
                usage_7d[agent] += 1
except Exception:
    suppress()

# Gate: fewer than 5 agent spawns today => not worth evaluating
if today_count < 5:
    suppress()

# ── Step 2: Pull latest agent_eval scores from ChromaDB ──
eval_scores = {}  # agent_name -> {"score": int, "notes": str, "timestamp": str}

try:
    col = get_collection()

    if col.count() > 0:
        # Fetch all agent_eval entries
        data = col.get(where={"type": "agent_eval"})
        for i in range(len(data["ids"])):
            meta = data["metadatas"][i]
            agent_name = meta.get("agent_name", "")
            if not agent_name:
                continue
            ts = meta.get("timestamp", "")
            score = int(meta.get("score", "0"))

            # Keep the latest eval per agent
            if agent_name not in eval_scores or ts > eval_scores[agent_name]["timestamp"]:
                eval_scores[agent_name] = {
                    "score": score,
                    "notes": data["documents"][i][:150] if data["documents"][i] else "",
                    "timestamp": ts
                }
except Exception:
    # If ChromaDB fails, we can still report usage stats
    pass

# ── Step 3: Build fleet health summary ──

# Discover all known agents (from ledger + evals)
all_agents = set(total_usage.keys()) | set(eval_scores.keys())
# Filter out "general-purpose" — that's the default, not a real agent
all_agents.discard("general-purpose")

# Filter out retired agents (in cortex .retired/ dir)
import glob
RETIRED_DIR = os.path.expanduser("~/.claude/.retired-agents")
retired_names = set()
if os.path.isdir(RETIRED_DIR):
    for f in glob.glob(os.path.join(RETIRED_DIR, "*.md")):
        # Extract agent name from filename and frontmatter
        basename = os.path.basename(f).replace(".md", "")
        retired_names.add(basename)
        try:
            with open(f) as fh:
                for line in fh:
                    if line.startswith("name:"):
                        retired_names.add(line.split(":", 1)[1].strip())
                        break
        except:
            pass
all_agents -= retired_names

if not all_agents:
    suppress()

active_agents = []  # used in last 7 days
flagged = []        # low score AND zero usage in 7 days

for agent in sorted(all_agents):
    uses_7d = usage_7d.get(agent, 0)
    eval_info = eval_scores.get(agent, {})
    score = eval_info.get("score", None)

    if uses_7d > 0:
        active_agents.append(agent)

    # Flag: score <= 2 AND zero usage in 7 days
    if score is not None and score <= 2 and uses_7d == 0:
        flagged.append(f"{agent}: score {score}/5, 0 uses in 7d")

# Build summary
parts = []
parts.append(f"Fleet health: {len(active_agents)} active agent(s) (7d), {len(all_agents)} total, {today_count} spawns today")

if flagged:
    parts.append(f"{len(flagged)} flagged for review: " + "; ".join(flagged))
    parts.append("Consider reviewing with /cortex agents.")

summary = ". ".join(parts)

if not flagged:
    # Everything looks healthy — suppress to avoid noise
    suppress()

# Output systemMessage (the only output format Stop hooks support)
print(json.dumps({
    "systemMessage": f"[cortex fleet] {summary}"
}))
PYEOF
