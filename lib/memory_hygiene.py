#!/usr/bin/env python3
"""Memory hygiene: dedup, path validation, recall tracking, consolidation.

Designed for long-running projects where memories accumulate over months.
NEVER auto-deletes based on age. Only merges duplicates and consolidates
related memories to keep the database clean and useful.

Phases:
  1. Dedup — merge near-duplicate memories (embedding distance < 0.35)
  1b. LLM dedup — Haiku judges borderline pairs (0.35-0.55) as true dupes
  2. Path validation — flag memories with broken file paths (no LLM)
  3. Recall tracking — update last_recalled from recall log (no LLM)
  4. Consolidation — merge 3+ related memories per project (haiku)

Returns JSON summary of actions taken.
"""
import hashlib
import json
import os
import re
import subprocess
import time
import warnings
from collections import defaultdict

warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["ONNXRUNTIME_SESSION_THREAD_POOL_SIZE"] = "2"

# Suppress onnxruntime noise
_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2)
os.close(_dn)
try:
    import chromadb
finally:
    os.dup2(_fd, 2)
    os.close(_fd)

DB_PATH = os.path.expanduser("~/.claude/cortex-db")
RECALL_LOG = os.path.expanduser("~/.claude/.cortex_recall_log")
ACTIVITY_FILE = os.path.expanduser("~/.claude/.cortex_activity")
AUDIT_LOG = os.path.expanduser("~/.claude/.cortex_audit.jsonl")

# Path patterns to extract from memory content
PATH_REGEX = re.compile(r'(/(?:home|app|remote|colin|tmp|local|usr|dev|zqiu)[/\w.\-]+)')

# NAS paths that may not be mounted — skip validation for these
NAS_PREFIXES = ("/remote/", "/colin/")


def get_collection():
    client = chromadb.PersistentClient(path=DB_PATH)
    return client.get_or_create_collection("claude_memories")


def get_all_memories(col):
    """Fetch all memories with full content and metadata."""
    data = col.get(include=["documents", "metadatas"])
    memories = []
    for i in range(len(data["ids"])):
        memories.append({
            "id": data["ids"][i],
            "content": data["documents"][i],
            "metadata": data["metadatas"][i],
        })
    return memories


