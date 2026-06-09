require("test_env")

local color_utils = require("ui.color_utils")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

print("\n=== Color Utils Tests (T16) ===")

-- ============================================================
-- dim_hex — valid operations
-- ============================================================
print("\n--- dim_hex valid ---")
do
    -- Full brightness (factor=1) → same color
    check("white at 1.0", color_utils.dim_hex("#ffffff", 1.0) == "#ffffff")
    check("black at 1.0", color_utils.dim_hex("#000000", 1.0) == "#000000")
    check("red at 1.0", color_utils.dim_hex("#ff0000", 1.0) == "#ff0000")

    -- Full dim (factor=0) → black
    check("white at 0.0 → black", color_utils.dim_hex("#ffffff", 0.0) == "#000000")
    check("red at 0.0 → black", color_utils.dim_hex("#ff0000", 0.0) == "#000000")
    check("arbitrary at 0.0 → black", color_utils.dim_hex("#abcdef", 0.0) == "#000000")

    -- Half brightness
    -- #ffffff at 0.5 → 128, 128, 128 (255*0.5=127.5, rounded to 128)
    check("white at 0.5", color_utils.dim_hex("#ffffff", 0.5) == "#808080")

    -- Specific color dimming
    -- #ff8000: r=255, g=128, b=0
    -- At 0.5: r=128, g=64, b=0
    check("#ff8000 at 0.5", color_utils.dim_hex("#ff8000", 0.5) == "#804000")

    -- Rounding: 255 * 0.3 = 76.5 → rounds to 77 = 0x4d
    check("rounding half-up", color_utils.dim_hex("#ff0000", 0.3) == "#4d0000")

    -- Black stays black at any factor
    check("black at 0.5", color_utils.dim_hex("#000000", 0.5) == "#000000")
    check("black at 0.0", color_utils.dim_hex("#000000", 0.0) == "#000000")
end

-- ============================================================
-- dim_hex — lowercase output
-- ============================================================
print("\n--- dim_hex output format ---")
do
    local result = color_utils.dim_hex("#AABBCC", 1.0)
    check("output is lowercase hex", result == "#aabbcc")
    check("output starts with #", result:sub(1, 1) == "#")
    check("output length = 7", #result == 7)
end

-- ============================================================
-- dim_hex — validation errors
-- ============================================================
print("\n--- dim_hex validation ---")
do
    -- Invalid hex color
    expect_error("nil color", function() color_utils.dim_hex(nil, 0.5) end, "expected hex string")
    expect_error("number color", function() color_utils.dim_hex(123, 0.5) end, "expected hex string")
    expect_error("no hash", function() color_utils.dim_hex("ffffff", 0.5) end, "expected '#RRGGBB'")
    expect_error("short hex", function() color_utils.dim_hex("#fff", 0.5) end, "expected '#RRGGBB'")
    expect_error("long hex", function() color_utils.dim_hex("#ffffffff", 0.5) end, "expected '#RRGGBB'")
    expect_error("invalid chars", function() color_utils.dim_hex("#gggggg", 0.5) end, "expected '#RRGGBB'")
    expect_error("empty string", function() color_utils.dim_hex("", 0.5) end, "expected '#RRGGBB'")

    -- Invalid factor
    expect_error("nil factor", function() color_utils.dim_hex("#ffffff", nil) end, "expected numeric")
    expect_error("string factor", function() color_utils.dim_hex("#ffffff", "half") end, "expected numeric")
    expect_error("negative factor", function() color_utils.dim_hex("#ffffff", -0.1) end, "factor must be in")
    expect_error("factor > 1", function() color_utils.dim_hex("#ffffff", 1.1) end, "factor must be in")
end

-- ============================================================
-- dim_hex — boundary factors
-- ============================================================
print("\n--- dim_hex boundary factors ---")
do
    -- Factor exactly 0 and 1 (boundaries)
    check("factor 0 exact", color_utils.dim_hex("#abcdef", 0) == "#000000")
    check("factor 1 exact", color_utils.dim_hex("#abcdef", 1) == "#abcdef")

    -- Very small factor
    -- 255 * 0.01 = 2.55 → rounds to 3
    check("tiny factor", color_utils.dim_hex("#ffffff", 0.01) == "#030303")
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Color Utils: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_color_utils.lua passed")
