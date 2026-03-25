#!/usr/bin/env python3
"""Cortex MCP server — always-on memory tools for Claude Code.

Exposes memory_store, memory_search, memory_list, memory_delete, memory_update,
memory_stats as native Claude Code tools via the MCP protocol (stdio transport).

Safety guardrails:
  - Content size limit: 5000 chars per memory
  - Soft-delete: deleted memories archived to audit log before removal
  - Audit trail: all store/update/delete operations logged to .cortex_audit.jsonl
  - Total DB cap: unlimited (set MAX_TOTAL_MEMORIES > 0 to enforce a limit)
"""

import hashlib
import json
import os
import time
import warnings
from pathlib import Path

os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"
# Throttle threads — multiple MCP server instances run concurrently
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["ONNXRUNTIME_SESSION_THREAD_POOL_SIZE"] = "2"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
warnings.filterwarnings("ignore")

_stderr_fd = os.dup(2)
_devnull = os.open(os.devnull, os.O_WRONLY)
os.dup2(_devnull, 2)
os.close(_devnull)
try:
    import onnxruntime
    onnxruntime.set_default_logger_severity(3)
    import chromadb
finally:
    os.dup2(_stderr_fd, 2)
    os.close(_stderr_fd)
from mcp.server.fastmcp import FastMCP

DB_PATH = str(Path.home() / ".claude" / "cortex-db")
AUDIT_LOG = str(Path.home() / ".claude" / ".cortex_audit.jsonl")
RECALL_LOG = str(Path.home() / ".claude" / ".cortex_recall_log")

MAX_CONTENT_LENGTH = 5000
MAX_TOTAL_MEMORIES = 0  # 0 = unlimited
P = "🧠 cortex ›"  # Prefix for all tool outputs — distinguishes from Claude Code
RECALL_LOG_MAX_SIZE = 5 * 1024 * 1024  # 5MB — truncate to last 7 days when exceeded
AUDIT_ROTATION_INTERVAL = 86400  # Check at most once per day (seconds)
AUDIT_RETENTION_DAYS = 90

mcp = FastMCP("cortex", log_level="ERROR")

# Singleton ChromaDB client — reused across all tool calls (MCP server is long-lived)
_chroma_client = None
_chroma_collection = None
_last_audit_rotation_check = 0


def get_collection():
    global _chroma_client, _chroma_collection
    if _chroma_collection is not None:
        try:
            _chroma_collection.count()  # Lightweight liveness check
            return _chroma_collection
        except Exception:
            _chroma_client = None
            _chroma_collection = None

    _chroma_client = chromadb.PersistentClient(path=DB_PATH)
    _chroma_collection = _chroma_client.get_or_create_collection(
        name="claude_memories",
        metadata={"hnsw:space": "cosine"},
    )
    return _chroma_collection


def audit_log_write(action, memory_id, content_hash="", metadata=None, reason=""):
    """Append an entry to the audit log."""
    try:
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "action": action,
            "memory_id": memory_id,
            "content_hash": content_hash,
            "reason": reason,
        }
        if metadata:
            entry["metadata"] = {k: v for k, v in metadata.items()
                                 if k in ("type", "project", "tags")}
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def _track_recalls(collection, result_ids):
    """Update recall_count and last_recalled in ChromaDB, and append to recall log."""
    if not result_ids:
        return
    now = time.strftime("%Y-%m-%dT%H:%M:%S")

    # 1. Update ChromaDB metadata inline (real-time recall tracking)
    try:
        existing = collection.get(ids=result_ids)
        for i, mid in enumerate(existing["ids"]):
            meta = dict(existing["metadatas"][i])
            meta["recall_count"] = str(int(meta.get("recall_count", "0") or "0") + 1)
            meta["last_recalled"] = now
            collection.update(ids=[mid], metadatas=[meta])
    except Exception:
        pass

    # 2. Append to recall log for recall.sh/memory_hygiene.py compatibility
    try:
        with open(RECALL_LOG, "a") as f:
            f.write(f"{now} {','.join(result_ids)}\n")
    except Exception:
        pass

    # 3. Truncate recall log if too large
    _maybe_truncate_recall_log()


