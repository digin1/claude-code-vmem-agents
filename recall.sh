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

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time, warnings
warnings.filterwarnings("ignore")
os.environ["ONNXRUNTIME_DISABLE_TELEMETRY"] = "1"
os.environ["ORT_LOG_LEVEL"] = "ERROR"
# Throttle onnxruntime threads — prevents each hook from saturating all cores
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["ONNXRUNTIME_SESSION_THREAD_POOL_SIZE"] = "2"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

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

# Skip recall for automated claude -p subprocess prompts
_skip_patterns = [
    "you are a memory extraction system",
    "you identify reusable workflow patterns",
    "you evaluate and reconcile an existing fleet",
    "you are an agent architect",
    "summarize this session in one sentence",
    "extract learnings from this coding session",
    "analyze this coding session for skill",
    "analyze this coding session for specialized agent",
    "output a json array of memories",
    "output a json array of agents",
    "output only the json array",
]
_prompt_lower = user_prompt[:500].lower()
for _pat in _skip_patterns:
    if _pat in _prompt_lower:
        sys.exit(0)

# Skip very short or empty prompts
if len(user_prompt.strip()) < 5:
    sys.exit(0)

# Connect to ChromaDB (HttpClient with PersistentClient fallback)
sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
from chroma_client import get_client, get_collection

