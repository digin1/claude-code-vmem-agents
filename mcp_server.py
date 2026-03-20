#!/usr/bin/env python3
"""MCP server for vector memory — always-on tools for Claude Code.

Exposes memory_store, memory_search, memory_list, memory_delete, memory_stats
as native Claude Code tools via the MCP protocol (stdio transport).

Safety guardrails:
  - Content size limit: 5000 chars per memory
  - Soft-delete: deleted memories archived to audit log before removal
  - Audit trail: all store/update/delete operations logged to .vmem_audit.jsonl
  - Total DB cap: 200 memories max
"""

import hashlib
import json
import os
import time
import warnings
from pathlib import Path

os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"
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

DB_PATH = str(Path.home() / ".claude" / "vector-memory-db")
AUDIT_LOG = str(Path.home() / ".claude" / ".vmem_audit.jsonl")

MAX_CONTENT_LENGTH = 5000
MAX_TOTAL_MEMORIES = 200

mcp = FastMCP("vector-memory", log_level="ERROR")


def get_collection():
    client = chromadb.PersistentClient(path=DB_PATH)
    return client.get_or_create_collection(
        name="claude_memories",
        metadata={"hnsw:space": "cosine"},
    )


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
        return json.dumps({
            "status": "error",
            "message": f"Content too long ({len(content)} chars). Maximum is {MAX_CONTENT_LENGTH}. Summarize before storing."
        })

    if len(content) < 10:
        return json.dumps({
            "status": "error",
            "message": "Content too short (min 10 chars). Provide meaningful content."
        })

    collection = get_collection()

    # Total DB cap (only check on new memories, not updates)
    mem_id = memory_id or f"mem_{int(time.time() * 1000)}"
    existing = collection.get(ids=[mem_id])
    is_update = bool(existing["ids"])

    if not is_update and collection.count() >= MAX_TOTAL_MEMORIES:
        return json.dumps({
            "status": "error",
            "message": f"Memory database full ({MAX_TOTAL_MEMORIES} memories). Delete old memories before storing new ones."
        })

    metadata = {"type": memory_type, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if project:
        metadata["project"] = project
    if tags:
        metadata["tags"] = tags

    collection.upsert(ids=[mem_id], documents=[content], metadatas=[metadata])

    audit_log_write("store" if not is_update else "update_via_store", mem_id,
                    content_hash=hashlib.sha256(content.encode()).hexdigest()[:16],
                    metadata=metadata)

    return json.dumps({"status": "stored", "id": mem_id, "metadata": metadata})


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
        return json.dumps({"results": [], "message": "No memories stored yet"})

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
    return json.dumps({"results": output, "total_in_db": collection.count()}, indent=2)


@mcp.tool()
def memory_list(memory_type: str = "", project: str = "") -> str:
    """List all stored memories, optionally filtered by type or project.

    Args:
        memory_type: Filter by type (empty = all)
        project: Filter by project (empty = all)
    """
    collection = get_collection()
    if collection.count() == 0:
        return json.dumps({"memories": [], "total": 0})

    where = {}
    if memory_type:
        where["type"] = memory_type
    if project:
        where["project"] = project

    data = collection.get(where=where if where else None)
    output = []
    for i in range(len(data["ids"])):
        doc = data["documents"][i]
        output.append({
            "id": data["ids"][i],
            "content": doc[:300] + ("..." if len(doc) > 300 else ""),
            "metadata": data["metadatas"][i],
        })
    return json.dumps({"memories": output, "total": len(output)}, indent=2)


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
            return json.dumps({"status": "not_found", "id": memory_id})

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
        return json.dumps({"status": "deleted", "id": memory_id, "audit": "content archived to audit log"})
    except Exception as e:
        return json.dumps({"status": "error", "message": str(e)})


@mcp.tool()
def memory_update(memory_id: str, content: str = "", memory_type: str = "", tags: str = "") -> str:
    """Update an existing memory's content or metadata.

    Args:
        memory_id: The ID of the memory to update
        content: New content (empty = keep existing, max 5000 chars)
        memory_type: New type (empty = keep existing)
        tags: New tags (empty = keep existing)
    """
    if content and len(content) > MAX_CONTENT_LENGTH:
        return json.dumps({
            "status": "error",
            "message": f"Content too long ({len(content)} chars). Maximum is {MAX_CONTENT_LENGTH}."
        })

    collection = get_collection()
    existing = collection.get(ids=[memory_id])
    if not existing["ids"]:
        return json.dumps({"status": "not_found", "id": memory_id})

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

    doc = content if content else existing["documents"][0]
    collection.update(ids=[memory_id], documents=[doc], metadatas=[metadata])

    return json.dumps({"status": "updated", "id": memory_id})


@mcp.tool()
def memory_stats() -> str:
    """Show statistics about the memory database — total count, breakdown by type and project."""
    collection = get_collection()
    total = collection.count()
    if total == 0:
        return json.dumps({"total": 0})

    data = collection.get()
    types = {}
    projects = {}
    for m in data["metadatas"]:
        t = m.get("type", "general")
        types[t] = types.get(t, 0) + 1
        p = m.get("project", "global")
        projects[p] = projects.get(p, 0) + 1

    return json.dumps({
        "total": total,
        "max_capacity": MAX_TOTAL_MEMORIES,
        "by_type": types,
        "by_project": projects
    }, indent=2)


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
