#!/bin/bash
# PreToolUse hook for Edit|Write|MultiEdit.
#
# Enforces two gates:
#
# (#3) Subsystem-declaration gate: edits adding >30 new lines to a subtree
#      with no declaration this session are blocked. Claude must first write
#      /tmp/claude-gate-<session>/declarations/<subtree-slug>.md listing the
#      subsystem files read, the invariants, and why the edit is architecturally
#      correct.
#
# (#4) Bug-fix TDD gate: if the last 20 user messages contain bug keywords
#      (bug, broken, doesn't work, fails, crash, wrong, regression), then
#      non-test edits are blocked until a tests/ file has been edited/written
#      this session. Per-file bypass via touch $GATE_DIR/bypass_bug/<sha>.
#
# Failures exit 2 with a stderr explanation (Claude Code surfaces this to the
# model). Soft failures (jq missing, malformed input) exit 0 — fail open.

set -u

INPUT="$(cat)"

# Fail open if jq is missing or input is malformed.
if ! command -v jq >/dev/null 2>&1; then exit 0; fi
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$TOOL" ] && exit 0
[ -z "$SESSION" ] && exit 0
[ -z "$CWD" ] && exit 0

GATE_DIR="/tmp/claude-gate-$SESSION"
mkdir -p "$GATE_DIR/declarations" "$GATE_DIR/bypass_bug"
EDIT_LOG="$GATE_DIR/edits.log"
touch "$EDIT_LOG"

# Extract file_path and new content depending on tool.
case "$TOOL" in
  Edit)
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
    ;;
  Write)
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    NEW=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
    ;;
  MultiEdit)
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    NEW=$(echo "$INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")')
    ;;
  *)
    exit 0
    ;;
esac
[ -z "$FILE" ] && exit 0

# Compute path-sha (used for per-file bug bypass).
FILE_SHA=$(printf '%s' "$FILE" | shasum -a 256 | awk '{print $1}')

# Scope: only enforce inside project tree. Skip /tmp, .claude/, memory/, build/, etc.
# Use absolute-path matching so shell cwd shifts (cd into tests/) don't reshape
# what counts as "inside the project". The project root is detected by walking
# up from CWD looking for a CLAUDE.md (works whether CWD is the root or a
# subdir like tests/). Falls back to CWD if no marker found.
PROJECT_ROOT="$CWD"
search="$CWD"
while [ "$search" != "/" ] && [ "$search" != "" ]; do
  if [ -f "$search/CLAUDE.md" ]; then PROJECT_ROOT="$search"; break; fi
  search=$(dirname "$search")
done

case "$FILE" in
  /tmp/*) echo "$FILE" >> "$EDIT_LOG"; exit 0 ;;
  */.claude/*|*/memory/*|*/build/*|*/graphify-out/*|*/.git/*|*/specs/*)
    echo "$FILE" >> "$EDIT_LOG"; exit 0 ;;
esac
case "$FILE" in
  "$PROJECT_ROOT"/*) ;;
  *) echo "$FILE" >> "$EDIT_LOG"; exit 0 ;;
esac
REL="${FILE#$PROJECT_ROOT/}"

# Line count of new content.
LINES=$(printf '%s' "$NEW" | awk 'END{print NR}')

# Subtree = first 3 components of relative path.
SUBTREE=$(echo "$REL" | awk -F'/' '{ if (NF>=3) print $1"/"$2"/"$3; else print $0 }')
SLUG=$(echo "$SUBTREE" | tr '/' '-')

# --- Bug gate (#4) ---
BUG_TRIGGER=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  RECENT_USER=$(tail -n 800 "$TRANSCRIPT" 2>/dev/null \
    | jq -r 'select(.type=="user") | .message.content | if type=="array" then (.[] | if type=="object" then (.text // "") else . end) else . end' 2>/dev/null \
    | tail -n 20)
  if echo "$RECENT_USER" | grep -Eiq "\b(bug|broken|doesn't work|isn't working|not working|fails|failing|crash|crashed|wrong|regression)\b"; then
    BUG_TRIGGER=1
  fi
fi

if [ "$BUG_TRIGGER" = "1" ]; then
  case "$REL" in
    tests/*|*/tests/*)
      : # editing a test — allow
      ;;
    *)
      if [ ! -f "$GATE_DIR/bypass_bug/$FILE_SHA" ] && ! grep -Eq '(^|/)tests/' "$EDIT_LOG"; then
        cat >&2 <<EOF
GATE BLOCKED — bug-fix TDD required.

Recent user messages contain bug-fix keywords, and no test file has
been edited or written this session.

Per MEMORY.md (feedback_tdd_before_fix.md): when addressing a bug,
write a failing regression test FIRST, verify it fails, only then
fix the production code.

To proceed (in order):
  1. Create or edit a test under tests/ that reproduces the bug.
  2. Run it; confirm it FAILS for the right reason.
  3. Then come back to this edit.

If this edit is not a bug fix and the keyword match is a false
positive, bypass for THIS FILE only:

  touch $GATE_DIR/bypass_bug/$FILE_SHA   # file: $REL

Bypass is per-file, per-session. Use it only when the gate is wrong
about THIS edit — not as a routine escape hatch.
EOF
        exit 2
      fi
      ;;
  esac
fi

# --- Size gate (#3) ---
THRESHOLD=30
DECL="$GATE_DIR/declarations/$SLUG.md"
if [ "$LINES" -gt "$THRESHOLD" ] && [ ! -f "$DECL" ]; then
  case "$REL" in
    tests/*|*/tests/*|*.md|*.toml|*.json|*.txt)
      : # tests, docs, config — skip
      ;;
    *)
      cat >&2 <<EOF
GATE BLOCKED — subsystem declaration required.

This edit adds $LINES lines to subtree '$SUBTREE' (threshold: $THRESHOLD)
and no declaration exists for that subtree this session.

Per CLAUDE.md and MEMORY.md (feedback_no_shortcuts_read_first.md,
feedback_read_before_act.md, feedback_architectural_correctness.md):
read the subsystem fully before changing it.

Write the declaration FIRST at:

  $DECL

Required (3 bullets minimum):
  1. Subsystem files READ this session (≥3, with paths). The Read
     tool calls must have happened — don't invent them.
  2. The invariants / contracts you intend to preserve.
  3. Why this edit is architecturally correct — not a workaround,
     fallback, or special-case patch over a broken abstraction.

Then retry the edit. Declarations persist for the session and cover
all edits in the same subtree.
EOF
      exit 2
      ;;
  esac
fi

echo "$FILE" >> "$EDIT_LOG"
exit 0
