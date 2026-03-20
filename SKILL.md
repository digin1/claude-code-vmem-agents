---
name: cortex
description: Cortex — self-evolving memory and agent fleet — store, search, and manage memories with semantic search across all projects
argument-hint: <store|search|list|delete|update|stats|agents|discover|learn> [args...]
allowed-tools: "mcp__cortex__memory_store, mcp__cortex__memory_search, mcp__cortex__memory_list, mcp__cortex__memory_delete, mcp__cortex__memory_update, mcp__cortex__memory_stats, Bash, Read, Glob, Write, WebSearch, WebFetch, Agent"
---

# Cortex Memory System

You have access to a persistent vector memory database (ChromaDB) via MCP tools. This memory is **global** — shared across all projects.

**IMPORTANT: Always use the MCP tools (mcp__cortex__memory_store, etc.) — NEVER call memory_db.py via Bash.** The MCP tools provide clean CLI output with spinners and status messages.

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
- `/cortex discover` → auto-discover project skills with web research (see below)
- `/cortex learn` → session review (see below)
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

## Skill Discovery (`/cortex discover`)

When the user runs `/cortex discover`, perform a deep skill discovery for the current project. Unlike the automatic SessionStart hook (which uses LLM knowledge only), this manual command uses **web research** for more detailed, current results.

### Steps:

1. **Detect tech stack** — run the detector:
```bash
/usr/bin/python3 ~/.claude/skills/cortex/lib/skill_detect.py "$(pwd)" 2>/dev/null
```

2. **Show detected frameworks** — display what was found and ask the user if they want skills for all or specific ones.

3. **Research online** — for each framework the user wants skills for:
   - Use `WebSearch` to find current best practices, patterns, and conventions (e.g., "FastAPI best practices 2026", "Next.js app router patterns")
   - Use `WebFetch` to read authoritative docs if needed
   - Also `Read` the actual project code to understand the user's specific patterns and conventions

4. **Generate skill files** — create `.md` command files that encode:
   - Framework-specific best practices from web research
   - Project-specific patterns from code analysis
   - Testing approaches appropriate for the framework
   - Common scaffolding patterns
   - Each skill should have YAML frontmatter with `description:` and a detailed prompt body

5. **Write files** — use `Write` to create `.md` files in:
   - `.claude/commands/` (project-level, framework-specific skills)
   - `~/.claude/commands/` (global, cross-project utility skills)
   - Use kebab-case filenames matching the command name (e.g., `fastapi-endpoint.md` → `/fastapi-endpoint`)

6. **Store in cortex** — record what was discovered using `memory_store`:
   - `memory_id`: `skill_discovery_<project_name>`
   - `memory_type`: `project`
   - Content: list of created skills and frameworks covered

7. **Report** — show the user what skills were created and how to use them (e.g., "Run `/fastapi-endpoint create user endpoint` to scaffold a new endpoint").

### Quality guidelines for generated skills:
- `description:` must be clear and actionable (shown in command palette)
- Body must contain SPECIFIC instructions, not generic advice
- Include framework conventions, file structure patterns, testing idioms
- Use `$ARGUMENTS` to accept user input
- Keep each skill focused on ONE task (scaffold, test, debug, deploy)
- Max 5-7 skills per framework — pick the most useful ones

### Example skill file (for reference):
```markdown
---
description: Scaffold a new FastAPI endpoint with Pydantic models and tests
---

Create a new FastAPI endpoint based on the user's description: $ARGUMENTS

Follow these conventions:
1. Use async def for route handlers
2. Define Pydantic models for request/response in a models file
3. Use Depends() for shared dependencies (db, auth)
4. Add proper status codes (201 create, 404 not found, 422 validation)
5. Include OpenAPI metadata: summary, description, response_model
6. Add the route to the appropriate router
7. Write tests using TestClient covering success + error paths
8. Follow the existing project structure and naming conventions
```

## Session Review (`/cortex learn`)

When the user runs `/cortex learn`, review the current conversation and extract any learnings worth persisting. Look for:

1. **Feedback** — corrections the user made, approaches they approved/rejected, preferences expressed
2. **Project** — decisions, constraints, or context about ongoing work that isn't in the code
3. **Reference** — external resources, deployment patterns, or lookup info discovered
4. **User** — new info about the user's role, expertise, or working style

For each finding:
- Check if a similar memory already exists (use `memory_search`) — update rather than duplicate
- Store with a descriptive `memory_id`, appropriate `memory_type`, and relevant `tags`
- Include the project name if the learning is project-specific

Report what you stored in a brief summary. If nothing new was learned, say so.
