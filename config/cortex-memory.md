# Cortex Memory Rules

## Mandatory Search Before "I Don't Know"

When the user asks about past conversations, prior decisions, or uses phrases like "do you remember", "recall", "did we discuss", "last time we" — you MUST:

1. Check the auto-injected cortex context (system-reminder with `[cortex]` prefix) first
2. If not found there, call `mcp__cortex__memory_search` with a relevant query
3. Only after both checks return nothing may you say you don't have the information

## Proactive Storage

Store memories when you observe:
- User corrections or approach rules (type: feedback)
- Configuration choices, workflow preferences, tool settings (type: preferences)
- Project decisions, constraints, or deadlines (type: project)
- External resource locations — URLs, file paths, credentials config (type: reference)
- New information about the user's role or expertise (type: user)

**Type distinction:**
- `feedback` = "don't do X" / "always do Y" — corrections and rules
- `preferences` = "I prefer X" / "use Y for Z" — configuration choices and defaults
- `user` = "I am X" / "I know Y" — identity and expertise

Always include a `project` tag when the memory is project-specific.

## Memory Hygiene

- Before storing, search for existing similar memories to avoid duplicates
- When a near-duplicate is found, use `memory_update` (mode=append or replace) instead of creating new
- When 3+ memories cover the same topic, use `memory_merge` to consolidate
- Use descriptive `memory_id` values (e.g., `pref_notify_off`, `feedback_no_mocks_in_tests`)
- Keep content concise — under 1000 chars when possible, max 5000
