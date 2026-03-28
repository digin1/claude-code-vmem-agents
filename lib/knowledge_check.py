#!/usr/bin/env python3
"""Check which frameworks need documentation fetching.

Reads detected tech stack (JSON from skill_detect.py) via argv[1],
compares against cached docs at ~/.claude/docs/, returns JSON list
of frameworks needing fetch.
"""
import json
import os
import sys
import time


def load_registry():
    registry_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "knowledge_registry.json")
    with open(registry_path) as f:
        return json.load(f)


def check_needed(stack_json):
    """Compare detected stack against cached docs, return stale/missing."""
    registry = load_registry()
    meta = registry.get("_meta", {})
    freshness_days = meta.get("freshness_days", 7)
    doc_root = os.path.expanduser(meta.get("doc_root", "~/.claude/docs"))
    frameworks_reg = registry.get("frameworks", {})
    user_overrides = registry.get("user_overrides", {})

    try:
        stack = json.loads(stack_json)
    except Exception:
        return "[]"

    detected = stack.get("frameworks", [])
    needed = []

    for fw in detected:
        fid = fw.get("id", "")
        if not fid:
            continue

        doc_dir = os.path.join(doc_root, fid)
        manifest_path = os.path.join(doc_dir, ".manifest.json")

        # Check if docs exist and are fresh
        if os.path.exists(manifest_path):
            try:
                mtime = os.path.getmtime(manifest_path)
                age_days = (time.time() - mtime) / 86400
                if age_days < freshness_days:
                    # Check version match if project specifies one
                    if fw.get("version"):
                        with open(manifest_path) as f:
                            m = json.load(f)
                        if m.get("project_version") == fw["version"]:
                            continue  # same version, still fresh
                    else:
                        continue  # no version to check, still fresh
            except Exception:
                pass  # manifest unreadable, treat as stale

        # Look up sources — user overrides take priority
        if fid in user_overrides:
            sources = user_overrides[fid].get("sources", [])
            name = user_overrides[fid].get("name", fw.get("name", fid))
        elif fid in frameworks_reg:
            sources = frameworks_reg[fid].get("sources", [])
            name = frameworks_reg[fid].get("name", fw.get("name", fid))
        else:
            # Not in registry — context7 auto fallback
            sources = [{"type": "context7_auto", "name": fw.get("name", fid)}]
            name = fw.get("name", fid)

        needed.append({
            "id": fid,
            "name": name,
            "sources": sources,
            "version": fw.get("version", ""),
        })

    return json.dumps(needed)


if __name__ == "__main__":
    stack_json = sys.argv[1] if len(sys.argv) > 1 else "{}"
    print(check_needed(stack_json))
