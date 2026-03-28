#!/usr/bin/env python3
"""Collect cortex memories grouped by project with full content.

Used by agent_bootstrap.sh to provide rich context for agent creation.
Accepts optional comma-separated project filter as argv[1].
Outputs structured text: memories grouped by project, then by type.
"""
import os
import sys
import warnings

warnings.filterwarnings("ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chroma_client import get_client, get_collection as _get_collection


def collect(project_filter=None):
    """Collect memories, optionally filtered by project names."""
    try:
        col = _get_collection()
        data = col.get(include=["documents", "metadatas"])
    except Exception:
        return ""

    # Parse filter
    filter_set = None
    if project_filter:
        filter_set = set(p.strip() for p in project_filter.split(",") if p.strip())

    # Group memories: project -> type -> [(id, content, tags)]
    grouped = {}
    for i in range(len(data["ids"])):
        mid = data["ids"][i]
        doc = data["documents"][i]
        meta = data["metadatas"][i]
        mtype = meta.get("type", "general")
        mproject = meta.get("project", "global") or "global"
        tags = meta.get("tags", "")

        if mtype == "agent_eval":
            continue

        # Apply filter if specified
        if filter_set:
            # Include if project matches filter, or it's global/feedback (always useful)
            if mproject not in filter_set and mproject != "global" and mtype != "feedback":
                continue

        if mproject not in grouped:
            grouped[mproject] = {}
        if mtype not in grouped[mproject]:
            grouped[mproject][mtype] = []
        grouped[mproject][mtype].append((mid, doc, tags))

    # Format output
    lines = []
    type_order = ["user", "feedback", "project", "reference"]
    for project in sorted(grouped.keys()):
        lines.append(f"\n=== Project: {project} ===")
        for mtype in type_order:
            items = grouped[project].get(mtype, [])
            if not items:
                continue
            lines.append(f"\n  [{mtype}] ({len(items)} memories)")
            for mid, doc, tags in items:
                tag_str = f" (tags: {tags})" if tags else ""
                lines.append(f"    {mid}{tag_str}:")
                lines.append(f"      {doc}")

    return "\n".join(lines)


def main():
    project_filter = sys.argv[1] if len(sys.argv) > 1 else None
    print(collect(project_filter))


if __name__ == "__main__":
    main()