def _maybe_truncate_recall_log():
    """If recall log exceeds 5MB, truncate to last 7 days."""
    try:
        if not os.path.exists(RECALL_LOG):
            return
        if os.path.getsize(RECALL_LOG) < RECALL_LOG_MAX_SIZE:
            return

        cutoff = time.strftime(
            "%Y-%m-%d",
            time.localtime(time.time() - 7 * 86400)
        )
        kept = []
        with open(RECALL_LOG, "r") as f:
            for line in f:
                if line[:10] >= cutoff:
                    kept.append(line)

        import tempfile
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(RECALL_LOG))
        try:
            with os.fdopen(tmp_fd, "w") as f:
                f.writelines(kept)
            os.replace(tmp_path, RECALL_LOG)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    except Exception:
        pass


def _maybe_rotate_audit_log():
    """Rotate audit log if not checked recently. Keeps last 90 days."""
    global _last_audit_rotation_check
    now = time.time()
    if now - _last_audit_rotation_check < AUDIT_ROTATION_INTERVAL:
        return
    _last_audit_rotation_check = now

    try:
        if not os.path.exists(AUDIT_LOG):
            return
        if os.path.getsize(AUDIT_LOG) < 50_000:  # Only bother if > 50KB
            return

        cutoff = time.strftime(
            "%Y-%m-%dT%H:%M:%S",
            time.localtime(now - AUDIT_RETENTION_DAYS * 86400)
        )
        kept = []
        with open(AUDIT_LOG, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    if entry.get("timestamp", "") >= cutoff:
                        kept.append(line)
                except Exception:
                    kept.append(line)  # Keep unparseable lines

        import tempfile
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(AUDIT_LOG))
        try:
            with os.fdopen(tmp_fd, "w") as f:
                f.write("\n".join(kept) + "\n" if kept else "")
            os.replace(tmp_path, AUDIT_LOG)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    except Exception:
        pass


