---
name: cortex
description: Cortex — self-evolving memory and agent fleet — store, search, and manage memories with semantic search across all projects
argument-hint: <store|search|list|delete|update|stats|agents> [args...]
allowed-tools: "mcp__vector-memory__memory_store, mcp__vector-memory__memory_search, mcp__vector-memory__memory_list, mcp__vector-memory__memory_delete, mcp__vector-memory__memory_update, mcp__vector-memory__memory_stats, Bash, Read, Glob"
---

# Vector Memory Database

You have access to a persistent vector memory database (ChromaDB) via MCP tools. This memory is **global** — shared across all projects.

**IMPORTANT: Always use the MCP tools (mcp__vector-memory__memory_store, etc.) — NEVER call memory_db.py via Bash.** The MCP tools provide clean CLI output with spinners and status messages.

## MCP Tools Available

- `memory_store` — Store a memory with embedding
- `memory_search` — Semantic similarity search
- `memory_list` — List all memories (with optional filters)
- `memory_delete` — Delete by ID
- `memory_update` — Update content or metadata
- `memory_stats` — Show DB statistics

## Interpreting the user's request

Parse `$ARGUMENTS` to determine the command:

- `/cortex store <content>` → call `memory_store`
- `/cortex search <query>` → call `memory_search`
- `/cortex list` → call `memory_list`
- `/cortex delete <id>` → call `memory_delete`
- `/cortex update <id> <content>` → call `memory_update`
- `/cortex stats` → call `memory_stats`
- `/cortex agents` → run agent fleet dashboard (see below)
- `/cortex` with no args → call `memory_stats`

When storing, always:
1. Choose an appropriate `memory_type` based on content (user, feedback, project, reference, general)
2. Generate a meaningful `memory_id` (e.g., `feedback_no_emojis`, `user_role_datasci`)
3. Add relevant `tags`

When searching, show results in a readable format with ID, content, type, and similarity score.

## Agent Fleet Dashboard (`/cortex agents`)

When the user runs `/cortex agents`, provide a comprehensive fleet health report by running:

```bash
python3 -W ignore ~/.claude/skills/cortex/agent_dashboard.py 2>/dev/null
```

Then format the JSON output into a readable table showing:
- Agent name, scope (user/project), model
- Usage count and last used date (from `~/.claude/agent-usage.jsonl`)
- Latest eval score and notes (from cortex `agent_eval` type memories)
- Health indicator based on score + usage

If the user says `/cortex agents <name>`, show detailed info for that specific agent (read its .md file, full eval history, usage timeline).
