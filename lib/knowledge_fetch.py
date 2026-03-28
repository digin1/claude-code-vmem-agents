#!/usr/bin/env python3
"""Download framework documentation to ~/.claude/docs/.

Reads JSON list of needed frameworks from stdin (output of knowledge_check.py).
Tries each source in order: git_sparse → context7 → context7_auto.
Writes .manifest.json per framework on success.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time


def load_registry_meta():
    registry_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "knowledge_registry.json")
    try:
        with open(registry_path) as f:
            return json.load(f).get("_meta", {})
    except Exception:
        return {}


META = load_registry_meta()
DOC_ROOT = os.path.expanduser(META.get("doc_root", "~/.claude/docs"))
MAX_FILES = META.get("max_files_per_framework", 500)
MAX_SIZE_MB = META.get("max_size_mb", 100)


def write_manifest(doc_dir, framework_id, source_type, source_ref, branch="", version=""):
    """Write .manifest.json with fetch metadata."""
    file_count = 0
    total_size = 0
    for root, _, files in os.walk(doc_dir):
        for f in files:
            if f.startswith("."):
                continue
            file_count += 1
            total_size += os.path.getsize(os.path.join(root, f))

    manifest = {
        "framework_id": framework_id,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source_type": source_type,
        "source_ref": source_ref,
        "branch": branch,
        "project_version": version,
        "file_count": file_count,
        "total_size_bytes": total_size,
    }
    with open(os.path.join(doc_dir, ".manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)


def fetch_git_sparse(framework_id, source, doc_dir, version=""):
    """Sparse checkout of docs directory from a git repo."""
    repo = source.get("repo", "")
    path = source.get("path", "")
    branch = source.get("branch", "main")
    glob_pattern = source.get("glob", "**/*.md")

    if not repo or not path:
        return False

    tmp_dir = tempfile.mkdtemp(prefix=f"cortex_docs_{framework_id}_")
    try:
        # Git sparse checkout — only clone the docs directory
        result = subprocess.run(
            ["nice", "-n", "15", "ionice", "-c", "3",
             "git", "clone", "--depth", "1", "--filter=blob:none",
             "--sparse", "--single-branch", "--branch", branch, repo, tmp_dir],
            timeout=60, capture_output=True, text=True,
        )
        if result.returncode != 0:
            return False

        result = subprocess.run(
            ["git", "-C", tmp_dir, "sparse-checkout", "set", path],
            timeout=60, capture_output=True, text=True,
        )
        if result.returncode != 0:
            return False

        # Source directory
        src = os.path.join(tmp_dir, path)
        if not os.path.isdir(src):
            return False

        # Clean target and copy
        if os.path.exists(doc_dir):
            shutil.rmtree(doc_dir)
        os.makedirs(doc_dir, exist_ok=True)

        # Copy matching files, respecting limits
        file_count = 0
        total_size = 0
        max_bytes = MAX_SIZE_MB * 1024 * 1024

        for root, dirs, files in os.walk(src):
            for fname in files:
                # Check glob pattern match
                rel_path = os.path.relpath(os.path.join(root, fname), src)
                if not _matches_glob(rel_path, glob_pattern):
                    continue

                src_file = os.path.join(root, fname)
                fsize = os.path.getsize(src_file)

                # Safety limits
                if file_count >= MAX_FILES:
                    break
                if total_size + fsize > max_bytes:
                    break

                dst_file = os.path.join(doc_dir, rel_path)
                os.makedirs(os.path.dirname(dst_file), exist_ok=True)
                shutil.copy2(src_file, dst_file)
                file_count += 1
                total_size += fsize

            if file_count >= MAX_FILES or total_size >= max_bytes:
                break

        if file_count == 0:
            return False

        write_manifest(doc_dir, framework_id, "git_sparse", repo, branch, version)
        return True

    except (subprocess.TimeoutExpired, Exception):
        return False
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _matches_glob(path, pattern):
    """Simple glob matching for doc file filtering."""
    import fnmatch
    return fnmatch.fnmatch(path, pattern)


def fetch_context7(framework_id, source, doc_dir, version=""):
    """Fetch docs via context7 MCP tool using claude -p."""
    library_id = source.get("library_id", "")
    topics = source.get("topics", [])
    name = source.get("name", framework_id)

    if not topics:
        topics = [
            f"{name} getting started and installation",
            f"{name} API reference",
            f"{name} configuration and setup",
            f"{name} advanced patterns and best practices",
        ]

    if os.path.exists(doc_dir):
        shutil.rmtree(doc_dir)
    os.makedirs(doc_dir, exist_ok=True)

    fetched = 0
    for topic in topics:
        try:
            prompt = (
                f"Use the context7 tools to fetch documentation. "
                f"First resolve the library ID for '{name}' using resolve-library-id, "
                f"then use query-docs to get documentation about: {topic}. "
                f"Output ONLY the documentation content, no commentary."
            )
            if library_id:
                prompt = (
                    f"Use the context7 query-docs tool with libraryId='{library_id}' "
                    f"and query='{topic}'. Output ONLY the documentation content."
                )

            result = subprocess.run(
                ["claude", "-p", "--no-session-persistence", "--model", "haiku",
             "--allowedTools", "mcp__context7__resolve-library-id,mcp__context7__query-docs",
             prompt],
                capture_output=True, text=True, timeout=60,
            )

            content = result.stdout.strip()
            if content and len(content) > 100:
                safe_topic = re.sub(r"[^a-z0-9-]", "-", topic.lower())[:60]
                with open(os.path.join(doc_dir, f"{safe_topic}.md"), "w") as f:
                    f.write(f"# {topic}\n\n{content}\n")
                fetched += 1
        except Exception:
            continue

    if fetched == 0:
        return False

    write_manifest(doc_dir, framework_id, "context7", library_id or name, version=version)
    return True


def fetch_framework(fw):
    """Try each source in order until one succeeds."""
    fid = fw.get("id", "")
    sources = fw.get("sources", [])
    version = fw.get("version", "")
    doc_dir = os.path.join(DOC_ROOT, fid)

    for source in sources:
        stype = source.get("type", "")

        if stype == "git_sparse":
            if fetch_git_sparse(fid, source, doc_dir, version):
                return True

        elif stype in ("context7", "context7_auto"):
            if fetch_context7(fid, source, doc_dir, version):
                return True

    return False


def main():
    """Read needed frameworks from stdin, fetch docs for each."""
    os.makedirs(DOC_ROOT, exist_ok=True)

    raw = sys.stdin.read().strip()
    if not raw:
        return

    try:
        needed = json.loads(raw)
    except Exception:
        return

    if not isinstance(needed, list):
        return

    results = {"fetched": [], "failed": []}
    for i, fw in enumerate(needed):
        fid = fw.get("id", "unknown")
        if fetch_framework(fw):
            results["fetched"].append(fid)
            sys.stderr.write(f"[cortex docs] Fetched: {fid}\n")
        else:
            results["failed"].append(fid)
            sys.stderr.write(f"[cortex docs] Failed: {fid}\n")
        # Throttle between downloads to avoid system overload
        if i < len(needed) - 1:
            time.sleep(2)

    print(json.dumps(results))


if __name__ == "__main__":
    main()
