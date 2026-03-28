#!/bin/bash
# FileChanged hook: flag stale memories when key config files change
# Watches: .env, docker-compose.yml, package.json, requirements.txt, pyproject.toml
# Tags affected memories with stale_config so hygiene can clean them

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings
warnings.filterwarnings("ignore")
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["ONNXRUNTIME_SESSION_THREAD_POOL_SIZE"] = "2"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

changed_file = d.get("file_path", "") or d.get("path", "")
cwd = d.get("cwd", "")

if not changed_file:
    sys.exit(0)

basename = os.path.basename(changed_file)

# Only care about config files that affect project setup
CONFIG_FILES = {
    ".env", ".env.local", ".env.production",
    "docker-compose.yml", "docker-compose.yaml",
    "package.json", "requirements.txt", "pyproject.toml",
    "Dockerfile", "Makefile", "tsconfig.json",
    "alembic.ini", ".envrc",
}

if basename not in CONFIG_FILES:
    sys.exit(0)

# Find project name from cwd
project_name = ""
if cwd:
    parts = cwd.rstrip("/").split("/")
    skip = {"home", "Users", "projects", "src", "work", "dev", "repos", "code", ".claude", ""}
    for p in reversed(parts):
        if p not in skip:
            project_name = p
            break

if not project_name:
    sys.exit(0)

# Search for reference memories in this project that might be stale
sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
try:
    from chroma_client import get_collection
    col = get_collection()
    if col.count() == 0:
        sys.exit(0)
except:
    sys.exit(0)

# Search for memories referencing this config file or its contents
query = f"{basename} {project_name} configuration setup"
try:
    results = col.query(
        query_texts=[query],
        n_results=min(5, col.count()),
        where={"project": project_name},
    )
except:
    sys.exit(0)

tagged = 0
for i in range(len(results["ids"][0])):
    mid = results["ids"][0][i]
    dist = results["distances"][0][i] if results.get("distances") else 1.0
    meta = results["metadatas"][0][i]

    # Only flag close matches that are reference type
    if dist > 0.5 or meta.get("type", "") != "reference":
        continue

    # Tag with stale_config
    existing_tags = meta.get("tags", "")
    if "stale_config" in existing_tags:
        continue

    new_tags = f"{existing_tags},stale_config" if existing_tags else "stale_config"
    try:
        col.update(ids=[mid], metadatas=[{**meta, "tags": new_tags}])
        tagged += 1
    except:
        pass

if tagged > 0:
    context = f"[cortex] {basename} changed — flagged {tagged} reference memory(ies) as potentially stale. Verify they're still accurate."
    output = json.dumps({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "FileChanged",
            "additionalContext": context
        }
    })
    print(output)

PYEOF
