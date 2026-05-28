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

emit() {
    local file=$1 line=$2 rule=$3 msg=$4
    local raw
    raw=$(awk -v n="$line" 'NR==n' "$file" 2>/dev/null)
    if echo "$raw" | grep -qE "(--|//)\s*lint-allow:\s*$rule\b"; then
        return
    fi
    echo "$file:$line:$rule: $msg"
    VIOLATIONS=$((VIOLATIONS + 1))
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
