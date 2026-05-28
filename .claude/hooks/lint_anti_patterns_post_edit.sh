#!/bin/bash
# PostToolUse hook: run lint_anti_patterns.sh on the file that was just edited.
# Emits violations as additionalContext so Claude sees them inline. Does NOT
# block (exit 0 always) — block-on-violation belongs to the pre-commit hook;
# this layer is in-session feedback so Claude can fix before committing.

set -u
INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$TOOL" ] && exit 0
[ -z "$CWD" ] && exit 0

case "$TOOL" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

# Find project root by walking up for CLAUDE.md (matches pre_edit_gate.sh).
ROOT="$CWD"
search="$CWD"
while [ "$search" != "/" ] && [ "$search" != "" ]; do
    if [ -f "$search/CLAUDE.md" ]; then ROOT="$search"; break; fi
    search=$(dirname "$search")
done

LINT="$ROOT/scripts/lint_anti_patterns.sh"
[ ! -x "$LINT" ] && exit 0

VIOLATIONS=$("$LINT" "$FILE" 2>/dev/null)
[ -z "$VIOLATIONS" ] && exit 0

# Escape for JSON.
MSG=$(printf 'LINT: anti-pattern violation(s) detected in %s:\n%s\n\nFix in this edit (preferred) or add `-- lint-allow: <rule_id> <reason>` (Lua) / `// lint-allow: <rule_id> <reason>` (C++) on the offending line with an explicit reason. Rule descriptions in scripts/lint_anti_patterns.md.' "$FILE" "$VIOLATIONS" \
    | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$MSG}}
EOF
exit 0
