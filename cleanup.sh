#!/bin/bash
# Cleanup: prunes stale memories from ChromaDB
# 1. agent_eval: older than 30 days, keep only latest per agent
# 2. compact_save.sh-sourced: older than 60 days with near-duplicates (cosine < 0.1)
# Called by SessionStart hook

/usr/bin/python3 -W ignore - 2>/dev/null <<'PYEOF'
import os, time, sys
from datetime import datetime, timedelta
from collections import defaultdict

sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

EVAL_MAX_AGE_DAYS = 30
COMPACT_MAX_AGE_DAYS = 60
DUPLICATE_THRESHOLD = 0.1  # cosine distance below this = near-duplicate

try:
    col = get_collection()

    if col.count() == 0:
        print("[cortex cleanup] Nothing to prune (empty collection)")
        sys.exit(0)

    data = col.get(include=["metadatas", "documents", "embeddings"])
    ids = data["ids"]
    metadatas = data["metadatas"]
    documents = data["documents"]

    now = datetime.now()
    eval_cutoff = (now - timedelta(days=EVAL_MAX_AGE_DAYS)).strftime("%Y-%m-%dT%H:%M:%S")
    compact_cutoff = (now - timedelta(days=COMPACT_MAX_AGE_DAYS)).strftime("%Y-%m-%dT%H:%M:%S")

    to_delete = set()
    report = {"eval_old": 0, "compact_dup": 0}

    # ── Phase 1: Prune old agent_eval entries (keep latest per agent) ──
    # Group eval entries by agent_name
    eval_by_agent = defaultdict(list)  # agent_name -> [(index, timestamp)]

    for i in range(len(ids)):
        meta = metadatas[i]
        if meta.get("type") != "agent_eval":
            continue
        agent_name = meta.get("agent_name", "")
        ts = meta.get("timestamp", "")
        if agent_name:
            eval_by_agent[agent_name].append((i, ts))

    for agent_name, entries in eval_by_agent.items():
        if len(entries) <= 1:
            continue
        # Sort by timestamp descending — keep the newest
        entries.sort(key=lambda x: x[1], reverse=True)
        latest_idx, latest_ts = entries[0]

        for idx, ts in entries[1:]:
            # Delete if older than cutoff
            if ts < eval_cutoff:
                to_delete.add(ids[idx])
                report["eval_old"] += 1

    # ── Phase 2: Prune old compact_save.sh duplicates ──
    # Find compact-sourced memories older than 60 days
    compact_old_indices = []
    compact_all_indices = []

    for i in range(len(ids)):
        meta = metadatas[i]
        if meta.get("source") != "compact_save.sh":
            continue
        if meta.get("type") == "agent_eval":
            continue  # already handled above
        ts = meta.get("timestamp", "")
        compact_all_indices.append(i)
        if ts and ts < compact_cutoff:
            compact_old_indices.append(i)

    # For each old compact memory, check if a newer near-duplicate exists
    if compact_old_indices and len(compact_all_indices) > 1:
        for old_idx in compact_old_indices:
            if ids[old_idx] in to_delete:
                continue  # already marked

            old_doc = documents[old_idx]
            if not old_doc:
                continue

            # Query for nearest neighbors to this document
            try:
                results = col.query(
                    query_texts=[old_doc[:500]],
                    n_results=min(5, col.count())
                )

                has_newer_duplicate = False
                for j in range(len(results["ids"][0])):
                    match_id = results["ids"][0][j]
                    match_dist = results["distances"][0][j] if results.get("distances") else 1.0

                    # Skip self
                    if match_id == ids[old_idx]:
                        continue

                    # Check if near-duplicate (cosine distance < threshold)
                    if match_dist < DUPLICATE_THRESHOLD:
                        # Confirm the match is newer
                        match_meta_idx = None
                        for k in range(len(ids)):
                            if ids[k] == match_id:
                                match_meta_idx = k
                                break
                        if match_meta_idx is not None:
                            match_ts = metadatas[match_meta_idx].get("timestamp", "")
                            old_ts = metadatas[old_idx].get("timestamp", "")
                            if match_ts > old_ts:
                                has_newer_duplicate = True
                                break

                if has_newer_duplicate:
                    to_delete.add(ids[old_idx])
                    report["compact_dup"] += 1

            except Exception:
                continue

    # ── Execute deletions ──
    if to_delete:
        col.delete(ids=list(to_delete))

    # ── Report ──
    total = len(to_delete)
    if total > 0:
        parts = []
        if report["eval_old"]:
            parts.append(f"{report['eval_old']} old agent_eval(s)")
        if report["compact_dup"]:
            parts.append(f"{report['compact_dup']} compact duplicate(s)")
        print(f"[cortex cleanup] Pruned {total}: {', '.join(parts)}")
    else:
        print("[cortex cleanup] Nothing to prune")

except Exception as e:
    print(f"[cortex cleanup] Error: {e}")
PYEOF
