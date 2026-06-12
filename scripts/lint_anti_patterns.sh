#!/bin/bash
# JVE anti-pattern linter.
#
# Scans files for patterns that 14+ audit passes have repeatedly found to
# hide real bugs. Designed to be called from:
#   • PostToolUse hook (per-edit, in-session warning)
#   • pre-commit hook (per-staged-file, block before history)
#   • CI / manual sweep (per-file or per-directory)
#
# Each rule has a STABLE id (`R001`, `R002`, ...) so the inline exemption
# `-- lint-allow: R005 reason` or `// lint-allow: R005 reason` can disable
# a specific rule on a specific line without disabling the whole linter.
# Reason text is REQUIRED to make exemptions reviewable in PRs.
#
# Usage:
#   scripts/lint_anti_patterns.sh <file1> [<file2> ...]
#   scripts/lint_anti_patterns.sh --staged          # scan git-staged hunks
#   scripts/lint_anti_patterns.sh --all             # full repo sweep
#
# Exit codes:
#   0  no violations
#   1  one or more violations found
#   2  invocation error

set -u

VIOLATIONS=0
TELEMETRY="${JVE_LINT_TELEMETRY:-$HOME/.cache/jve-lint.jsonl}"

emit() {
    local file=$1 line=$2 rule=$3 msg=$4
    local raw
    raw=$(awk -v n="$line" 'NR==n' "$file" 2>/dev/null)
    if echo "$raw" | grep -qE "(--|//)\s*lint-allow:\s*$rule\b"; then
        # Exemption used; count to telemetry so we can spot bad rules.
        if mkdir -p "$(dirname "$TELEMETRY")" 2>/dev/null; then
            printf '{"ts":"%s","file":"%s","line":%d,"rule":"%s","exempted":true}\n' \
                "$(date -u +%FT%TZ)" "$file" "$line" "$rule" >> "$TELEMETRY" 2>/dev/null || true
        fi
        return
    fi
    echo "$file:$line:$rule: $msg"
    VIOLATIONS=$((VIOLATIONS + 1))
    if mkdir -p "$(dirname "$TELEMETRY")" 2>/dev/null; then
        printf '{"ts":"%s","file":"%s","line":%d,"rule":"%s","exempted":false}\n' \
            "$(date -u +%FT%TZ)" "$file" "$line" "$rule" >> "$TELEMETRY" 2>/dev/null || true
    fi
}

skip_file() {
    local f=$1
    case "$f" in
        */tests/*|*/test_*) return 0 ;;
        */build/*|*/.git/*|*/graphify-out/*|*/specs/*) return 0 ;;
        */memory/*|*/.claude/*) return 0 ;;
        *.md|*.json|*.toml|*.txt|*.yml|*.yaml) return 0 ;;
        */schema.sql) return 0 ;;
    esac
    return 1
}