try:
    col = get_collection()
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
    seen_ids = {mid for section in sections.values() for mid, _, _ in section}

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

    # ── Agent, skill, and doc inventory (first message only) ──
    import glob as _glob

    def _scan_inventory(dirs, prefix=""):
        """Scan .md files for name + description from YAML frontmatter."""
        items = []
        for scope, d in dirs:
            if not os.path.isdir(d):
                continue
            for f in sorted(_glob.glob(os.path.join(d, "*.md"))):
                name = os.path.splitext(os.path.basename(f))[0]
                desc = ""
                try:
                    with open(f) as fh:
                        in_front = False
                        for line in fh:
                            line = line.strip()
                            if line == "---" and not in_front:
                                in_front = True; continue
                            if line == "---" and in_front:
                                break
                            if in_front and line.lower().startswith("description:"):
                                desc = line.split(":", 1)[1].strip().strip('"').strip("'")
                except Exception:
                    pass
                items.append(f"  [{scope}] {prefix}{name}: {desc[:100]}")
        return items

    agent_lines = _scan_inventory([
        ("project", os.path.join(cwd, ".claude", "agents")),
        ("global", os.path.expanduser("~/.claude/agents")),
    ])
    skill_lines = _scan_inventory([
        ("project", os.path.join(cwd, ".claude", "commands")),
        ("global", os.path.expanduser("~/.claude/commands")),
    ], prefix="/")
    doc_lines = []
    doc_root = os.path.expanduser("~/.claude/docs")
    if os.path.isdir(doc_root):
        for fid in sorted(os.listdir(doc_root)):
            mp = os.path.join(doc_root, fid, ".manifest.json")
            if os.path.isfile(mp):
                try:
                    with open(mp) as f:
                        m = json.load(f)
                    doc_lines.append(f"  {fid}: {m.get('file_count', '?')} files at ~/.claude/docs/{fid}/")
                except Exception:
                    doc_lines.append(f"  {fid}: ~/.claude/docs/{fid}/")

    if agent_lines:
        lines.append("\n[cortex] Available agents:")
        lines.extend(agent_lines)
    if skill_lines:
        lines.append("\n[cortex] Available skills:")
        lines.extend(skill_lines)
    if doc_lines:
        lines.append("\n[cortex] Cached docs:")
        lines.extend(doc_lines)

    if total > 0 or agent_lines or skill_lines:
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

        # Smart truncation: keep output under 8KB
        context_text = '\n'.join(lines)
        MAX_OUTPUT = 8000
        if len(context_text) > MAX_OUTPUT:
            # Prioritize: user/feedback > project > agents/skills > reference > cross-project
            # Reduce SUMMARY_LIMIT and rebuild
            for limit in [150, 100, 60]:
                truncated_lines = [lines[0]]  # keep header
                for section_key in ["user", "feedback", "project", "reference"]:
                    items = sections[section_key]
                    if not items:
                        continue
                    truncated_lines.append(f"\n== {headers[section_key]} ({len(items)}) ==")
                    for mid, doc, meta in items:
                        proj_tag = ""
                        if section_key in ("project", "reference"):
                            p = meta.get("project", "")
                            if p:
                                proj_tag = f" [{p}]"
                        summary = doc[:limit] + ("..." if len(doc) > limit else "")
                        truncated_lines.append(f"  {mid}{proj_tag}: {summary}")
                if agent_lines:
                    truncated_lines.append("\n[cortex] Available agents:")
                    truncated_lines.extend(agent_lines)
                if skill_lines:
                    truncated_lines.append("\n[cortex] Available skills:")
                    truncated_lines.extend(skill_lines)
                if doc_lines:
                    truncated_lines.append("\n[cortex] Cached docs:")
                    truncated_lines.extend(doc_lines)
                context_text = '\n'.join(truncated_lines)
                if len(context_text) <= MAX_OUTPUT:
                    break

            # If still too large, hard truncate
            if len(context_text) > MAX_OUTPUT:
                context_text = context_text[:MAX_OUTPUT] + "\n[cortex] Output truncated — use mcp__cortex__memory_search for full content."

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

    # ── LLM query expansion via claude -p (DISABLED) ───────────────
    # BUG: claude -p returns empty stdout on v2.1.83 despite generating
    # tokens (output_tokens > 0, result: ""). Filed as:
    #   https://github.com/anthropics/claude-code/issues/38774
    # TODO: Re-enable when the bug is fixed. Test with:
    #   echo "say hello" | claude -p --model haiku --max-turns 1
    # If that produces output, uncomment the block below.
    expanded_query = ""
    # try:
    #     import subprocess as _sp
    #     _expand_prompt = (
    #         "Extract 5-10 search keywords/phrases that would help find "
    #         "stored memories about tools, credentials, APIs, config, or "
    #         "project context needed to fulfil this request. "
    #         "Return ONLY the keywords, comma-separated, nothing else.\n\n"
    #         f"User message: {user_prompt[:300]}\n"
    #     )
    #     if assistant_context:
    #         _expand_prompt += f"Recent conversation context: {assistant_context[:200]}\n"
    #     _proc = _sp.run(
    #         ["claude", "-p", "--model", "haiku", "--max-turns", "1"],
    #         input=_expand_prompt, capture_output=True, text=True, timeout=4
    #     )
    #     if _proc.returncode == 0 and _proc.stdout.strip():
    #         expanded_query = _proc.stdout.strip()[:300]
    # except Exception:
    #     pass  # Timeout or missing claude — fall back to regular search

    # ── Multi-query ChromaDB search ────────────────────────────────
    n_results = min(12 if is_remember_query else 8, col.count())

    # Primary search: user prompt + assistant context
    results = col.query(
        query_texts=[search_query],
        n_results=n_results
    )

    # Secondary search: LLM-expanded keywords (if available)
    expanded_results = None
    if expanded_query:
        try:
            expanded_results = col.query(
                query_texts=[expanded_query],
                n_results=n_results
            )
        except Exception:
            pass

    # Merge results: keep best (lowest) distance per memory ID
    best = {}  # mid → (dist, index, source_results)
    for src in [results, expanded_results]:
        if src is None:
            continue
        for i in range(len(src["ids"][0])):
            mid = src["ids"][0][i]
            dist = src["distances"][0][i] if src.get("distances") else 1.0
            if mid not in best or dist < best[mid][0]:
                best[mid] = (dist, i, src)

    relevant = []
    for mid, (dist, i, src) in best.items():
        meta = src["metadatas"][0][i]
        mem_type = meta.get("type", "general")
        mem_project = meta.get("project", "")

        if mem_type == "agent_eval":
            continue

        # Recall boost: frequently recalled memories get a distance discount (closer = better)
        recall_count = int(meta.get("recall_count", "0") or "0")
        if recall_count >= 5:
            dist *= 0.85   # 15% boost for heavily recalled memories
        elif recall_count >= 2:
            dist *= 0.92   # 8% boost for moderately recalled

        # Boosted thresholds for "remember" queries, relaxed for project matches
        if is_remember_query:
            threshold = 0.85 if mem_project in matched_projects else 0.75
        else:
            threshold = 0.7 if mem_project in matched_projects else 0.6

        if dist < threshold:
            relevant.append({
                "id": mid,
                "content": src["documents"][0][i][:400],
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
