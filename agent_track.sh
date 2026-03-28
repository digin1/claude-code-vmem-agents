#!/bin/bash
# PostToolUse hook for Agent tool — logs spawns + injects relevant memories
# Receives JSON on stdin with tool_input containing agent details

INPUT=$(cat 2>/dev/null)

# Pass input via env var since heredoc takes stdin
VMEM_HOOK_INPUT="$INPUT" /usr/bin/python3 -W ignore - 2>/dev/null <<'PYEOF'
import sys, json, time, os

raw = os.environ.get('VMEM_HOOK_INPUT', '').strip()
if not raw:
    sys.exit(0)

try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

# Extract agent info from tool input
tool_input = d.get('tool_input', {})
if isinstance(tool_input, str):
    try: tool_input = json.loads(tool_input)
    except Exception: tool_input = {}

agent_type = tool_input.get('subagent_type', 'general-purpose')
description = tool_input.get('description', '')
model = tool_input.get('model', 'inherit')

# Log to usage ledger
entry = {
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%S'),
    'agent': agent_type,
    'description': description,
    'model': model,
    'cwd': d.get('cwd', '')
}

ledger = os.path.expanduser('~/.claude/agent-usage.jsonl')
try:
    with open(ledger, 'a') as f:
        f.write(json.dumps(entry) + '\n')
        f.flush()
        os.fsync(f.fileno())
except Exception:
    pass

# Search cortex for context relevant to what the agent just did
if description:
    try:
        sys.path.insert(0, os.path.expanduser("~/.claude/skills/cortex/lib"))
        from chroma_client import get_client, get_collection

        col = get_collection()
        if col.count() > 0:
            results = col.query(query_texts=[description[:300]], n_results=min(3, col.count()))
            relevant = []
            for i in range(len(results['ids'][0])):
                dist = results['distances'][0][i] if results.get('distances') else 1.0
                if dist < 0.4:
                    mem_type = results['metadatas'][0][i].get('type', 'general')
                    if mem_type == 'agent_eval':
                        continue
                    mem_id = results['ids'][0][i]
                    mem_doc = results['documents'][0][i][:200]
                    relevant.append(f"  [{mem_type}] {mem_id}: {mem_doc}")
            if relevant:
                context = '[cortex] Memories relevant to agent task:\n' + '\n'.join(relevant)
                print(json.dumps({
                    'suppressOutput': True,
                    'hookSpecificOutput': {
                        'hookEventName': 'PostToolUse',
                        'additionalContext': context
                    }
                }))
                sys.exit(0)
    except:
        pass

# No context to inject — silent exit
print(json.dumps({'suppressOutput': True}))
PYEOF
