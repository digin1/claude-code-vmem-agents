#!/usr/bin/env python3
"""Index cached documentation in ChromaDB as reference memories.

Scans ~/.claude/docs/ for frameworks with .manifest.json,
creates/updates docs_<framework> reference entries in cortex.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chroma_client import get_collection


def index_all_docs(doc_root=None):
    """Scan doc root and upsert index entries for each cached framework."""
    if doc_root is None:
        doc_root = os.path.expanduser("~/.claude/docs")

    if not os.path.isdir(doc_root):
        return {"indexed": 0}

    try:
        col = get_collection()
    except Exception:
        return {"error": "ChromaDB unavailable"}

    indexed = 0
    for fid in sorted(os.listdir(doc_root)):
        fdir = os.path.join(doc_root, fid)
        manifest_path = os.path.join(fdir, ".manifest.json")
        if not os.path.isfile(manifest_path):
            continue

        try:
            with open(manifest_path) as f:
                manifest = json.load(f)
        except Exception:
            continue

        # Build file listing for the content
        files = []
        for root, _, filenames in os.walk(fdir):
            for fn in filenames:
                if fn.startswith("."):
                    continue
                rel = os.path.relpath(os.path.join(root, fn), fdir)
                files.append(rel)

        file_count = manifest.get("file_count", len(files))
        name = manifest.get("framework_id", fid)
        source_type = manifest.get("source_type", "unknown")
        fetched_at = manifest.get("fetched_at", "")

        # Build descriptive content for semantic search
        key_files = ", ".join(files[:20])
        content = (
            f"Full {name} documentation cached at ~/.claude/docs/{fid}/. "
            f"{file_count} files fetched via {source_type} on {fetched_at}. "
            f"Key files: {key_files}{'...' if len(files) > 20 else ''}. "
            f"Read these files directly with the Read tool for {name} reference."
        )

        col.upsert(
            ids=[f"docs_{fid}"],
            documents=[content[:2000]],
            metadatas=[{
                "type": "reference",
                "tags": f"docs,{fid},knowledge-base",
                "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "doc_path": f"~/.claude/docs/{fid}",
                "file_count": str(file_count),
                "source_type": source_type,
            }],
        )
        indexed += 1

    return {"indexed": indexed}


if __name__ == "__main__":
    result = index_all_docs()
    print(json.dumps(result))
