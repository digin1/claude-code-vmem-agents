#!/bin/bash
# Auto-recall: searches vector memory for context relevant to user's prompt
# Called by UserPromptSubmit hook — reads JSON from stdin
# Outputs JSON with additionalContext for silent injection into Claude's context
#
# Two modes:
#   FIRST MESSAGE  — comprehensive project-aware context load
#                    (all user/feedback + project-specific + global memories)
#   SUBSEQUENT     — targeted semantic search with project boost

INPUT=$(cat)

python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings
warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"

# Suppress onnxruntime noise
_fd = os.dup(2)
_dn = os.open(os.devnull, os.O_WRONLY)
os.dup2(_dn, 2)
os.close(_dn)
try:
    import onnxruntime
    onnxruntime.set_default_logger_severity(3)
    import chromadb
finally:
    os.dup2(_fd, 2)
    os.close(_fd)

DB_PATH = os.path.expanduser("~/.claude/cortex-db")
ACTIVITY_FILE = os.path.expanduser("~/.claude/.cortex_activity")

raw = sys.argv[1] if len(sys.argv) > 1 else ""

# Parse hook input
try:
    d = json.loads(raw)
except:
    d = {}

user_prompt = d.get("prompt", "") or d.get("content", "") or raw
transcript_path = d.get("transcript_path", "")
cwd = d.get("cwd", "") or os.getcwd()

# Connect to ChromaDB
try:
    client = chromadb.PersistentClient(path=DB_PATH)
    col = client.get_or_create_collection("claude_memories")
    if col.count() == 0:
        sys.exit(0)
except Exception:
    sys.exit(0)


# ================================================================
# Detect first message (no assistant replies in transcript yet)
# ================================================================
def is_first_message(transcript_path):
    if not transcript_path or not os.path.exists(transcript_path):
        return True
    try:
        with open(transcript_path, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                except:
                    continue
                msg = entry.get('message', entry)
                if msg.get('role') != 'assistant':
                    continue
                content = msg.get('content', '')
                if isinstance(content, str) and len(content) > 10:
                    return False
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get('type') == 'text':
                            if len(part.get('text', '')) > 10:
                                return False
    except:
        pass
    return True


# ================================================================
# Detect project(s) from working directory
# ================================================================
def detect_projects(cwd):
    """Match cwd path components against known cortex project names."""
    if not cwd:
        return set()

    # Get all unique project names from DB
    all_data = col.get(include=["metadatas"])
    known_projects = set()
    for m in all_data["metadatas"]:
        p = m.get("project", "")
        if p and p != "global":
            known_projects.add(p)

    # Match: any known project name that appears as a path component
    cwd_lower = cwd.lower()
    matched = set()
    for proj in known_projects:
        if proj.lower() in cwd_lower:
            matched.add(proj)

    return matched


matched_projects = detect_projects(cwd)
first_msg = is_first_message(transcript_path)

# Detect "remember" intent globally — applies to both first and subsequent messages
remember_keywords = ["remember", "recall", "do you know", "have you seen",
                     "did we", "last time", "previously", "earlier session"]
prompt_lower = user_prompt.lower()
is_remember_query = any(kw in prompt_lower for kw in remember_keywords)


# ================================================================
# FIRST MESSAGE: Comprehensive project-aware context load
# ================================================================
if first_msg:
    all_data = col.get(include=["documents", "metadatas"])

    sections = {
        "user": [],
        "feedback": [],
        "project": [],
        "reference": []
    }

    for i in range(len(all_data["ids"])):
        mid = all_data["ids"][i]
        doc = all_data["documents"][i]
        meta = all_data["metadatas"][i]
        mtype = meta.get("type", "general")
        mproject = meta.get("project", "")

        # Skip agent evals — not useful as conversation context
        if mtype == "agent_eval":
            continue

        # USER + FEEDBACK: always include (cross-project knowledge)
        if mtype == "user":
            sections["user"].append((mid, doc, meta))
        elif mtype == "feedback":
            sections["feedback"].append((mid, doc, meta))

        # PROJECT: include if matches current project, is global, or untagged
        elif mtype == "project":
            if mproject in matched_projects or mproject == "global" or mproject == "":
                sections["project"].append((mid, doc, meta))

        # REFERENCE: always include — references are high-value and few in number
        elif mtype == "reference":
            sections["reference"].append((mid, doc, meta))

    # Also do semantic search for cross-project hits the above missed
    # (e.g. user asks about glabheatmap while in grantlab-dockerswarm)
    seen_ids = {all_data["ids"][i] for section in sections.values()
                for _, doc, _ in section
                for i in range(len(all_data["ids"]))
                if all_data["documents"][i] == doc}

    if len(user_prompt) >= 3:
        try:
            # More results and looser threshold for "remember" queries
            sem_n = min(10 if is_remember_query else 5, col.count())
            sem_threshold = 0.8 if is_remember_query else 0.65

            sem_results = col.query(
                query_texts=[user_prompt[:400]],
                n_results=sem_n
            )
            cross_project = []
            for i in range(len(sem_results["ids"][0])):
                mid = sem_results["ids"][0][i]
                dist = sem_results["distances"][0][i] if sem_results.get("distances") else 1.0
                meta = sem_results["metadatas"][0][i]
                if mid not in seen_ids and dist < sem_threshold and meta.get("type") != "agent_eval":
                    cross_project.append((mid, sem_results["documents"][0][i], meta))
                    seen_ids.add(mid)
        except:
            cross_project = []
    else:
        cross_project = []

    # Build structured output
    proj_label = ', '.join(sorted(matched_projects)) if matched_projects else "unknown"
    lines = [f"[cortex] Session context loaded for project: {proj_label}"]

    headers = {
        "user": "User Profile",
        "feedback": "Rules & Preferences",
        "project": "Project Context",
        "reference": "References & Locations"
    }

    # Progressive disclosure: truncate long memories to save tokens
    # Full content available via mcp__cortex__memory_search when needed
    SUMMARY_LIMIT = 250

    total = 0
    for section_key in ["user", "feedback", "project", "reference"]:
        items = sections[section_key]
        if not items:
            continue
        total += len(items)
        lines.append(f"\n== {headers[section_key]} ({len(items)}) ==")
        for mid, doc, meta in items:
            # Show project tag on project/reference items for clarity
            proj_tag = ""
            if section_key in ("project", "reference"):
                p = meta.get("project", "")
                if p:
                    proj_tag = f" [{p}]"
            summary = doc[:SUMMARY_LIMIT] + ("..." if len(doc) > SUMMARY_LIMIT else "")
            lines.append(f"  {mid}{proj_tag}: {summary}")

    # Add cross-project semantic hits
    if cross_project:
        total += len(cross_project)
        lines.append(f"\n== Also Relevant (from other projects) ({len(cross_project)}) ==")
        for mid, doc, meta in cross_project:
            p = meta.get("project", "")
            proj_tag = f" [{p}]" if p else ""
            summary = doc[:SUMMARY_LIMIT] + ("..." if len(doc) > SUMMARY_LIMIT else "")
            lines.append(f"  {mid}{proj_tag}: {summary}")

    if total > 0:
        # Progressive disclosure hint
        lines.append(f"\n[cortex] Showing summaries ({SUMMARY_LIMIT} chars). Use mcp__cortex__memory_search for full content.")

        with open(ACTIVITY_FILE, "w") as af:
            af.write(f"loaded {total} (session start)")

        # Log recalled IDs for hygiene tracking
        try:
            recall_log = os.path.expanduser("~/.claude/.cortex_recall_log")
            all_recalled_ids = []
            for section in sections.values():
                for mid, _, _ in section:
                    all_recalled_ids.append(mid)
            for mid, _, _ in cross_project:
                all_recalled_ids.append(mid)
            with open(recall_log, "a") as rl:
                rl.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {','.join(all_recalled_ids)}\n")
        except Exception:
            pass

        context_text = '\n'.join(lines)
        output = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context_text
            }
        })
        print(output)


