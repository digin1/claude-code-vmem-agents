# Global Instructions

## Cortex Memory System

A persistent vector memory system (cortex) is available via MCP tools. It stores knowledge across sessions and projects using ChromaDB semantic search.

### Behavioral Rules

- When the user asks "do you remember", "recall", "do you know about", or references past conversations — ALWAYS call `mcp__cortex__memory_search` BEFORE saying you don't have the information. Never say "I don't have a specific memory stored" without searching first.
- The `UserPromptSubmit` hook auto-injects relevant memories as context, but it may miss some due to semantic distance thresholds. When the auto-injected context doesn't cover the user's question, search manually.
- When you learn something new about the user, their project, workflow, or preferences that would be useful in future sessions, store it in cortex using `mcp__cortex__memory_store` with an appropriate `memory_type` (user, feedback, project, reference).
- Use `/cortex learn` at end of productive sessions to extract and store learnings.

## Specialized Agents

Project-specific agents are available in `.claude/agents/`. When a task matches an agent's description, prefer using it over the general-purpose agent — specialized agents have domain knowledge and cortex memories injected automatically via the SubagentStart hook.

## Auto-Skill Discovery

Cortex automatically detects project tech stacks (FastAPI, Next.js, Flask, etc.) on session start and generates slash-command skill files (`.md`) in `.claude/commands/` (project) or `~/.claude/commands/` (global). These skills encode framework-specific best practices and are immediately available as `/command-name`.

### Behavioral Rules

- When starting work in a project, check if auto-discovered skills exist in `.claude/commands/`. If they do, mention them briefly so the user knows they're available (e.g., "This project has auto-discovered skills: `/flask-endpoint`, `/flask-test`").
- When the user asks about available skills or commands, include auto-discovered ones.
- If the user wants deeper, web-researched skills, suggest `/cortex discover` — it uses WebSearch for current best practices unlike the automatic path which uses LLM knowledge only.
- Auto-discovered skills have a weekly cooldown per project. If the user wants to regenerate, `/cortex discover` bypasses cooldown.
- The detection system covers: Node.js (Next.js, React, Vue, Express, etc.), Python (FastAPI, Django, Flask, etc.), Go, Rust, Ruby, Java, and infrastructure tools (Docker, K8s, Terraform, CI/CD).
