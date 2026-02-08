--- Test: browser_state.normalize_timeline handles Rational duration
--
-- Bug: When selecting a sequence in the browser, normalize_timeline fails
-- because sequence.duration is a Rational, not a number.

require("test_env")

print("Testing browser_state handles Rational duration...")

-- Read the source to verify the fix
local file = io.open("../src/lua/ui/project_browser/browser_state.lua", "r")
assert(file, "Could not open browser_state.lua")
local content = file:read("*all")
file:close()

-- Find the normalize_timeline function
local func_start = content:find("local function normalize_timeline")
assert(func_start, "Could not find normalize_timeline function")

-- The fix must handle both Rational (.frames) and plain numbers
-- Check for the type check pattern (plain text search with 4th arg = true)
local has_type_check = content:find('type(sequence.duration) == "table"', func_start, true)
local has_frames_access = content:find("sequence.duration.frames", func_start, true)

if not has_type_check or not has_frames_access then
    print("  EXPECTED FAILURE: normalize_timeline doesn't handle Rational duration")
    print("")
    print("  FIX REQUIRED: Check type before accessing .frames")
    error("TEST FAILED: normalize_timeline must handle Rational duration")
end

print("✅ test_browser_state_rational_duration.lua passed")
