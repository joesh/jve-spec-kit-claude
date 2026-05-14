#!/bin/bash
# PostToolUse hook for Edit/Write/MultiEdit — injects an audit reminder so
# Claude self-checks against ENGINEERING.md / CLAUDE.md without Joe having
# to ask after every change.

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"AUDIT + NSF REMINDER (do not skip — Joe should not have to ask): Before claiming this change done, audit against (1) ENGINEERING.md rules: 1.14 fail-fast asserts, 2.5 algorithm-style functions, 2.13 no fallbacks/defaults, 2.16 no shortcuts, 2.20/2.21 spec-driven, 2.32 no silent failures, 3.14 MVC; (2) CLAUDE.md coding style; (3) NSF principles: no silent failures (every error path asserts or surfaces), TDD (a failing test existed before this fix), comprehensive happy + error path coverage. Report rule → finding → fix for any violations proactively."}}
JSON
