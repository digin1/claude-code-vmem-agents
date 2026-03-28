#!/usr/bin/env python3
"""Read top 20 memories from ChromaDB and output as text."""
import os
import warnings

warnings.filterwarnings("ignore")

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chroma_client import get_collection as _get_collection


def collect_memories():
    """Read memories from ChromaDB and return formatted text."""
    try:
        col = _get_collection()
        data = col.get()
        lines = []
        metadatas = data["metadatas"] or []
        documents = data["documents"] or []
        for i in range(min(20, len(data["ids"]))):
            mem_type = metadatas[i].get("type", "?")
            doc = documents[i][:150]
            lines.append(f"[{mem_type}] {doc}")
        return "\n".join(lines)
    except Exception:
        return ""


def main():
    print(collect_memories())


if __name__ == "__main__":
    main()
