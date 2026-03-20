# Skill Discovery Rules

## Auto-Discovered Skills Awareness

On session start, the `skill_discover.sh` hook silently detects the project's tech stack and generates slash-command `.md` files. These appear in:
- `.claude/commands/` (project-level, framework-specific)
- `~/.claude/commands/` (global, cross-project)

### When to surface auto-discovered skills

1. **First interaction in a project** — if `.claude/commands/` has auto-generated skill files, briefly list them so the user knows they exist. Keep it to one line (e.g., "Auto-discovered skills available: `/flask-endpoint`, `/flask-test`, `/flask-debug`").
2. **When the user asks what commands are available** — include auto-discovered skills alongside built-in ones.
3. **When the user is about to do a task that a skill covers** — suggest the relevant skill (e.g., "You can use `/fastapi-endpoint` to scaffold this with best practices").

### Manual discovery with web research

`/cortex discover` triggers a deeper discovery that:
- Uses `WebSearch` to research current framework best practices online
- Reads the actual project code for project-specific conventions
- Generates richer, more detailed skills than the automatic path
- Bypasses the weekly cooldown

Suggest this when:
- The user is working with a newer or less common framework
- The user wants more detailed or up-to-date skills
- Auto-generated skills feel too generic

### Skill file format reference

```markdown
---
description: One-line description (shown in command palette)
---

Detailed instructions for Claude when invoked.
$ARGUMENTS captures user input after the command name.
```
