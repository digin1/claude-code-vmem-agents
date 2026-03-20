# Cortex Memory Rules

## Mandatory Search Before "I Don't Know"

When the user asks about past conversations, prior decisions, or uses phrases like "do you remember", "recall", "did we discuss", "last time we" — you MUST:

1. Check the auto-injected cortex context (system-reminder with `[cortex]` prefix) first
2. If not found there, call `mcp__cortex__memory_search` with a relevant query
3. Only after both checks return nothing may you say you don't have the information

## Proactive Storage

Store memories when you observe:
- User corrections or preferences (type: feedback)
- Project decisions, constraints, or deadlines (type: project)
- External resource locations — URLs, file paths, credentials config (type: reference)
- New information about the user's role or expertise (type: user)

Always include a `project` tag when the memory is project-specific.

## Memory Hygiene

- Before storing, search for existing similar memories to avoid duplicates
- Use descriptive `memory_id` values (e.g., `feedback_no_mocks_in_tests`, `reference_gitlab_api`)
- Keep content concise — under 1000 chars when possible, max 5000
