---
description: No Silent Failures - enforce strict error handling, TDD, and comprehensive test coverage
---

# No Silent Failures (NSF) Mode

You are now in strict NSF mode. Apply these rules to ALL code you write or review:

## Core Principles

1. **NO SILENT FAILURES** - Every error must be surfaced immediately
2. **NO FALLBACKS** - Never invent default values when data is missing
3. **NO IGNORED RETURNS** - Check and handle every error return
4. **TDD REQUIRED** - Write failing test FIRST, then implement
5. **ALL PATHS TESTED** - Cover error paths, edge cases, not just happy path

## Error Handling Rules

- Functions that can fail MUST return error info or assert
- Callers MUST check return values - never discard
- Use `assert()` for invariant violations with actionable messages
- Include context in errors: function name, relevant IDs, bad values
- NO try/catch that swallows errors silently
- NO `or default_value` patterns that hide missing data

## TDD Workflow (Mandatory)

1. **Write test first** - Test must fail initially (red)
2. **Show the failure** - Run test, confirm it fails as expected
3. **Implement minimally** - Write just enough code to pass
4. **Run test again** - Confirm green
5. **Refactor if needed** - Keep tests passing

## Test Coverage Requirements

Tests MUST cover:
- ✅ Happy path (normal operation)
- ✅ Error paths (what happens when things fail?)
- ✅ Boundary conditions (empty, zero, max, nil)
- ✅ Invalid inputs (wrong types, out of range)
- ✅ State transitions (before/after, edge states)

## Code Review Checklist

Before completing any code task, verify:

```
[ ] No functions silently return nil/false without caller checking
[ ] No default values substituted for missing required data
[ ] All assert messages include function name + context
[ ] Failing test written and shown BEFORE implementation
[ ] Tests exist for error conditions, not just success
[ ] No TODO/FIXME for error handling deferred
```

## Applies To

$ARGUMENTS

If no arguments provided, apply to current task context.

Execute the task with these constraints strictly enforced.