@mcp.tool()
def memory_store(
    content: str,
    memory_type: str = "general",
    memory_id: str = "",
    project: str = "",
    tags: str = "",
) -> str:
    """Store a memory in the vector database with semantic embedding.

    Args:
        content: The memory text to store (max 5000 chars)
        memory_type: Category — user, feedback, project, reference, or general
        memory_id: Custom ID (auto-generated if empty). Use descriptive IDs like 'user_prefers_dark_mode'
        project: Project name for scoping (empty = global)
        tags: Comma-separated tags for organization
    """
    # Content size limit
    if len(content) > MAX_CONTENT_LENGTH:
        return f"{P} Error: Content too long ({len(content)} chars). Max {MAX_CONTENT_LENGTH}."

    if len(content) < 10:
        return f"{P} Error: Content too short (min 10 chars)."

    collection = get_collection()

    # Total DB cap (only check on new memories, not updates)
    mem_id = memory_id or f"mem_{int(time.time() * 1000)}"
    existing = collection.get(ids=[mem_id])
    is_update = bool(existing["ids"])

    if MAX_TOTAL_MEMORIES and not is_update and collection.count() >= MAX_TOTAL_MEMORIES:
        return f"{P} Error: Database full ({MAX_TOTAL_MEMORIES}). Delete old memories first."

    metadata = {"type": memory_type, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if project:
        metadata["project"] = project
    if tags:
        metadata["tags"] = tags

    collection.upsert(ids=[mem_id], documents=[content], metadatas=[metadata])

    audit_log_write("store" if not is_update else "update_via_store", mem_id,
                    content_hash=hashlib.sha256(content.encode()).hexdigest()[:16],
                    metadata=metadata)

    meta_parts = [f"type={memory_type}"]
    if project:
        meta_parts.append(f"project={project}")
    if tags:
        meta_parts.append(f"tags={tags}")
    return f"{P} Stored: {mem_id} ({', '.join(meta_parts)})"


@mcp.tool()
def memory_search(
    query: str,
    n: int = 5,
    memory_type: str = "",
    project: str = "",
) -> str:
    """Semantic search across all stored memories. Returns the most similar matches.

    Args:
        query: Natural language search query
        n: Number of results to return (default 5, max 20)
        memory_type: Filter by type (empty = all)
        project: Filter by project (empty = all)
    """
    collection = get_collection()
    if collection.count() == 0:
        return f"{P} No memories stored yet."

    # Cap results to prevent excessive output
    n = min(n, 20)

    where = {}
    if memory_type:
        where["type"] = memory_type
    if project:
        where["project"] = project

    results = collection.query(
        query_texts=[query[:1000]],  # Truncate query to prevent abuse
        n_results=min(n, collection.count()),
        where=where if where else None,
    )

    output = []
    for i in range(len(results["ids"][0])):
        output.append({
            "id": results["ids"][0][i],
            "content": results["documents"][0][i],
            "metadata": results["metadatas"][0][i],
            "distance": round(results["distances"][0][i], 4) if results.get("distances") else None,
        })

    # Track recalls — update metadata + append to recall log
    if output:
        _track_recalls(collection, [r["id"] for r in output])

    lines = [f"{P} Found {len(output)} result(s) ({collection.count()} total in DB):\n"]
    for r in output:
        meta = r["metadata"]
        mtype = meta.get("type", "general")
        proj = meta.get("project", "")
        proj_tag = f" [{proj}]" if proj else ""
        dist = f" (distance: {r['distance']})" if r.get("distance") is not None else ""
        lines.append(f"  [{mtype}] {r['id']}{proj_tag}{dist}")
        lines.append(f"    {r['content'][:200]}")
        lines.append("")
    return "\n".join(lines)


@mcp.tool()
def memory_list(memory_type: str = "", project: str = "") -> str:
    """List all stored memories, optionally filtered by type or project.

    Args:
        memory_type: Filter by type (empty = all)
        project: Filter by project (empty = all)
    """
    collection = get_collection()
    if collection.count() == 0:
        return f"{P} No memories stored."

    where = {}
    if memory_type:
        where["type"] = memory_type
    if project:
        where["project"] = project

    data = collection.get(where=where if where else None)
    total = len(data["ids"])
    lines = [f"{P} {total} memor{'y' if total == 1 else 'ies'}:\n"]
    for i in range(total):
        meta = data["metadatas"][i]
        mtype = meta.get("type", "general")
        proj = meta.get("project", "")
        proj_tag = f" [{proj}]" if proj else ""
        doc = data["documents"][i]
        preview = doc[:200] + ("..." if len(doc) > 200 else "")
        lines.append(f"  [{mtype}] {data['ids'][i]}{proj_tag}")
        lines.append(f"    {preview}")
        lines.append("")
    return "\n".join(lines)


@mcp.tool()
def memory_delete(memory_id: str) -> str:
    """Delete a memory by its ID. The memory content is archived to the audit log before deletion.

    Args:
        memory_id: The ID of the memory to delete
    """
    collection = get_collection()
    try:
        existing = collection.get(ids=[memory_id])
        if not existing["ids"]:
            return f"{P} Not found: {memory_id}"

        # Archive to audit log before deletion
        content = existing["documents"][0] if existing["documents"] else ""
        metadata = existing["metadatas"][0] if existing["metadatas"] else {}
        content_hash = hashlib.sha256(content.encode()).hexdigest()[:16]

        # Write full content to audit log for recovery
        audit_entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "action": "delete",
            "memory_id": memory_id,
            "content_hash": content_hash,
            "content_backup": content[:2000],  # Backup up to 2000 chars
            "metadata": metadata,
        }
        try:
            with open(AUDIT_LOG, "a") as f:
                f.write(json.dumps(audit_entry) + "\n")
        except Exception:
            pass

        collection.delete(ids=[memory_id])
        return f"{P} Deleted: {memory_id} (archived to audit log)"
    except Exception as e:
        return f"{P} Error: {e}"


