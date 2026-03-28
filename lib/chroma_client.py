"""Shared ChromaDB client — HttpClient (fast) with PersistentClient fallback.

Usage:
    from lib.chroma_client import get_client, get_collection
"""
import os
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("ONNXRUNTIME_DISABLE_TELEMETRY", "1")
os.environ.setdefault("ORT_LOG_LEVEL", "ERROR")
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("ONNXRUNTIME_SESSION_THREAD_POOL_SIZE", "2")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

CHROMA_HOST = os.environ.get("CORTEX_CHROMA_HOST", "localhost")
CHROMA_PORT = int(os.environ.get("CORTEX_CHROMA_PORT", "8100"))
DB_PATH = os.path.expanduser("~/.claude/cortex-db")

_client = None


def get_client():
    global _client
    if _client is not None:
        return _client

    import chromadb

    try:
        c = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT)
        c.heartbeat()
        _client = c
        return _client
    except Exception:
        pass

    # Fallback: embedded mode (slow cold start)
    try:
        import onnxruntime
        onnxruntime.set_default_logger_severity(3)
    except Exception:
        pass
    _client = chromadb.PersistentClient(path=DB_PATH)
    return _client


def get_collection(name="claude_memories"):
    client = get_client()
    return client.get_or_create_collection(
        name=name,
        metadata={"hnsw:space": "cosine"},
    )
