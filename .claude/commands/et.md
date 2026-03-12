---
description: Ensure Tests - create/update tests for complete happy and error path coverage
---

# Ensure Tests (/et)

Ensure comprehensive **black-box** test coverage for specified files or recent changes. Tests must verify **intended behavior** (from specs, requirements, domain knowledge), not mirror implementation details.

## Arguments

$ARGUMENTS

If no arguments: analyze files from `git diff --name-only HEAD~3` and uncommitted changes.

## CRITICAL: Black-Box Testing Mandate

### The Tautology Trap

The #1 failure mode of AI-written tests: Claude reads the code, then writes tests that assert exactly what the code does. This is circular — the test can never catch a bug because it encodes the implementation's assumptions, not the user's intent.

**Tautological test** (BAD):
```lua
-- Claude reads: source_in = math.floor(in_value * speed + 0.5)
-- Claude writes:
local expected = math.floor(447 * 0.7273 + 0.5)  -- copied the formula from source
assert(clip.source_in == expected)
-- This CANNOT catch the bug: speed should be 0.88, not 0.7273
```

**Black-box test** (GOOD):
```lua
-- Resolve shows source TC 01:14:36:16, media start 01:14:20:22 at 25fps
-- Expected source_in = (01:14:36:16 - 01:14:20:22) in frames = 394
assert(clip.source_in == 394,
    "source_in must match Resolve TC 01:14:36:16 from media start 01:14:20:22")
```

### Where Expected Values Must Come From (priority order)

1. **Spec or requirement** — spec.md, CLAUDE.md, user description, external reference (e.g. screenshot from Resolve, FCP XML ground truth, RFC)
2. **Manual calculation from domain knowledge** — compute from first principles: timecode math, sample rate conversion, coordinate geometry. Show the derivation in a comment.
3. **Ask the user** — when the expected value isn't obvious from spec or calculation, ASK. Do not guess by reading the implementation.

**NEVER**: Run the code, observe the output, paste it into the assertion. That tests "does the code do what the code does?" — always true, always useless.

### Black-Box Checklist

For every test assertion, ask:

- [ ] **Could this test catch a bug?** If the implementation changed to produce a wrong answer, would this test fail? Or would it just track the new (wrong) answer?
- [ ] **Is the expected value derived independently of the code under test?** If you got the expected value by reading the source, it's tautological.
- [ ] **Does the test verify observable behavior?** Inputs → outputs, inputs → side effects (DB state, signals, files), inputs → errors. NOT internal state, call order, intermediate variables.
- [ ] **Would a user or spec author recognize this test?** If you described the test to Joe, would he say "yes, that's what it should do" — or would he have no idea what internal detail you're testing?

## Process

### 1. Identify Target Files

```bash
git diff --name-only HEAD~3
git status --short
```

Filter to `src/lua/**/*.lua` files. For each source file, find or create corresponding test file:
- `src/lua/core/foo.lua` → `tests/test_foo.lua`
- `src/lua/ui/bar.lua` → `tests/test_bar.lua`
- `src/lua/core/commands/baz.lua` → `tests/test_baz.lua`

### 2. Identify Intent (BEFORE reading implementation)

For each function to test, determine **what it should do** from:
- Spec files (`specs/*.md`)
- CLAUDE.md / ENGINEERING.md descriptions
- Function docstrings and module-level comments
- Commit messages that introduced the function
- User's verbal description of the feature
- External references (NLE behavior, format specs, RFCs)

**Write down the expected behavior in plain language before reading the code.**

### 3. Audit Existing Tests for Tautology

For each existing test, check:

**Flag as TAUTOLOGICAL if:**
- Expected value is a formula copied from the source code
- Test asserts on internal/private state that isn't part of the public contract
- Test mocks so aggressively that it only tests the mock wiring
- Expected value could only be known by reading the implementation (not the spec)
- Test name describes an implementation detail, not a user-visible behavior

**Flag as COUPLED (white-box) if:**
- Test calls private/internal helper functions directly (unless that helper IS the public API)
- Test asserts on call order or exact number of internal function invocations
- Test would break from a valid refactor that preserves behavior

Report flagged tests in the output summary with suggested rewrites.

### 4. Analyze Coverage

For each public function, check for tests covering:

**Behavior Tests (Required — black-box):**
- [ ] Given valid input, produces correct output (derived from spec/domain, NOT from code)
- [ ] Side effects are observable: DB records created/modified, signals emitted, state changed
- [ ] Multiple scenarios that exercise different behavior (not just different code paths)
- [ ] Boundary values from the domain (first frame, last frame, zero duration, single-sample)

**Error Tests (Required — NSF Policy):**
- [ ] Each required parameter as `nil` → assert fires
- [ ] Invalid values from the domain (negative duration, overlapping clips, out-of-range TC)
- [ ] Precondition violations (calling play before load, editing during playback)

**Integration Tests (Required for commands and workflows):**
- [ ] Execute command → verify DB state matches expectation
- [ ] Execute command → undo → verify DB returns to prior state
- [ ] Multi-step workflows: import → edit → verify combined result

### 5. Write Missing Tests

**Template: Black-box behavior test**
```lua
-- Expected behavior: <describe what spec/user says should happen>
-- Source of truth: <spec.md section / Resolve screenshot / manual calc>
print("Test: <behavior description in user terms>")

-- Setup: create the scenario
<setup_code>

-- Act: exercise the public API
local result = module.function(input)

-- Assert: verify observable outcomes against independently-derived values
assert(result.field == EXPECTED_FROM_SPEC,
    string.format("<behavior>: expected %s (from spec), got %s",
        EXPECTED_FROM_SPEC, result.field))

-- Verify side effects
local db_row = db:exec("SELECT ... WHERE ...")
assert(db_row.column == EXPECTED, "DB must reflect <behavior>")

print("  ok")
```

**Template: Error path test**
```lua
print("Test: <function> rejects <invalid scenario>")
local ok, err = pcall(function()
    module.function(invalid_input)
end)
assert(not ok, "<function>(<invalid>) must assert")
assert(err:match("<context>"),
    "Error should identify problem, got: " .. tostring(err))
print("  ok")
```

### 6. Run Tests After Changes

```bash
make -j4
```

(`make -j4` runs luacheck + all Lua tests + C++ tests + integration)

### 7. Output Summary

```
## Ensure Tests: <file>

### Tautology Audit:
- test_foo:L45: TAUTOLOGICAL — expected value copies formula from source
  → Rewrite: derive from <spec section>
- test_foo:L82: COUPLED — tests private helper _internal_calc()
  → Rewrite: test through public API instead

### Coverage Before:
- function_a: ✅ black-box tests (3 tests)
- function_b: ⚠️ tautological (asserts mirror implementation)
- function_c: ❌ no tests

### Tests Created/Updated:
1. test_foo.lua:L100 - REWRITTEN (was tautological → now spec-derived)
2. test_foo.lua:L120 - NEW (error path: nil clip_id)
3. test_bar.lua:L45 - NEW (integration: command → DB verify)

### Truth Sources Used:
- function_b expected values: derived from 25fps timecode math
- function_c expected values: Resolve screenshot showing TC 01:14:36:16

### Coverage After:
- function_a: ✅ complete (3 tests)
- function_b: ✅ complete, spec-derived (2 tests rewritten)
- function_c: ✅ complete (4 tests added)

### Test Run:
✅ All X tests pass (make -j4)
```

## Key Rules

1. **BLACK-BOX FIRST** — test observable behavior, not implementation details
2. **INDEPENDENT EXPECTED VALUES** — derive from spec/domain/user, never from reading the code under test
3. **TAUTOLOGY AUDIT** — flag existing tests that encode implementation assumptions instead of spec requirements
4. **ALWAYS test error paths** — every assert in production code needs a test proving it fires
5. **SIDE EFFECTS OVER RETURNS** — for commands, verify DB state and signal emissions, not just return values
6. **NO EXCESSIVE MOCKS** — mocks encode assumptions about internals. Use real DB, real models. Only mock what's truly external (Qt widgets, filesystem)
7. **ASK WHEN UNSURE** — if the expected behavior isn't clear from spec or domain, ask the user. Don't guess by reading the code.
8. **Update, don't duplicate** — enhance existing test files rather than creating parallel ones
9. **Run tests** — `make -j4` before declaring complete

## Now Execute

Analyze the target files. For each: identify intent (from spec/docs, not code), audit existing tests for tautology, then ensure complete black-box coverage for both happy and error paths.