# ================================================================
# Phase 1: Duplicate Detection & Merge
# ================================================================
def phase_dedup(col, memories):
    """Find near-duplicate memories and merge them.

    For each memory, find its nearest neighbor in the same type.
    If distance < 0.35 (very similar), keep the longer/more detailed one.
    Returns count of memories merged (deleted).
    """
    if len(memories) < 2:
        return 0

    merged = 0
    deleted_ids = set()

    for mem in memories:
        if mem["id"] in deleted_ids:
            continue

        mtype = mem["metadata"].get("type", "general")
        if mtype == "agent_eval":
            continue

        # Query for nearest neighbor (excluding self)
        try:
            results = col.query(
                query_texts=[mem["content"]],
                n_results=min(3, col.count()),
            )
        except Exception:
            continue

        for i in range(len(results["ids"][0])):
            neighbor_id = results["ids"][0][i]
            if neighbor_id == mem["id"] or neighbor_id in deleted_ids:
                continue

            dist = results["distances"][0][i] if results.get("distances") else 1.0
            neighbor_meta = results["metadatas"][0][i]
            neighbor_type = neighbor_meta.get("type", "general")

            # Only merge same-type memories
            if neighbor_type != mtype:
                continue

            # Threshold: < 0.35 = very similar content
            if dist < 0.35:
                neighbor_content = results["documents"][0][i]

                # Keep the longer/more detailed memory
                if len(mem["content"]) >= len(neighbor_content):
                    keep_id, delete_id = mem["id"], neighbor_id
                    keep_content = mem["content"]
                    keep_meta = mem["metadata"]
                else:
                    keep_id, delete_id = neighbor_id, mem["id"]
                    keep_content = neighbor_content
                    keep_meta = neighbor_meta

                # Preserve tags and project from both
                keep_tags = set((keep_meta.get("tags", "") or "").split(","))
                delete_meta_lookup = {m["id"]: m["metadata"] for m in memories}
                if delete_id in delete_meta_lookup:
                    delete_tags = set((delete_meta_lookup[delete_id].get("tags", "") or "").split(","))
                    keep_tags |= delete_tags
                keep_tags.discard("")

                # Update the keeper with merged tags
                updated_meta = dict(keep_meta)
                updated_meta["tags"] = ",".join(sorted(keep_tags))
                updated_meta["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                updated_meta["merged_from"] = delete_id

                try:
                    col.update(ids=[keep_id], metadatas=[updated_meta])
                    col.delete(ids=[delete_id])
                    deleted_ids.add(delete_id)
                    merged += 1
                    print(f"[hygiene] Merged '{delete_id}' into '{keep_id}' (dist={dist:.3f})")
                except Exception as e:
                    print(f"[hygiene] Merge failed: {e}")

                break  # One merge per memory per pass

    return merged


# ================================================================
# Phase 1b: LLM Semantic Dedup (borderline pairs)
# ================================================================
def phase_llm_dedup(col, memories):
    """Use Haiku to judge borderline-similar memory pairs (dist 0.35-0.55).

    Embedding distance catches near-identical wording but misses memories
    that say the same thing in different words. Haiku can reason about
    whether two memories are truly redundant or complementary.

    Returns count of memories merged.
    """
    if len(memories) < 2:
        return 0

    merged = 0
    deleted_ids = set()
    # Collect candidate pairs first, then batch-judge with Haiku
    candidates = []

    for mem in memories:
        if mem["id"] in deleted_ids:
            continue
        mtype = mem["metadata"].get("type", "general")
        if mtype == "agent_eval":
            continue

        try:
            results = col.query(
                query_texts=[mem["content"]],
                n_results=min(5, col.count()),
            )
        except Exception:
            continue

        for i in range(len(results["ids"][0])):
            nid = results["ids"][0][i]
            if nid == mem["id"] or nid in deleted_ids:
                continue

            dist = results["distances"][0][i] if results.get("distances") else 1.0
            ntype = results["metadatas"][0][i].get("type", "general")

            # Only same-type, borderline range (0.35-0.55)
            if ntype != mtype or dist < 0.35 or dist >= 0.55:
                continue

            # Avoid duplicate pairs (A,B) and (B,A)
            pair_key = tuple(sorted([mem["id"], nid]))
            if pair_key not in {tuple(sorted([c[0]["id"], c[1]["id"]])) for c in candidates}:
                neighbor_mem = {
                    "id": nid,
                    "content": results["documents"][0][i],
                    "metadata": results["metadatas"][0][i],
                }
                candidates.append((mem, neighbor_mem, dist))

    if not candidates:
        return 0

    # Batch up to 10 pairs per Haiku call to save tokens
    for batch_start in range(0, len(candidates), 10):
        batch = candidates[batch_start:batch_start + 10]
        # Skip pairs where one was already deleted in this batch
        batch = [(a, b, d) for a, b, d in batch
                 if a["id"] not in deleted_ids and b["id"] not in deleted_ids]
        if not batch:
            continue

        pairs_text = []
        for idx, (a, b, dist) in enumerate(batch):
            pairs_text.append(
                f"PAIR {idx}:\n"
                f"  A [{a['id']}]: {a['content'][:300]}\n"
                f"  B [{b['id']}]: {b['content'][:300]}\n"
                f"  Distance: {dist:.3f}"
            )

        prompt = (
            "Judge whether each memory pair is a TRUE DUPLICATE (same information, "
            "just worded differently) or COMPLEMENTARY (each has unique info worth keeping).\n\n"
            + "\n\n".join(pairs_text) +
            "\n\nFor each pair, output a JSON array of objects:\n"
            '[{"pair": 0, "verdict": "duplicate" or "keep_both", '
            '"keep": "A" or "B" (if duplicate, which is better)}]\n'
            "Output ONLY the JSON array, no explanation."
        )

        try:
            result = subprocess.run(
                ["claude", "-p", "--model", "haiku", "--max-turns", "1"],
                input=prompt, capture_output=True, text=True, timeout=15
            )
            if result.returncode != 0:
                continue

            raw = result.stdout.strip()
            # Strip code fences if present
            if raw.startswith("```"):
                raw = "\n".join(l for l in raw.split("\n") if not l.startswith("```"))

            try:
                verdicts = json.loads(raw)
            except Exception:
                match = re.search(r'\[.*\]', raw, re.DOTALL)
                if match:
                    verdicts = json.loads(match.group())
                else:
                    continue

            for v in verdicts:
                pair_idx = v.get("pair", -1)
                if pair_idx < 0 or pair_idx >= len(batch):
                    continue
                if v.get("verdict") != "duplicate":
                    continue

                a, b, dist = batch[pair_idx]
                if a["id"] in deleted_ids or b["id"] in deleted_ids:
                    continue

                keep_which = v.get("keep", "A")
                if keep_which == "B":
                    keep, delete = b, a
                else:
                    keep, delete = a, b

                # Merge tags
                keep_tags = set((keep["metadata"].get("tags", "") or "").split(","))
                del_tags = set((delete["metadata"].get("tags", "") or "").split(","))
                keep_tags |= del_tags
                keep_tags.discard("")

                updated_meta = dict(keep["metadata"])
                updated_meta["tags"] = ",".join(sorted(keep_tags))
                updated_meta["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                updated_meta["merged_from"] = delete["id"]

                try:
                    col.update(ids=[keep["id"]], metadatas=[updated_meta])
                    col.delete(ids=[delete["id"]])
                    deleted_ids.add(delete["id"])
                    merged += 1
                    print(f"[hygiene-llm] Merged '{delete['id']}' into '{keep['id']}' (dist={dist:.3f}, haiku-judged)")
                except Exception as e:
                    print(f"[hygiene-llm] Merge failed: {e}")

        except subprocess.TimeoutExpired:
            print("[hygiene-llm] Haiku timed out for batch")
        except Exception as e:
            print(f"[hygiene-llm] Batch failed: {e}")

    return merged


# ================================================================
# Phase 2: Path Validation
# ================================================================
def phase_path_validation(col, memories):
    """Check file paths mentioned in memories and flag broken ones.

    Skips NAS paths (/remote/, /colin/) since they may not be mounted.
    Adds 'stale_path' to tags and 'stale_paths' to metadata for broken paths.
    NEVER deletes — just flags for awareness.
    """
    flagged = 0

    for mem in memories:
        mtype = mem["metadata"].get("type", "general")
        if mtype == "agent_eval":
            continue

        # Extract file paths from content
        paths = PATH_REGEX.findall(mem["content"])
        if not paths:
            continue

        broken = []
        for path in paths:
            # Skip NAS paths — they require network mounts
            if any(path.startswith(p) for p in NAS_PREFIXES):
                continue
            # Skip container-internal paths
            if path.startswith("/app/") or path.startswith("/dev/"):
                continue
            # Check if the path exists on local filesystem
            if not os.path.exists(path):
                broken.append(path)

        if broken:
            tags = set((mem["metadata"].get("tags", "") or "").split(","))
            already_flagged = "stale_path" in tags

            if not already_flagged:
                tags.add("stale_path")
                tags.discard("")
                updated_meta = dict(mem["metadata"])
                updated_meta["tags"] = ",".join(sorted(tags))
                updated_meta["stale_paths"] = ",".join(broken[:5])
                updated_meta["stale_checked"] = time.strftime("%Y-%m-%dT%H:%M:%S")

                try:
                    col.update(ids=[mem["id"]], metadatas=[updated_meta])
                    flagged += 1
                    print(f"[hygiene] Flagged '{mem['id']}': broken paths {broken[:3]}")
                except Exception:
                    pass

    return flagged


# ================================================================
# Phase 3: Recall Tracking
# ================================================================
def phase_recall_tracking(col, memories):
    """Update last_recalled and recall_count from the recall log.

    recall.sh appends lines like:
      2026-03-20T01:05:00 mem_id_1,mem_id_2,mem_id_3
    """
    if not os.path.exists(RECALL_LOG):
        return 0

    # Parse recall log
    recall_counts = defaultdict(int)
    last_recalled = {}

    try:
        with open(RECALL_LOG) as f:
            for line in f:
                line = line.strip()
                if not line or " " not in line:
                    continue
                ts, ids_str = line.split(" ", 1)
                for mid in ids_str.split(","):
                    mid = mid.strip()
                    if mid:
                        recall_counts[mid] += 1
                        if mid not in last_recalled or ts > last_recalled[mid]:
                            last_recalled[mid] = ts
    except Exception:
        return 0

    # Update memory metadata
    updated = 0
    for mem in memories:
        mid = mem["id"]
        if mid not in recall_counts:
            continue

        current_count = int(mem["metadata"].get("recall_count", "0") or "0")
        current_last = mem["metadata"].get("last_recalled", "")

        new_count = recall_counts[mid]
        new_last = last_recalled.get(mid, "")

        # Only update if there's new data
        if new_count > current_count or new_last > current_last:
            updated_meta = dict(mem["metadata"])
            updated_meta["recall_count"] = str(max(new_count, current_count))
            updated_meta["last_recalled"] = max(new_last, current_last)

            try:
                col.update(ids=[mid], metadatas=[updated_meta])
                updated += 1
            except Exception:
                pass

    # Rotate recall log (keep last 7 days of entries)
    # Use atomic write (temp file + rename) to avoid race with recall.sh appending
    try:
        import tempfile
        cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - 7 * 86400))
        kept_lines = []
        with open(RECALL_LOG) as f:
            for line in f:
                if line[:10] >= cutoff:
                    kept_lines.append(line)
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(RECALL_LOG))
        try:
            with os.fdopen(tmp_fd, "w") as f:
                f.writelines(kept_lines)
            os.replace(tmp_path, RECALL_LOG)
        except Exception:
            os.unlink(tmp_path)
    except Exception:
        pass

    return updated