lint_lua() {
    local f=$1

    # Skip Lua comment lines (start with -- after optional whitespace) — docstrings
    # legitimately quote the anti-pattern they describe (e.g., dialog_prefs.lua).
    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R001 \
            "json.decode(...) or <default> silently masks parse failures; assert or pcall+assert instead"
    done < <(grep -nE 'json\.decode\([^)]+\)\s*or\b' "$f" 2>/dev/null | grep -vE ':\s*--')

    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R002 \
            "self-admitting comment (Claude-tell pattern) — fold to memory/todo_*.md or fix in this commit"
    done < <(grep -nE -- '--.*\b(for now|hopefully|kludge|simplification|in production we|XXX|HACK|FIXME)\b' "$f" 2>/dev/null | grep -vE 'lint-allow')

    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R003 \
            "os.getenv(\"HOME\") or \"\" silently produces invalid paths; assert HOME or use core.dialog_prefs.path_for()"
    done < <(grep -nE 'os\.getenv\(\s*"HOME"\s*\)\s*or\s*""' "$f" 2>/dev/null)

    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R004 \
            "silent type-check return hides contract violations; assert instead, or annotate with lint-allow + reason"
    done < <(grep -nE 'if\s+type\([^)]+\)\s*~=\s*"[a-z]+"\s*then\s+return\s+end' "$f" 2>/dev/null)

    # R009: module-level (column-0) Signals.connect to a signal OTHER than
    # `project_changed` needs an explicit "intentional process-lifetime"
    # comment block above it, OR `lint-allow: R009 reason` on the connect
    # line. Without that, the next audit agent will re-flag it as a leak
    # (pass 15c FP shape). `project_changed` is skipped because CLAUDE.md
    # documents it as the canonical process-lifetime signal.
    # Whole-file immunization: a top-of-file `MODULE-LEVEL SIGNAL CONNECTS`
    # banner skips the rule for the entire file.
    if ! grep -qE 'MODULE-LEVEL SIGNAL CONNECTS|NOT A LEAK' "$f" 2>/dev/null; then
        while IFS=: read -r ln _; do
            [ -z "$ln" ] && continue
            local connect_line
            connect_line=$(awk -v n="$ln" 'NR==n' "$f" 2>/dev/null)
            # Skip project_changed (documented intentional pattern).
            if echo "$connect_line" | grep -qE 'Signals\.connect\(\s*"project_changed"'; then
                continue
            fi
            local start=$((ln - 10))
            [ "$start" -lt 1 ] && start=1
            local above
            above=$(sed -n "${start},$((ln - 1))p" "$f" 2>/dev/null)
            if echo "$above" | grep -qE 'MODULE-LEVEL|NOT A LEAK|intentional process-lifetime|lint-allow: R009'; then
                continue
            fi
            emit "$f" "$ln" R009 \
                "module-level Signals.connect (non-project_changed) without an immunization comment — future audits will mis-flag as leak; add MODULE-LEVEL block or lint-allow: R009 reason"
        done < <(grep -nE '^Signals\.connect\(' "$f" 2>/dev/null)
    fi

    # R010: `or 0` / `or ""` directly on schema accessor chains
    # (clip.X, track.X, sequence.X, media.X). These columns are mostly
    # NOT NULL; the fallback masks a contract violation. False-positive
    # rate handled by per-line lint-allow with reason.
    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R010 \
            "or 0/or \"\" on schema accessor (clip/track/sequence/media.X) — most columns are NOT NULL; assert or annotate lint-allow: R010 reason"
    done < <(grep -nE '\b(clip|track|sequence|media)\.[a-z_]+\s+or\s+(0|""|\{\})' "$f" 2>/dev/null \
        | grep -vE ':\s*--')

    # R011: sqlite prepare/finalize parity. Pass 17d found 2 real leaks in
    # snapshot_manager.lua where `db:prepare(...)` returned without a paired
    # `:finalize()` on every exit path. File-level count check catches the
    # gross mismatch; per-prepare control-flow analysis is out of shell scope.
    # Skip files where prepares legitimately escape (e.g. cached statement maps);
    # those must use `-- lint-allow: R011 reason` on the prepare line.
    local preps fins
    preps=$(grep -cE '\bdb:prepare\b' "$f" 2>/dev/null)
    fins=$(grep -cE ':finalize\(\)' "$f" 2>/dev/null)
    [ -z "$preps" ] && preps=0
    [ -z "$fins" ] && fins=0
    if [ "$preps" -gt 0 ] && [ "$fins" -lt "$preps" ]; then
        local first
        first=$(grep -nE '\bdb:prepare\b' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$first" ]; then
            local first_line
            first_line=$(awk -v n="$first" 'NR==n' "$f" 2>/dev/null)
            if ! echo "$first_line" | grep -qE 'lint-allow:\s*R011'; then
                emit "$f" "$first" R011 \
                    "file has $preps db:prepare but only $fins :finalize() — leaks statements on at least one exit path; pair every prepare with finalize on every return/error path"
            fi
        fi
    fi

    # R012: prepare → next without exec. lsqlite3 requires
    # `stmt:exec()` between bind and the first `stmt:next()`; without
    # it `next()` is false from the start and the iterator silently
    # returns zero rows (2026-06-03 "0 JVE clip(s)" bug in
    # discovery.lua [née connect_to_resolve_project] + payload_builder). Safe alternative:
    # `database.select_rows(conn, sql, params, row_mapper)` which
    # encapsulates the full prepare→bind→exec→iter→finalize cycle.
    # Per-prepare opt-out: `-- lint-allow: R012 reason` on the
    # prepare line. Multi-line scan in python3 because prepare and
    # next are usually on different lines.
    if command -v python3 >/dev/null 2>&1; then
        local r012_out
        r012_out=$(python3 - "$f" <<'PY' 2>/dev/null
import re, sys
path = sys.argv[1]
try:
    src = open(path).read()
except Exception:
    sys.exit(0)
lines = src.splitlines()
for m in re.finditer(r':prepare\b', src):
    start = m.start()
    tail = src[start:start+2000]
    fin_idx = tail.find(':finalize(')
    block = tail[:fin_idx] if fin_idx > 0 else tail[:1200]
    if (':next()' in block or ':next ' in block) and ':exec()' not in block:
        line_no = src[:start].count('\n') + 1
        line_text = lines[line_no - 1] if line_no - 1 < len(lines) else ''
        if re.search(r'lint-allow:\s*R012', line_text):
            continue
        print(f"{line_no}")
PY
        )
        if [ -n "$r012_out" ]; then
            while IFS= read -r ln; do
                [ -z "$ln" ] && continue
                emit "$f" "$ln" R012 \
                    "prepare → next() without exec(); use database.select_rows(...) or call stmt:exec() before stmt:next() (annotate lint-allow: R012 with reason if intentional)"
            done <<< "$r012_out"
        fi
    fi
}

lint_cpp() {
    local f=$1

    # Flag the unsafe pattern `static_cast<T*>(... lua_to_widget(...) ...)` where T
    # is a non-QWidget class — pass-11 / pass-15a shape. Skip lines that wrap the
    # static_cast in qobject_cast (e.g. layout_bindings.cpp:250's
    # `qobject_cast<QLayout*>(static_cast<QObject*>(static_cast<QWidget*>(lua_to_widget...)))`
    # — the qobject_cast IS the runtime type check).
    # Flag unchecked downcasts on widget userdata. Skip:
    #   • lines that wrap in qobject_cast (the runtime type check)
    #   • static_cast<QWidget*>(lua_to_widget(...))   — initial QWidget* cast IS the idiom
    #   • static_cast<QObject*>(lua_to_widget(...))   — safe upcast (QWidget : QObject)
    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R005 \
            "unchecked downcast on widget userdata; use qobject_cast<T*>(static_cast<QObject*>(...)) for runtime type check"
    done < <(grep -nE 'static_cast<[A-Z][A-Za-z0-9_]+\*>\s*\(\s*(static_cast<QWidget\*>\s*\(\s*)?lua_to_widget' "$f" 2>/dev/null \
        | grep -vE 'qobject_cast' \
        | grep -vE 'static_cast<QWidget\*>\s*\(\s*lua_to_widget' \
        | grep -vE 'static_cast<QObject\*>\s*\(\s*lua_to_widget')

    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R006 \
            "raw delete of a QObject-derived widget; prefer ->deleteLater() so in-flight signal handlers complete safely"
    done < <(grep -nE 'delete\s+(shortcut|action|widget|menu|button|label|surface|scrollarea|item|btn)\s*;' "$f" 2>/dev/null)

    local refs unrefs
    refs=$(grep -cE '\bluaL_ref\b' "$f" 2>/dev/null)
    unrefs=$(grep -cE '\bluaL_unref\b' "$f" 2>/dev/null)
    [ -z "$refs" ] && refs=0
    [ -z "$unrefs" ] && unrefs=0
    if [ "$refs" -gt 0 ] && [ "$unrefs" -eq 0 ]; then
        local first
        first=$(grep -nE '\bluaL_ref\b' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$first" ]; then
            emit "$f" "$first" R007 \
                "file contains luaL_ref but no luaL_unref; lifetime leak unless ref is owned/freed elsewhere — annotate per-line if intentional"
        fi
    fi

    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        emit "$f" "$ln" R008 \
            "self-admitting comment (Claude-tell pattern) — fold to memory/todo_*.md or fix in this commit"
    done < <(grep -nE '//.*\b(for now|hopefully|kludge|simplification|in production we|XXX|HACK|FIXME)\b' "$f" 2>/dev/null | grep -vE 'lint-allow')
}

lint_file() {
    local f=$1
    [ ! -f "$f" ] && return
    skip_file "$f" && return
    case "$f" in
        *.lua)  lint_lua "$f" ;;
        *.cpp|*.h|*.hpp|*.mm) lint_cpp "$f" ;;
        *) return ;;
    esac
}

main() {
    if [ $# -eq 0 ]; then
        echo "usage: $0 <file>... | --staged | --all" >&2
        exit 2
    fi

    local files=()
    case "$1" in
        --staged)
            while IFS= read -r line; do files+=("$line"); done \
                < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
            ;;
        --all)
            while IFS= read -r line; do files+=("$line"); done \
                < <(find src -type f \( -name '*.lua' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.mm' \) 2>/dev/null)
            ;;
        *)
            files=("$@")
            ;;
    esac

    for f in "${files[@]}"; do
        lint_file "$f"
    done

    if [ "$VIOLATIONS" -gt 0 ]; then
        echo "" >&2
        echo "$VIOLATIONS violation(s). See scripts/lint_anti_patterns.md for rule descriptions." >&2
        echo "Suppress a specific line: -- lint-allow: <rule_id> <reason>  (Lua)" >&2
        echo "                          // lint-allow: <rule_id> <reason>  (C++)" >&2
        exit 1
    fi
    exit 0
}

main "$@"
