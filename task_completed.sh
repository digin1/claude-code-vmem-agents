#!/bin/bash
# TaskCompleted hook: log completed tasks for project tracking
# Stores task completions as lightweight project context

INPUT=$(cat 2>/dev/null)

/usr/bin/python3 -W ignore - "$INPUT" 2>/dev/null <<'PYEOF'
import sys, json, os, time

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except:
    sys.exit(0)

task = d.get("task", {})
subject = task.get("subject", "") if isinstance(task, dict) else str(task)[:200]
cwd = d.get("cwd", "")

if not subject:
    sys.exit(0)

# Log to session tasks file (rotated per day)
TASKS_LOG = os.path.expanduser("~/.claude/.cortex_tasks_log")
try:
    import stat
    fd = os.open(TASKS_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "a") as f:
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "subject": subject[:200],
            "cwd": cwd,
        }
        f.write(json.dumps(entry) + "\n")
except:
    pass

# Rotate if >100KB
try:
    if os.path.exists(TASKS_LOG) and os.path.getsize(TASKS_LOG) > 100_000:
        cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - 30 * 86400))
        with open(TASKS_LOG) as f:
            lines = [l for l in f if l[:10] >= cutoff]
        import tempfile
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(TASKS_LOG))
        with os.fdopen(tmp_fd, "w") as f:
            f.writelines(lines)
        os.replace(tmp_path, TASKS_LOG)
except:
    pass

PYEOF