# ================================================================
# Phase 4: Consolidation (uses claude -p haiku)
# ================================================================
def phase_consolidation(col, memories):
    """Merge 3+ related memories per project into comprehensive ones.

    Groups by (project, type), finds clusters via nearest-neighbor chains.
    Uses haiku to write a consolidated memory that preserves all unique info.
    ONLY consolidates project and reference types (not user/feedback).
    """
    # Group by (project, type)
    groups = defaultdict(list)
    for mem in memories:
        mtype = mem["metadata"].get("type", "general")
        project = mem["metadata"].get("project", "global")
        # Only consolidate project and reference types
        if mtype in ("project", "reference"):
            groups[(project, mtype)].append(mem)

    consolidated = 0

    for (project, mtype), group_mems in groups.items():
        if len(group_mems) < 3:
            # Need 3+ to make consolidation worthwhile
            continue

        # Find clusters within this group using nearest-neighbor
        clusters = _find_clusters(col, group_mems, threshold=0.5)

        for cluster in clusters:
            if len(cluster) < 3:
                continue

            # Build consolidation prompt
            mem_texts = []
            for mem in cluster:
                mem_texts.append(f"[{mem['id']}]: {mem['content']}")

            prompt_input = "\n\n".join(mem_texts)

            try:
                result = subprocess.run(
                    ["claude", "-p", "--model", "haiku", "--mcp-config", "{}", "--strict-mcp-config"],
                    input=f"""Consolidate these related memories into 1 comprehensive memory.

MEMORIES TO CONSOLIDATE:
{prompt_input}

RULES:
- Preserve ALL unique facts, paths, commands, gotchas, and decisions
- Eliminate only pure redundancy (same fact stated multiple ways)
- Structure clearly: what it is, key details, gotchas/warnings
- The consolidated memory must be self-contained
- Keep it concise but complete — every unique fact from the originals must appear
- Project: {project}, Type: {mtype}

Output ONLY a JSON object (no markdown):
{{"id": "descriptive_snake_case_id", "content": "consolidated text", "tags": "comma,separated"}}""",
                    capture_output=True, text=True, timeout=60
                )

                if result.returncode != 0:
                    continue

                # Parse output
                raw = result.stdout.strip()
                # Strip code fences if present
                if raw.startswith("```"):
                    raw = "\n".join(l for l in raw.split("\n") if not l.startswith("```"))

                try:
                    consolidated_mem = json.loads(raw)
                except Exception:
                    match = re.search(r'\{.*\}', raw, re.DOTALL)
                    if match:
                        consolidated_mem = json.loads(match.group())
                    else:
                        continue

                new_id = consolidated_mem.get("id", f"consolidated_{project}_{mtype}")
                new_content = consolidated_mem.get("content", "")
                new_tags = consolidated_mem.get("tags", "")

                if not new_content or len(new_content) < 20:
                    continue

                # Store consolidated memory
                original_ids = [m["id"] for m in cluster]
                col.upsert(
                    ids=[new_id],
                    documents=[new_content],
                    metadatas=[{
                        "type": mtype,
                        "project": project,
                        "tags": new_tags,
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "consolidated_from": ",".join(original_ids),
                        "source": "memory_hygiene",
                    }]
                )

                # Delete originals (only if consolidation succeeded)
                for mem in cluster:
                    if mem["id"] != new_id:  # Don't delete if ID reused
                        try:
                            col.delete(ids=[mem["id"]])
                        except Exception:
                            pass

                consolidated += len(cluster) - 1  # Net reduction
                print(f"[hygiene] Consolidated {len(cluster)} memories → '{new_id}' [{project}/{mtype}]")

            except subprocess.TimeoutExpired:
                print(f"[hygiene] Consolidation timed out for cluster in {project}/{mtype}")
            except Exception as e:
                print(f"[hygiene] Consolidation failed: {e}")

    return consolidated