@mcp.tool()
def memory_update(memory_id: str, content: str = "", memory_type: str = "", tags: str = "", project: str = "") -> str:
    """Update an existing memory's content or metadata.

    Args:
        memory_id: The ID of the memory to update
        content: New content (empty = keep existing, max 5000 chars)
        memory_type: New type (empty = keep existing)
        tags: New tags (empty = keep existing)
        project: New project scope (empty = keep existing)
    """
    if content and len(content) > MAX_CONTENT_LENGTH:
        return f"{P} Error: Content too long ({len(content)} chars). Max {MAX_CONTENT_LENGTH}."

    collection = get_collection()
    existing = collection.get(ids=[memory_id])
    if not existing["ids"]:
        return f"{P} Not found: {memory_id}"

    # Audit log the update (old content hash for diffing)
    old_content = existing["documents"][0] if existing["documents"] else ""
    audit_log_write("update", memory_id,
                    content_hash=hashlib.sha256(old_content.encode()).hexdigest()[:16],
                    metadata=existing["metadatas"][0] if existing["metadatas"] else None,
                    reason="content_changed" if content else "metadata_only")

    metadata = existing["metadatas"][0]
    metadata["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    if memory_type:
        metadata["type"] = memory_type
    if tags:
        metadata["tags"] = tags
    if project:
        metadata["project"] = project

    doc = content if content else existing["documents"][0]
    collection.update(ids=[memory_id], documents=[doc], metadatas=[metadata])

    changed = []
    if content:
        changed.append("content")
    if memory_type:
        changed.append(f"type={memory_type}")
    if tags:
        changed.append(f"tags={tags}")
    if project:
        changed.append(f"project={project}")
    return f"{P} Updated: {memory_id} ({', '.join(changed) if changed else 'metadata timestamp'})"


@mcp.tool()
def memory_stats() -> str:
    """Show statistics about the memory database — total count, breakdown by type and project."""
    _maybe_rotate_audit_log()
    collection = get_collection()
    total = collection.count()
    if total == 0:
        return f"{P} No memories stored."

    data = collection.get()
    types = {}
    projects = {}
    for m in data["metadatas"]:
        t = m.get("type", "general")
        types[t] = types.get(t, 0) + 1
        p = m.get("project", "global")
        projects[p] = projects.get(p, 0) + 1

    lines = [f"{P} Total: {total} memories"]
    lines.append("By type: " + ", ".join(f"{t} ({c})" for t, c in sorted(types.items())))
    lines.append("By project: " + ", ".join(f"{p} ({c})" for p, c in sorted(projects.items())))
    return "\n".join(lines)


# ================================================================
# MCP Resources — @memory:// references
# ================================================================

@mcp.resource("memory://all", name="all-memories", description="All stored memories — use @memory://all to pull into context")
def resource_all_memories() -> str:
    """List all memories with type, project, and content preview."""
    collection = get_collection()
    if collection.count() == 0:
        return "No memories stored."
    data = collection.get(include=["documents", "metadatas"])
    lines = []
    for i in range(len(data["ids"])):
        meta = data["metadatas"][i]
        mtype = meta.get("type", "general")
        project = meta.get("project", "")
        proj_tag = f" [{project}]" if project else ""
        lines.append(f"[{mtype}] {data['ids'][i]}{proj_tag}: {data['documents'][i][:300]}")
    return "\n".join(lines)


@mcp.resource("memory://{memory_id}", name="memory-by-id", description="Fetch a specific memory by ID")
def resource_memory_by_id(memory_id: str) -> str:
    """Get full content and metadata for a specific memory."""
    collection = get_collection()
    result = collection.get(ids=[memory_id])
    if not result["ids"]:
        return f"Memory '{memory_id}' not found."
    doc = result["documents"][0]
    meta = result["metadatas"][0]
    return json.dumps({"id": memory_id, "content": doc, "metadata": meta}, indent=2)


@mcp.resource("memory://project/{project_name}", name="project-memories", description="All memories for a specific project")
def resource_project_memories(project_name: str) -> str:
    """Get all memories scoped to a project."""
    collection = get_collection()
    try:
        data = collection.get(where={"project": project_name}, include=["documents", "metadatas"])
    except Exception:
        return f"No memories for project '{project_name}'."
    if not data["ids"]:
        return f"No memories for project '{project_name}'."
    lines = [f"Memories for project: {project_name} ({len(data['ids'])} total)\n"]
    for i in range(len(data["ids"])):
        meta = data["metadatas"][i]
        mtype = meta.get("type", "?")
        lines.append(f"[{mtype}] {data['ids'][i]}: {data['documents'][i][:300]}")
    return "\n".join(lines)


@mcp.resource("memory://type/{memory_type}", name="typed-memories", description="All memories of a specific type (user, feedback, project, reference)")
def resource_typed_memories(memory_type: str) -> str:
    """Get all memories filtered by type."""
    collection = get_collection()
    try:
        data = collection.get(where={"type": memory_type}, include=["documents", "metadatas"])
    except Exception:
        return f"No memories of type '{memory_type}'."
    if not data["ids"]:
        return f"No memories of type '{memory_type}'."
    lines = [f"Memories of type: {memory_type} ({len(data['ids'])} total)\n"]
    for i in range(len(data["ids"])):
        meta = data["metadatas"][i]
        proj = meta.get("project", "")
        proj_tag = f" [{proj}]" if proj else ""
        lines.append(f"{data['ids'][i]}{proj_tag}: {data['documents'][i][:300]}")
    return "\n".join(lines)


if __name__ == "__main__":
    mcp.run(transport="stdio")
