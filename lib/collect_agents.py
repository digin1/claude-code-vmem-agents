#!/usr/bin/env python3
"""Collect agent inventory from ~/.claude/agents and .claude/agents.

Outputs JSON array of {path, filename, name, scope, content} objects.
"""
import os
import glob
import json
import warnings

warnings.filterwarnings("ignore")


def collect_agents():
    """Collect all agent .md files from user and project scopes."""
    agents = []
    for scope, d in [
        ("user", os.path.expanduser("~/.claude/agents")),
        ("project", ".claude/agents"),
    ]:
        for f in sorted(glob.glob(os.path.join(d, "*.md"))):
            try:
                with open(f) as fh:
                    content = fh.read()
                name = os.path.basename(f)
                agent_name = name
                for line in content.split("\n"):
                    if line.strip().startswith("name:"):
                        agent_name = line.split(":", 1)[1].strip()
                        break
                agents.append(
                    {
                        "path": os.path.abspath(f),
                        "filename": name,
                        "name": agent_name,
                        "scope": scope,
                        "content": content,
                    }
                )
            except Exception:
                pass
    return agents


def main():
    agents = collect_agents()
    print(json.dumps(agents))


if __name__ == "__main__":
    main()
