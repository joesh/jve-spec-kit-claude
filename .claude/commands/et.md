---
description: Ensure Tests - create/update tests for complete happy and error path coverage
---

# Ensure Tests (/et)

Ensure comprehensive test coverage for specified files or recent changes. Creates missing tests for both happy paths AND error paths.

## Arguments

$ARGUMENTS

If no arguments: analyze files from `git diff --name-only HEAD~3` and uncommitted changes.

## Process

### 1. Identify Target Files

```bash
# Get files to analyze
git diff --name-only HEAD~3
git status --short
```

Filter to `src/lua/**/*.lua` files. For each source file, find or create corresponding test file:
- `src/lua/core/foo.lua` → `tests/test_foo.lua`
- `src/lua/ui/bar.lua` → `tests/test_bar.lua`
- `src/lua/core/commands/baz.lua` → `tests/test_baz.lua`

### 2. Analyze Each File

For each public function, check for tests covering:

**Happy Paths (Required):**
- [ ] Normal successful operation with valid inputs
- [ ] Multiple valid input variations (different types that should work)
- [ ] Boundary values that should succeed (0, 1, max-1)

**Error Paths (Required - NSF Policy):**
- [ ] Each required parameter as `nil` → assert fires
- [ ] Wrong type for each parameter → assert fires
- [ ] Invalid values (negative when positive required, empty when non-empty required)
- [ ] Missing required fields in table parameters

**Edge Cases:**
- [ ] Empty collections (empty table, no clips, no tracks)
- [ ] Single item collections
- [ ] Idempotency where relevant

### 3. Test Pattern Templates

**Happy path test:**
```lua
print("Test: <function> with valid input")
local result = module.function(valid_input)
assert(result.expected_field == expected_value,
    string.format("<function>: expected %s, got %s", expected_value, result.expected_field))
print("  ✓ <function> returns correct result")
```

**Error path test (assert expected):**
```lua
print("Test: <function> with nil <param> asserts")
local ok, err = pcall(function()
    module.function(nil)
end)
assert(not ok, "<function>(nil) should assert")
assert(err:match("<function>") and err:match("<param>"),
    "<function> error should identify function and bad param, got: " .. tostring(err))
print("  ✓ <function> validates <param>")
```

**Error path test (missing required field):**
```lua
print("Test: <function> with missing required field asserts")
local ok, err = pcall(function()
    module.function({ other_field = 1 })  -- missing required_field
end)
assert(not ok, "<function> should assert on missing required_field")
assert(err:match("required_field"), "Error should mention missing field")
print("  ✓ <function> validates required_field presence")
```

### 4. Update Existing Tests

When existing tests use outdated patterns (e.g., Rational when integers now expected):

1. Read existing test to understand intent
2. Update to match current API
3. Preserve test coverage while fixing assertions

Example transformation:
```lua
-- BEFORE (Rational-based)
assert(clip.timeline_start.frames == 100, "expected 100 frames")

-- AFTER (integer-based)
assert(clip.timeline_start == 100, "expected timeline_start 100, got " .. tostring(clip.timeline_start))
```

### 5. Run Tests After Changes

```bash
cd tests && luajit test_harness.lua test_<name>.lua
```

Or for all tests:
```bash
./tests/run_lua_tests_all.sh
```

### 6. Output Summary

```
## Ensure Tests: <file>

### Coverage Before:
- function_a: ✅ happy + error paths (5 tests)
- function_b: ⚠️ happy only, missing error paths
- function_c: ❌ no tests

### Tests Created/Updated:
1. test_function_b_nil_param.lua:45 - NEW (error path)
2. test_function_b_invalid_type.lua:52 - NEW (error path)
3. test_function_c.lua - NEW FILE (happy + error)

### Coverage After:
- function_a: ✅ complete (5 tests)
- function_b: ✅ complete (3 tests added)
- function_c: ✅ complete (4 tests added)

### Test Run:
✅ All X tests pass
```

## Key Rules

1. **ALWAYS test error paths** - Every assert in production code needs a test proving it fires
2. **Error messages must be actionable** - Test that error includes function name + context
3. **No silent failures in tests** - Tests must assert, not just print
4. **Update, don't duplicate** - Enhance existing test files rather than creating parallel ones
5. **Run tests** - Verify tests pass before declaring complete

## Now Execute

Analyze the target files and ensure complete test coverage for both happy and error paths.
