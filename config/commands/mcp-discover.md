---
description: Discover and suggest MCP servers relevant to the current project's tech stack
---

# MCP Server Discovery

Analyze the current project and find MCP servers that would accelerate development.

## Steps

### 1. Detect Tech Stack
Scan the project for:
- `package.json` (Node.js deps — database clients, APIs, frameworks)
- `requirements.txt` / `pyproject.toml` (Python deps)
- `docker-compose.yml` (services — postgres, redis, mongo, etc.)
- `.env` / `.env.example` (API keys — Stripe, GitHub, Slack, etc.)
- `Dockerfile`, `Makefile`, CI configs
- Any `mcp.json` or `.mcp.json` already present

### 2. Check Existing MCP Servers
Run `claude mcp list` to see what's already configured. Don't suggest duplicates.

### 3. Web Search for MCP Servers
For each detected technology/service, search:
- `"MCP server" <technology> site:github.com`
- `"model context protocol" <technology> server`
- `npmjs.com mcp-server-<technology>`
- `pypi.org mcp-server-<technology>`

Focus on:
- **Databases**: postgres, mysql, sqlite, mongodb, redis
- **APIs**: GitHub, Slack, Linear, Jira, Notion, Stripe
- **Dev tools**: Docker, Kubernetes, Terraform, AWS
- **Search**: Elasticsearch, Algolia
- **File formats**: PDF, CSV, Excel

### 4. Evaluate Each Found Server
For each candidate, check:
- GitHub stars / recent activity (skip abandoned projects)
- Installation method (`npx`, `uvx`, `docker`)
- Whether it requires API keys the user already has

### 5. Present Results
Show a table:

```
| MCP Server | Why | Install Command | Stars |
|------------|-----|-----------------|-------|
```

### 6. Install (if user confirms)
For each approved server, run:
```bash
claude mcp add <name> -s user -- <command> <args>
```

Store the discovery results as a cortex memory (type: reference) so future sessions know what's available.

## Rules
- Only suggest servers with >100 GitHub stars or from verified publishers
- Prefer `npx`/`uvx` servers (no manual install needed)
- Don't suggest servers for technologies not actually used in the project
- If $ARGUMENTS contains a specific technology, search only for that
- Max 10 suggestions per run
