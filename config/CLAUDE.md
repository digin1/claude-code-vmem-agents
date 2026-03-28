# Global Instructions

## Cortex Memory System

A persistent vector memory system (cortex) is available via MCP tools. It stores knowledge across sessions and projects using ChromaDB semantic search.

### MCP Tools

- `memory_store` — Store with auto dedup detection (warns if >85% similar memory exists)
- `memory_search` — Semantic search (shows similarity %)
- `memory_update` — Update content (modes: replace/append/prepend) or metadata (tags: "+tag" to append)
- `memory_merge` — Consolidate 2+ related memories into one
- `memory_list`, `memory_delete`, `memory_stats`

### Memory Types

- `user` — Role, expertise, identity ("I am X", "I know Y")
- `feedback` — Corrections, rules ("don't do X", "always do Y")
- `preferences` — Config choices, workflow settings ("I prefer X", "use Y for Z")
- `project` — Decisions, architecture, constraints
- `reference` — External resources, URLs, configs, service endpoints

### Behavioral Rules

- When the user asks "do you remember", "recall", or references past conversations — ALWAYS call `mcp__cortex__memory_search` BEFORE saying you don't have the information.
- The `UserPromptSubmit` hook auto-injects relevant memories, but may miss some. Search manually when needed.
- Store new learnings proactively — distinguish between feedback (corrections), preferences (config choices), and user (identity).
- Before storing, the tool auto-checks for near-duplicates. If warned, use `memory_update` instead.
- When 3+ memories cover the same topic, use `memory_merge` to consolidate.

### Slash Commands

- `/cortex store|search|list|delete|update|stats` — Direct memory operations
- `/cortex merge <id1,id2,...>` — Merge related memories
- `/cortex discover` — Deep skill discovery with web research
- `/cortex addskill <description>` — Create a new slash-command skill
- `/cortex agents` — Agent fleet dashboard
- `/cortex config [key] [value]` — Toggle auto_learn, auto_skills, auto_agents
- `/cortex learn` — Manual session review

## Specialized Agents

Project-specific agents are available in `.claude/agents/`. Global agents in `~/.claude/agents/`. The first-message recall hook injects the full inventory (name + description) so you know what's available.

- **Prefer specialized agents** over general-purpose when a task matches an agent's description — they have domain knowledge and cortex memories injected via the SubagentStart hook.
- Agents are also auto-created from session patterns at session end (via learn.sh). Duplicate detection via semantic similarity (cosine distance < 0.55) prevents redundancy.

### Key Global Agents

- **Code Documenter** (`code-documenter`) — generates architecture docs, API references, module guides as `.md` files inside the project's `docs/` directory. Use when the user asks to document code, create a README, or explain the codebase structure.
- **Simulation Tester** (`simulation-tester`) — creates tests using realistic but fabricated data. Reads codebase in **read-only mode** (never modifies source), writes test files only. Use when the user asks for tests, mock data, or test coverage without touching real data.

### Creating Agents Inline

When you spot a recurring pattern that would benefit from a specialized agent, create one directly:

1. Write the `.md` file to the appropriate directory:
   - **Project-specific**: `.claude/agents/<name>.md` — references project files, services, architecture
   - **Global/reusable**: `~/.claude/agents/<name>.md` — generic specialist across projects
2. Use this frontmatter format:
   ```yaml
   ---
   name: <Display Name>
   description: <When to use this agent — one line>
   model: sonnet
   ---

   <System prompt with detailed instructions>
   ```
3. Update cortex inventory: `mcp__cortex__memory_update` on `inventory_agents` (mode=append) with the new agent entry. This keeps the inventory searchable across sessions.

## Skills (Slash Commands)

Skills are slash-command `.md` files in `.claude/commands/` (project) or `~/.claude/commands/` (global). The first-message recall hook injects the full inventory so you know what's available.

- **Use skills proactively** — when a task matches an available skill, suggest or invoke it.
- Skills are also auto-discovered from project tech stacks on session start, and improved at session end via learn.sh.
- For deeper, web-researched skills, suggest `/cortex discover`.

### Creating Skills Inline

When you identify a reusable multi-step workflow, create a skill directly:

1. Write the `.md` file:
   - **Project-specific**: `.claude/commands/<skill-name>.md`
   - **Global**: `~/.claude/commands/<skill-name>.md`
2. Use this format:
   ```yaml
   ---
   description: <One-line description shown in command palette>
   ---

   <Detailed instructions for Claude when invoked>
   $ARGUMENTS captures user input after the command name.
   ```
3. Update cortex inventory: `mcp__cortex__memory_update` on `inventory_skills` (mode=append) with the new skill entry. This keeps the inventory searchable across sessions.

### Placement Rules
- **Local** (`.claude/commands/`): References project-specific paths, containers, tables, architecture
- **Global** (`~/.claude/commands/`): Generic CLI wrappers, cross-project utilities

