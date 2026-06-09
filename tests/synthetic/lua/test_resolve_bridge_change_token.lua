-- test_resolve_bridge_change_token.lua — `core.resolve_bridge.change_token`
-- contract (spec 023 T017, FR-008).
--
-- The change token is the idempotency key for state-changing helper verbs:
--   { project_id, sequence_id, mutation_generation }
-- The helper compares tokens by structural equality; a re-sent request with
-- an already-applied token returns the prior response. (See protocol.lua
-- idempotency_key for how the token is converted to a wire key.)

require("test_env")
local change_token = require("core.resolve_bridge.change_token")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end
local function expect_assert(label, fn, substr)
    local ok, err = pcall(fn)
    if ok then
        fail = fail + 1; print("FAIL (expected assert): " .. label); return
    end
    if substr and not tostring(err):find(substr, 1, true) then
        fail = fail + 1
        print(string.format("FAIL (msg %q lacks %q): %s",
            tostring(err), substr, label))
        return
    end
    pass = pass + 1
end

print("\n=== change_token Tests ===")

local t = change_token.build("p-1", "s-7", 42)
check("built token has project_id", t.project_id == "p-1")
check("built token has sequence_id", t.sequence_id == "s-7")
check("built token has mutation_generation", t.mutation_generation == 42)

-- structural equality
local t2 = change_token.build("p-1", "s-7", 42)
local t3 = change_token.build("p-1", "s-7", 43)  -- bumped
local t4 = change_token.build("p-2", "s-7", 42)  -- different project
check("equal tokens compare equal",
    change_token.equals(t, t2))
check("bumped mutation_generation not equal",
    not change_token.equals(t, t3))
check("different project_id not equal",
    not change_token.equals(t, t4))

-- fail-fast on missing / bad inputs (no defaults — FR ENG 2.13)
expect_assert("missing project_id rejected", function()
    change_token.build(nil, "s-7", 42)
end, "project_id")
expect_assert("non-integer mutation_generation rejected", function()
    change_token.build("p-1", "s-7", "forty-two")
end, "mutation_generation")
expect_assert("negative mutation_generation rejected", function()
    change_token.build("p-1", "s-7", -1)
end, "mutation_generation")
expect_assert("empty sequence_id rejected", function()
    change_token.build("p-1", "", 42)
end, "sequence_id")

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_resolve_bridge_change_token.lua: failures present")
print("✅ test_resolve_bridge_change_token.lua passed")
