# Verify Tests (/vt)

Verify test coverage for recently modified code and enhance/create tests where coverage is insufficient.

## Process

### 1. Identify Changed Code

First, identify what code has changed:
- Check `git diff --name-only HEAD~5` for recently modified files
- Check `git status` for uncommitted changes
- Focus on `.lua` files in `src/` and `.cpp` files

### 2. For Each Changed File, Audit Test Coverage

For each modified source file, find its corresponding test file(s):
- `src/lua/ui/foo.lua` → `tests/test_foo.lua`
- `src/lua/core/foo.lua` → `tests/test_foo.lua`
- `src/foo.cpp` → `tests/unit/test_foo.cpp`

### 3. Coverage Checklist (NSF-Compliant)

For each public function in the changed code, verify tests exist for:

**Required Coverage:**
- [ ] **Happy path** - Normal successful operation
- [ ] **Error paths** - What happens when things fail?
- [ ] **Nil/missing inputs** - Each required parameter as nil
- [ ] **Invalid type inputs** - Wrong types for parameters
- [ ] **Boundary conditions** - Zero, empty, max values
- [ ] **State preconditions** - Calling before init, after shutdown, etc.
- [ ] **Idempotency** - Double-calls where relevant (start/start, stop/stop)

**For functions that assert:**
- [ ] Test that assert fires with expected message pattern
- [ ] Use `pcall` to catch and verify the error

**For functions with multiple code paths:**
- [ ] Each conditional branch exercised
- [ ] Each early return condition tested

### 4. Generate Missing Tests

For any gaps found, write tests following this pattern:

```lua
print("\nTest X.Y: <description>")
-- Setup
local <setup_code>

-- Execute
local ok, err = pcall(function()
    <code_under_test>
end)

-- Verify
assert(<condition>, "<failure message with context>")
print("  ✓ <what passed>")
```

For error path tests:
```lua
print("\nTest X.Y: <function> with <invalid_input> asserts")
local ok, err = pcall(function()
    module.function(invalid_input)
end)
assert(not ok, "<function>(invalid) should assert")
assert(err:match("<expected_pattern>"), "Error should mention <thing>, got: " .. tostring(err))
print("  ✓ <function> validates <parameter>")
```

### 5. Output Format

Report findings as:

```
## Test Coverage Audit: <filename>

### Functions Analyzed:
- function_a: ✅ Full coverage (5 tests)
- function_b: ⚠️ Missing error path tests
- function_c: ❌ No tests found

### Tests Added/Enhanced:
1. test_function_b_nil_input - NEW
2. test_function_b_invalid_type - NEW
3. test_function_c_happy_path - NEW
4. test_function_c_boundary - NEW

### Coverage After:
- function_a: ✅ Full coverage (5 tests)
- function_b: ✅ Full coverage (3 tests)
- function_c: ✅ Full coverage (4 tests)
```

## Execution

1. Run the audit on changed files
2. For each gap, write the test FIRST (show it fails or would fail)
3. If implementation needs fixing to pass, note it but don't change impl
4. Run all tests to verify no regressions: `make -j4`

## Special Cases

### Lua modules without Qt context
Some tests need `qt_constants`. Structure tests so standalone tests run first, Qt-dependent tests are guarded:
```lua
if not has_qt then
    print("Test N: SKIPPED (requires qt_constants)")
end
```

### C++ tests
Use Qt Test framework patterns:
```cpp
void test_function_validates_input() {
    // Document: invalid input causes assert (NSF policy)
    // Cannot test without death tests, but verify valid inputs work
    QVERIFY(true);
}
```

## Now Execute

Analyze the recently changed files and verify/enhance their test coverage following this process.
