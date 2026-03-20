# Global Instructions

## Cortex Memory System

A persistent vector memory system (cortex) is available via MCP tools. It stores knowledge across sessions and projects using ChromaDB semantic search.

### Behavioral Rules

- When the user asks "do you remember", "recall", "do you know about", or references past conversations — ALWAYS call `mcp__cortex__memory_search` BEFORE saying you don't have the information. Never say "I don't have a specific memory stored" without searching first.
- The `UserPromptSubmit` hook auto-injects relevant memories as context, but it may miss some due to semantic distance thresholds. When the auto-injected context doesn't cover the user's question, search manually.
- When you learn something new about the user, their project, workflow, or preferences that would be useful in future sessions, store it in cortex using `mcp__cortex__memory_store` with an appropriate `memory_type` (user, feedback, project, reference).
- Use `/cortex learn` at end of productive sessions to extract and store learnings.
