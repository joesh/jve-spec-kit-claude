# No Silent Failures (NSF) Mode

You are now in strict NSF mode. Apply these rules to ALL code you write or review:

## Core Principles

1. **NO SILENT FAILURES** - Every error must be surfaced immediately
2. **NO FALLBACKS** - Never invent default values when data is missing
3. **NO IGNORED RETURNS** - Check and handle every error return
4. **TDD REQUIRED** - Write failing test FIRST, then implement
5. **ALL PATHS TESTED** - Cover error paths, edge cases, not just happy path

## TWO HALVES OF NSF

NSF has two halves. Both are mandatory. Auditing only half is a failure.

### Half 1: Input Validation (prerequisites)
- Are all required inputs non-nil/non-null?
- Are all parameters in valid range?
- Are all required fields present?
- Is the caller meeting the function's preconditions?

### Half 2: Output Invariants (postconditions)
- Does the function produce a sane result?
- Is the output within expected bounds?
- Did a multi-step pipeline actually produce output (not silently drop data)?
- Can a computed value teleport to an impossible state?

**Example failures from missing Half 2:**
- Audio pump pushes source data to SSE but SSE produces 0 frames → silent (no assert)
- Position advances from frame 0 to frame 124365 in one tick → silent (clamped to boundary, stops playback, no assert)
- Clock returns time_us corresponding to the end of a 90-minute sequence on the first tick → silent

## Error Handling Rules

- Functions that can fail MUST return error info or assert
- Callers MUST check return values - never discard
- Use `assert()` for invariant violations with actionable messages
- Include context in errors: function name, relevant IDs, bad values
- NO try/catch that swallows errors silently
- NO `or default_value` patterns that hide missing data
- Functions that transform data MUST validate output is sane (not just that input was valid)

## TDD Workflow (Mandatory)

1. **Write test first** - Test must fail initially (red)
2. **Show the failure** - Run test, confirm it fails as expected
3. **Implement minimally** - Write just enough code to pass
4. **Run test again** - Confirm green
5. **Refactor if needed** - Keep tests passing

## Test Coverage Requirements

Tests MUST cover:
- Happy path (normal operation)
- Error paths (what happens when things fail?)
- Boundary conditions (empty, zero, max, nil)
- Invalid inputs (wrong types, out of range)
- State transitions (before/after, edge states)

## Code Review Checklist

Before completing any code task, verify:

```
INPUT VALIDATION (Half 1):
[ ] No functions silently return nil/false without caller checking
[ ] No default values substituted for missing required data
[ ] All assert messages include function name + context
[ ] No TODO/FIXME for error handling deferred

OUTPUT INVARIANTS (Half 2):
[ ] Pipeline outputs are checked (did render produce frames? did write succeed?)
[ ] Computed values are bounded (can't teleport, can't exceed physical limits)
[ ] Multi-step chains validate end-to-end (source pushed → frames rendered → output written)
[ ] Clamp-and-continue patterns have asserts BEFORE the clamp (clamp hides the bug)

TESTING:
[ ] Failing test written and shown BEFORE implementation
[ ] Tests exist for error conditions, not just success
[ ] Black-box tests check observable output, not internal calls
```

## Coding Style (ENGINEERING.md)

Also audit for violations of the project's coding standards:

### Structure
- **2.5 Functions Read Like Algorithms** - Main functions tell WHAT happens, helpers handle HOW. Never mix high-level logic with low-level detail in the same function.
- **2.6 Short Functions** - One responsibility per function. If it doesn't fit on one screen, split it.
- **2.18 FFI vs Business Logic** - FFI functions are pure C++ mappings (parameter validation only). Business logic calls FFI, never C++ directly. Never put application logic in FFI functions.

### Safety
- **2.13 No Fallbacks** - Never `or default_value`. Fail explicitly.
- **2.15 No Backward Compatibility** - No shims, migrations, or legacy paths unless Joe explicitly asks.
- **2.17 No Stubs** - No dummy return values. Implement fully or fix the architecture.
- **2.21 Statically-Verifiable** - Prefer compile-time/signature-level enforcement over runtime checks.
- **2.29 sequence_id on Timeline Commands** - All commands modifying a sequence MUST include `sequence_id`.

### Process
- **2.4 Clean Builds** - Zero warnings, zero errors before moving on.
- **2.20 Regression Tests First** - Failing test BEFORE fix. Prove it fails.
- **2.31 Never Change Test Expectations** - Existing assertions are canon. Fix impl, not tests.
- **2.32 New Codepaths Require Tests** - Every new branch/handler needs tests (including error paths).

### Code Review Checklist Addition

```
CODING STYLE:
[ ] Functions are short, single-responsibility (2.5, 2.6)
[ ] No high-level + low-level logic mixed in same function (2.5)
[ ] FFI functions contain no business logic (2.18)
[ ] No stubs or dummy implementations (2.17)
[ ] No backward-compat shims (2.15)
[ ] No fallback values hiding errors (2.13)
[ ] Timeline commands include sequence_id (2.29)
[ ] Build is clean (0 warnings, 0 errors) (2.4)
```