def _find_clusters(col, memories, threshold=0.5):
    """Find clusters of related memories using nearest-neighbor chaining.

    Simple approach: for each memory, find neighbors within threshold.
    Merge overlapping neighbor sets into clusters.
    """
    # Build adjacency list
    neighbors = defaultdict(set)
    id_to_mem = {m["id"]: m for m in memories}
    ids = [m["id"] for m in memories]

    for mem in memories:
        try:
            results = col.query(
                query_texts=[mem["content"]],
                n_results=min(len(memories), col.count()),
            )
            for i in range(len(results["ids"][0])):
                nid = results["ids"][0][i]
                dist = results["distances"][0][i] if results.get("distances") else 1.0
                if nid != mem["id"] and nid in id_to_mem and dist < threshold:
                    neighbors[mem["id"]].add(nid)
                    neighbors[nid].add(mem["id"])
        except Exception:
            pass

    # Merge overlapping neighbor sets into clusters (union-find style)
    visited = set()
    clusters = []

    for mid in ids:
        if mid in visited or mid not in neighbors:
            continue
        # BFS to find connected component
        cluster = []
        queue = [mid]
        while queue:
            current = queue.pop(0)
            if current in visited:
                continue
            visited.add(current)
            if current in id_to_mem:
                cluster.append(id_to_mem[current])
            for neighbor in neighbors.get(current, set()):
                if neighbor not in visited:
                    queue.append(neighbor)
        if len(cluster) >= 3:
            clusters.append(cluster)

    return clusters


