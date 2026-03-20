#!/usr/bin/env python3
"""Create skill .md command files from claude -p output.

Takes JSON string (claude -p output) as argv[1] and CWD as argv[2].
Writes .md command files to project or global commands directory.

Output format expected from claude -p:
[{
    "scope": "project" | "global",
    "filename": "framework-action.md",
    "content": "---\ndescription: What this skill does\n---\n\nPrompt content..."
}]

Safety:
  - Max 10 project skills, 10 global skills
  - Won't overwrite existing files
  - Sanitizes filenames
  - Validates frontmatter structure
"""
import sys
import json
import os
import re


def strip_code_fences(raw):
    """Remove markdown code fences from raw text."""
    raw = raw.strip()
    if raw.startswith("```"):
        lines = raw.split("\n")
        raw = "\n".join(l for l in lines if not l.startswith("```"))
    return raw


def parse_json_array(raw):
    """Parse JSON array from raw text, with regex fallback."""
    raw = strip_code_fences(raw)
    try:
        return json.loads(raw)
    except Exception:
        match = re.search(r"\[.*\]", raw, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except Exception:
                return []
        return []


def validate_skill_content(content):
    """Check that skill content has valid frontmatter with description."""
    if "---" not in content:
        return False
    # Must have at least description in frontmatter
    if "description:" not in content.split("---")[1] if content.count("---") >= 2 else "":
        return False
    return True


def get_existing_skills(cwd):
    """Collect names of existing skill commands from both scopes."""
    existing = set()
    for cmd_dir in [
        os.path.expanduser("~/.claude/commands"),
        os.path.join(cwd, ".claude", "commands") if cwd else "",
    ]:
        if cmd_dir and os.path.isdir(cmd_dir):
            for fname in os.listdir(cmd_dir):
                if fname.endswith(".md"):
                    existing.add(fname)
    return existing


MAX_PROJECT_SKILLS = 10
MAX_GLOBAL_SKILLS = 10


def count_skills(cwd):
    """Count existing skills per scope."""
    project_cmd_dir = os.path.join(cwd, ".claude", "commands") if cwd else ""
    global_cmd_dir = os.path.expanduser("~/.claude/commands")

    project_count = 0
    global_count = 0

    if project_cmd_dir and os.path.isdir(project_cmd_dir):
        project_count = len([f for f in os.listdir(project_cmd_dir) if f.endswith(".md")])
    if os.path.isdir(global_cmd_dir):
        global_count = len([f for f in os.listdir(global_cmd_dir) if f.endswith(".md")])

    return project_count, global_count


def create_skills(raw, cwd):
    """Parse skill definitions and create .md files. Returns count of created."""
    skills = parse_json_array(raw)
    if not isinstance(skills, list):
        skills = []

    existing = get_existing_skills(cwd)
    project_count, global_count = count_skills(cwd)
    created = 0

    for skill in skills[:10]:
        if not isinstance(skill, dict):
            continue

        filename = skill.get("filename", "")
        content = skill.get("content", "")
        scope = skill.get("scope", "project")

        if not filename or not content or not filename.endswith(".md"):
            continue

        # Sanitize filename — only allow lowercase alphanumeric, hyphens, dots
        filename = re.sub(r"[^a-z0-9\-_.]", "", filename.lower())
        if not filename or filename == ".md":
            continue

        # Validate content has proper frontmatter
        if not validate_skill_content(content):
            print(f"[skill-discover] Skipped '{filename}': invalid frontmatter", file=sys.stderr)
            continue

        # Skip if already exists
        if filename in existing:
            print(f"[skill-discover] Skipped '{filename}': already exists", file=sys.stderr)
            continue

        # Cap check
        if scope == "project" and project_count >= MAX_PROJECT_SKILLS:
            print(f"[skill-discover] Skipped '{filename}': project skill cap reached", file=sys.stderr)
            continue
        if scope == "global" and global_count >= MAX_GLOBAL_SKILLS:
            print(f"[skill-discover] Skipped '{filename}': global skill cap reached", file=sys.stderr)
            continue

        # Determine target directory
        if scope == "project":
            target_dir = os.path.join(cwd, ".claude", "commands") if cwd else ".claude/commands"
        else:
            target_dir = os.path.expanduser("~/.claude/commands")

        os.makedirs(target_dir, exist_ok=True)
        skill_path = os.path.join(target_dir, filename)

        if os.path.exists(skill_path):
            continue

        try:
            with open(skill_path, "w") as f:
                f.write(content)
            created += 1
            existing.add(filename)
            if scope == "project":
                project_count += 1
            else:
                global_count += 1
            print(f"[skill-discover] Created skill: {skill_path}", file=sys.stderr)
        except Exception as e:
            print(f"[skill-discover] Failed to create {skill_path}: {e}", file=sys.stderr)

    print(created)
    return created


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    if not raw:
        print("0")
        sys.exit(0)
    create_skills(raw, cwd)


if __name__ == "__main__":
    main()
