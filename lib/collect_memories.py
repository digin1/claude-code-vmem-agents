#!/usr/bin/env python3
"""Read top 20 memories from ChromaDB and output as text."""
import os
import warnings

warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"

DB_PATH = os.path.expanduser("~/.claude/vector-memory-db")


def collect_memories():
    """Read memories from ChromaDB and return formatted text."""
    try:
        import chromadb

        client = chromadb.PersistentClient(path=DB_PATH)
        col = client.get_or_create_collection("claude_memories")
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