# ================================================================
# Main
# ================================================================
def run_hygiene():
    """Run all hygiene phases and return summary."""
    col = get_collection()
    memories = get_all_memories(col)

    # Filter out agent_eval for processing
    memories = [m for m in memories if m["metadata"].get("type") != "agent_eval"]

    if len(memories) < 2:
        return {"status": "skipped", "reason": "too few memories"}

    summary = {"total_before": len(memories)}

    # Phase 1: Embedding-based dedup (distance < 0.35)
    merged = phase_dedup(col, memories)
    summary["duplicates_merged"] = merged

    # Refresh memories after dedup
    if merged > 0:
        memories = [m for m in get_all_memories(col)
                    if m["metadata"].get("type") != "agent_eval"]

    # Phase 1b: LLM semantic dedup (borderline pairs 0.35-0.55)
    llm_merged = phase_llm_dedup(col, memories)
    summary["llm_duplicates_merged"] = llm_merged

    # Refresh memories after LLM dedup
    if llm_merged > 0:
        memories = [m for m in get_all_memories(col)
                    if m["metadata"].get("type") != "agent_eval"]

    # Phase 2: Path validation
    flagged = phase_path_validation(col, memories)
    summary["stale_paths_flagged"] = flagged

    # Phase 3: Recall tracking
    tracked = phase_recall_tracking(col, memories)
    summary["recall_stats_updated"] = tracked

    # Phase 4: Consolidation (only if 15+ memories — worth the haiku cost)
    if len(memories) >= 15:
        consolidated = phase_consolidation(col, memories)
        summary["memories_consolidated"] = consolidated
    else:
        summary["memories_consolidated"] = 0
        summary["consolidation_skipped"] = "fewer than 15 memories"

    # Final count
    final_memories = get_all_memories(col)
    final_count = len([m for m in final_memories if m["metadata"].get("type") != "agent_eval"])
    summary["total_after"] = final_count

    return summary


def main():
    try:
        summary = run_hygiene()
        print(json.dumps(summary, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}))


if __name__ == "__main__":
    main()
