#!/usr/bin/env python3
"""Vector memory database CLI for Claude Code.

Stores memories in ChromaDB with semantic search capability.
Data persists at ~/.claude/cortex-db/
"""

import argparse
import json
import os
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.chroma_client import get_collection as _get_collection


def get_collection():
    return _get_collection()


def store(args):
    collection = get_collection()
    mem_id = args.id or f"mem_{int(time.time() * 1000)}"
    metadata = {"type": args.type, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if args.project:
        metadata["project"] = args.project
    if args.tags:
        metadata["tags"] = args.tags

    collection.upsert(ids=[mem_id], documents=[args.content], metadatas=[metadata])
    print(json.dumps({"status": "stored", "id": mem_id, "metadata": metadata}))


def search(args):
    collection = get_collection()
    if collection.count() == 0:
        print(json.dumps({"results": [], "message": "No memories stored yet"}))
        return

    where = {}
    if args.type:
        where["type"] = args.type
    if args.project:
        where["project"] = args.project

    results = collection.query(
        query_texts=[args.query],
        n_results=min(args.n, collection.count()),
        where=where if where else None,
    )

    output = []
    for i in range(len(results["ids"][0])):
        output.append({
            "id": results["ids"][0][i],
            "content": results["documents"][0][i],
            "metadata": results["metadatas"][0][i],
            "distance": results["distances"][0][i] if results.get("distances") else None,
        })
    print(json.dumps({"results": output, "total_in_db": collection.count()}, indent=2))


def list_all(args):
    collection = get_collection()
    if collection.count() == 0:
        print(json.dumps({"memories": [], "total": 0}))
        return

    where = {}
    if args.type:
        where["type"] = args.type
    if args.project:
        where["project"] = args.project

    data = collection.get(where=where if where else None)
    output = []
    for i in range(len(data["ids"])):
        output.append({
            "id": data["ids"][i],
            "content": data["documents"][i][:200] + ("..." if len(data["documents"][i]) > 200 else ""),
            "metadata": data["metadatas"][i],
        })
    print(json.dumps({"memories": output, "total": len(output)}, indent=2))


def delete(args):
    collection = get_collection()
    try:
        existing = collection.get(ids=[args.id])
        if not existing["ids"]:
            print(json.dumps({"status": "error", "message": f"Memory '{args.id}' not found"}))
            return
        collection.delete(ids=[args.id])
        print(json.dumps({"status": "deleted", "id": args.id}))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}))


def update(args):
    collection = get_collection()
    existing = collection.get(ids=[args.id])
    if not existing["ids"]:
        print(json.dumps({"status": "error", "message": f"Memory '{args.id}' not found"}))
        return

    metadata = existing["metadatas"][0]
    metadata["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    if args.type:
        metadata["type"] = args.type
    if args.tags:
        metadata["tags"] = args.tags

    content = args.content if args.content else existing["documents"][0]
    collection.update(ids=[args.id], documents=[content], metadatas=[metadata])
    print(json.dumps({"status": "updated", "id": args.id, "metadata": metadata}))


def stats(args):
    collection = get_collection()
    total = collection.count()
    if total == 0:
        print(json.dumps({"total": 0}))
        return

    data = collection.get()
    types = {}
    projects = {}
    for m in data["metadatas"]:
        t = m.get("type", "general")
        types[t] = types.get(t, 0) + 1
        p = m.get("project", "global")
        projects[p] = projects.get(p, 0) + 1

    print(json.dumps({"total": total, "by_type": types, "by_project": projects}, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Vector memory database for Claude Code")
    sub = parser.add_subparsers(dest="command", required=True)

    # store
    p_store = sub.add_parser("store", help="Store a memory")
    p_store.add_argument("content", help="Memory content")
    p_store.add_argument("--id", help="Custom memory ID (auto-generated if omitted)")
    p_store.add_argument("--type", default="general", help="Memory type: user, feedback, project, reference, general")
    p_store.add_argument("--project", help="Project name for scoping")
    p_store.add_argument("--tags", help="Comma-separated tags")
    p_store.set_defaults(func=store)

    # search
    p_search = sub.add_parser("search", help="Semantic search")
    p_search.add_argument("query", help="Search query")
    p_search.add_argument("-n", type=int, default=5, help="Number of results (default: 5)")
    p_search.add_argument("--type", help="Filter by type")
    p_search.add_argument("--project", help="Filter by project")
    p_search.set_defaults(func=search)

    # list
    p_list = sub.add_parser("list", help="List all memories")
    p_list.add_argument("--type", help="Filter by type")
    p_list.add_argument("--project", help="Filter by project")
    p_list.set_defaults(func=list_all)

    # delete
    p_delete = sub.add_parser("delete", help="Delete a memory")
    p_delete.add_argument("id", help="Memory ID to delete")
    p_delete.set_defaults(func=delete)

    # update
    p_update = sub.add_parser("update", help="Update a memory")
    p_update.add_argument("id", help="Memory ID to update")
    p_update.add_argument("--content", help="New content")
    p_update.add_argument("--type", help="New type")
    p_update.add_argument("--tags", help="New tags")
    p_update.set_defaults(func=update)

    # stats
    p_stats = sub.add_parser("stats", help="Show memory statistics")
    p_stats.set_defaults(func=stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
