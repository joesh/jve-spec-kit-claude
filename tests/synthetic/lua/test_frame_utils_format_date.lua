--- Test: frame_utils.format_date function
-- Coverage: valid timestamps, nil, zero, edge cases
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local frame_utils = require("core.frame_utils")

-- ============================================================================
-- format_date tests
-- ============================================================================

print("Test: format_date with valid timestamp")
-- Jan 1, 2024 00:00:00 UTC = 1704067200 (approximate, depends on timezone)
-- We'll use a known timestamp and check format pattern
local timestamp = os.time({ year = 2024, month = 1, day = 15, hour = 12, min = 0, sec = 0 })
local formatted = frame_utils.format_date(timestamp)
check("format_date returns string", type(formatted) == "string")
check("format_date contains 2024", formatted:find("2024") ~= nil)
check("format_date contains Jan", formatted:find("Jan") ~= nil)
check("format_date contains 15", formatted:find("15") ~= nil)
print("  ✓ format_date with valid timestamp: " .. formatted)

print("Test: format_date with nil returns empty")
formatted = frame_utils.format_date(nil)
check("format_date(nil) = ''", formatted == "")
print("  ✓ format_date handles nil")

print("Test: format_date with 0 returns empty")
formatted = frame_utils.format_date(0)
check("format_date(0) = ''", formatted == "")
print("  ✓ format_date handles zero")

print("Test: format_date with different months")
local months = {
    { month = 1, abbr = "Jan" },
    { month = 6, abbr = "Jun" },
    { month = 12, abbr = "Dec" },
}
for _, m in ipairs(months) do
    timestamp = os.time({ year = 2023, month = m.month, day = 1, hour = 0, min = 0, sec = 0 })
    formatted = frame_utils.format_date(timestamp)
    check(string.format("month %d shows %s", m.month, m.abbr), formatted:find(m.abbr) ~= nil)
end
print("  ✓ format_date handles various months")

if failed > 0 then
    print(string.format("❌ test_frame_utils_format_date.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_frame_utils_format_date.lua passed (%d assertions)", passed))
