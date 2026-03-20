#!/usr/bin/env python3
"""Store AI-extracted memories into ChromaDB.

Takes JSON string (claude -p output) as argv[1].
Parses it, deduplicates against ChromaDB (cosine < 0.15), stores new memories.
Handles markdown code fences, regex fallback for JSON extraction.
"""
import sys
import json
import os
import time
import re
import warnings

warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"

DB_PATH = os.path.expanduser("~/.claude/vector-memory-db")
ACTIVITY_FILE = os.path.expanduser("~/.claude/.vmem_activity")


def strip_code_fences(raw):
    """Remove markdown code fences from raw text."""
    raw = raw.strip()
    if raw.startswith("```"):
        lines = raw.split("\n")
        raw = "\n".join(l for l in lines if not l.startswith("```"))
    return raw


def parse_json_array(raw):
    """Parse JSON array from raw text, with regex fallback."""
    raw = strip_code_fences(raw)
    try:
        return json.loads(raw)
    except Exception:
        match = re.search(r"\[.*\]", raw, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except Exception:
                return []
        return []


def store_memories(raw):
    """Parse and store memories, deduplicating against ChromaDB."""
    items = parse_json_array(raw)
    if not isinstance(items, list):
        items = []

    try:
        import chromadb

        client = chromadb.PersistentClient(path=DB_PATH)
        col = client.get_or_create_collection("claude_memories")
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        stored = 0

        for item in items[:5]:
            if not isinstance(item, dict):
                continue
            mem_id = item.get("id", f"compact_auto_{stored}")
            content = item.get("content", "")
            mem_type = item.get("type", "general")
            tags = item.get("tags", "auto-compact")
            if not content or len(content) < 10:
                continue

            existing = col.query(query_texts=[content], n_results=1)
            if (
                existing["distances"]
                and existing["distances"][0]
                and existing["distances"][0][0] < 0.15
            ):
                continue

            col.upsert(
                ids=[mem_id],
                documents=[content],
                metadatas=[
                    {
                        "type": mem_type,
                        "timestamp": ts,
                        "tags": tags,
                        "source": "compact_save.sh",
                    }
                ],
            )
            stored += 1

        if stored > 0:
            with open(ACTIVITY_FILE, "w") as af:
                af.write(f"learned {stored} (AI)")
            print(f"[vmem compact] Stored {stored} AI-extracted memory(ies)")
    except Exception as e:
        print(f"[vmem compact] Memory error: {e}")


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    if not raw:
        sys.exit(0)
    store_memories(raw)


if __name__ == "__main__":
    main()
