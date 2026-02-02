---
description: Commit all dirty files in logical groups following CLAUDE.md and ENGINEERING.md rules
---

# Commit All (/ca)

Commit all dirty files in the repo in logical, well-grouped commits.

## Workflow

1. **Survey**: Run `git status` and `git diff --stat` to see all dirty files (tracked + untracked)
2. **Read diffs**: Read every diff to understand what changed and why
3. **Group logically**: Cluster files into coherent commits by feature/fix/refactor. Each commit should be a single logical change that makes sense independently. Common groupings:
   - Schema + DB helpers + state module + tests = one feature commit
   - Keybindings that depend on the above = separate commit
   - C++ binding additions = separate commit if independent
   - Bug fixes = separate commit per fix
4. **Order commits**: Dependencies first (e.g., schema before UI that uses it)
5. **Stage and commit each group** using `git add <specific files>` (never `git add -A` or `git add .`)

## Commit Message Rules

Per CLAUDE.md rule 2.8, every commit message MUST end with:
```
Authored-By: Joe Shapiro <joe@shapiro.net>
With-Help-From: Claude
```

Message format:
- First line: `type: concise summary` (feat/fix/refactor/test/docs)
- Blank line
- Body: 1-3 lines explaining what and why (not how)
- Blank line
- Attribution lines

Use HEREDOC format for `git commit -m`:
```bash
git commit -m "$(cat <<'EOF'
type: summary

Body text.

Authored-By: Joe Shapiro <joe@shapiro.net>
With-Help-From: Claude
EOF
)"
```

## Rules

- NEVER commit files that look like secrets (.env, credentials, tokens)
- NEVER use `git add -A` or `git add .`
- Stage specific files by name for each logical group
- Read EVERY diff before deciding groups — don't guess from filenames
- If a file has changes belonging to two different logical groups, note this and ask the user how to proceed
- Run `git status` after the final commit to verify clean tree
- Show the final `git log --oneline` of all new commits

$ARGUMENTS
