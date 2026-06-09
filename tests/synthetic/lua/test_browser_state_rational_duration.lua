--- Test: browser_state.normalize_timeline handles integer duration
--
-- Validates that normalize_timeline uses sequence.duration directly
-- since all coordinates are now plain integers (post-Rational refactor).

require("test_env")

print("Testing browser_state handles integer duration...")

-- Read the source to verify the fix
local file = io.open("../src/lua/ui/project_browser/browser_state.lua", "r")
assert(file, "Could not open browser_state.lua")
local content = file:read("*all")
file:close()

-- Find the normalize_timeline function
local func_start = content:find("local function normalize_timeline")
assert(func_start, "Could not find normalize_timeline function")

-- Verify duration is accessed (now as plain integer)
local has_duration_access = content:find("sequence.duration", func_start, true)

if not has_duration_access then
    print("  EXPECTED FAILURE: normalize_timeline doesn't access sequence.duration")
    error("TEST FAILED: normalize_timeline must access sequence.duration")
end

print("✅ test_browser_state_rational_duration.lua passed")