# ================================================================
# SUBSEQUENT MESSAGES: Semantic search with project boost
# ================================================================
else:
    if len(user_prompt) < 3:
        sys.exit(0)

    # Build richer query with assistant context
    assistant_context = ""
    if transcript_path and os.path.exists(transcript_path):
        try:
            last_assistant_msgs = []
            with open(transcript_path, 'r') as f:
                for line in f:
                    try:
                        entry = json.loads(line.strip())
                    except:
                        continue
                    msg = entry.get('message', entry)
                    if msg.get('role') != 'assistant':
                        continue
                    raw_content = msg.get('content', '')
                    text = ''
                    if isinstance(raw_content, str):
                        text = raw_content.strip()
                    elif isinstance(raw_content, list):
                        for part in raw_content:
                            if isinstance(part, dict) and part.get('type') == 'text':
                                t = part.get('text', '').strip()
                                if t:
                                    text += t + ' '
                    text = text.strip()
                    if len(text) > 20:
                        last_assistant_msgs.append(text[:300])
            if last_assistant_msgs:
                assistant_context = ' '.join(last_assistant_msgs[-2:])[:500]
        except:
            pass

    search_query = user_prompt[:400]
    if assistant_context:
        search_query = f"{user_prompt[:300]} {assistant_context[:200]}"

    # More results and looser thresholds for explicit recall queries
    n_results = min(12 if is_remember_query else 8, col.count())

    results = col.query(
        query_texts=[search_query],
        n_results=n_results
    )

    relevant = []
    for i in range(len(results["ids"][0])):
        dist = results["distances"][0][i] if results.get("distances") else 1.0
        mid = results["ids"][0][i]
        meta = results["metadatas"][0][i]
        mem_type = meta.get("type", "general")
        mem_project = meta.get("project", "")

        if mem_type == "agent_eval":
            continue

        # Boosted thresholds for "remember" queries, relaxed for project matches
        if is_remember_query:
            threshold = 0.85 if mem_project in matched_projects else 0.75
        else:
            threshold = 0.7 if mem_project in matched_projects else 0.6

        if dist < threshold:
            relevant.append({
                "id": mid,
                "content": results["documents"][0][i][:400],
                "type": mem_type,
                "project": mem_project,
                "distance": round(dist, 3)
            })

    if relevant:
        with open(ACTIVITY_FILE, "w") as af:
            af.write(f"recalled {len(relevant)}")

        # Log recalled IDs for hygiene tracking
        try:
            recall_log = os.path.expanduser("~/.claude/.cortex_recall_log")
            recalled_ids = [r["id"] for r in relevant]
            with open(recall_log, "a") as rl:
                rl.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {','.join(recalled_ids)}\n")
        except Exception:
            pass

        context_lines = ["[cortex] Recalled memories relevant to this message:"]
        for r in relevant:
            proj_tag = f" [{r['project']}]" if r.get('project') else ""
            context_lines.append(
                f"  [{r['type']}] {r['id']}{proj_tag}: {r['content']}"
            )

        context_text = '\n'.join(context_lines)
        output = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context_text
            }
        })
        print(output)

PYEOF
