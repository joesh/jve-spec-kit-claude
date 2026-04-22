#!/usr/bin/env luajit
-- Unit test T010: timecode parse/format at the Inspector field boundary (FR-010, FR-015).
-- Domain-derived expected values: timecode math at given rates. NOT read from frame_utils source.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local field_widget = require("ui.inspector.field_widget")
local ft = require("ui.metadata_schemas").FIELD_TYPES

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want))) end
end

print("=== Inspector: timecode parse/format unit test ===\n")

local rate_24    = { fps_numerator = 24,    fps_denominator = 1    }
local rate_2997  = { fps_numerator = 30000, fps_denominator = 1001 }

-- 24 fps round-trip.
-- 00:00:04:12 at 24 fps is 4 seconds + 12 frames = 96 + 12 = 108 frames.
do
    local v, err = field_widget._parse_text(ft.TIMECODE, "00:00:04:12", function() return rate_24 end)
    check("parse 00:00:04:12 @24 → 108", v, 108)
    check("parse 00:00:04:12 @24 no error", err, nil)

    local text = field_widget._format_value(ft.TIMECODE, 108, function() return rate_24 end)
    check("format 108 @24 → 00:00:04:12", text, "00:00:04:12")
end

-- 1 hour at 24 fps = 86400 frames.
do
    local v = field_widget._parse_text(ft.TIMECODE, "01:00:00:00", function() return rate_24 end)
    check("parse 01:00:00:00 @24 → 86400", v, 86400)
end

-- Invalid text returns (nil, err).
do
    local v, err = field_widget._parse_text(ft.TIMECODE, "not timecode", function() return rate_24 end)
    check("parse garbage → v=nil", v, nil)
    check("parse garbage → err not nil", err ~= nil, true)
end

-- Empty string returns (nil, nil) — caller decides.
do
    local v, err = field_widget._parse_text(ft.TIMECODE, "", function() return rate_24 end)
    check("parse empty → v=nil", v, nil)
    check("parse empty → err=nil",  err, nil)
end

-- INTEGER parsing.
do
    check("INTEGER parse '42'", field_widget._parse_text(ft.INTEGER, "42"), 42)
    local v, err = field_widget._parse_text(ft.INTEGER, "3.5")
    check("INTEGER parse '3.5' → nil",  v, nil)
    check("INTEGER parse '3.5' → err",  err ~= nil, true)
    local v2, err2 = field_widget._parse_text(ft.INTEGER, "junk")
    check("INTEGER parse 'junk' → nil", v2, nil)
    check("INTEGER parse 'junk' → err", err2 ~= nil, true)
end

-- DOUBLE parsing.
do
    check("DOUBLE parse '3.14'",  field_widget._parse_text(ft.DOUBLE, "3.14"), 3.14)
    check("DOUBLE parse '-2.5'",  field_widget._parse_text(ft.DOUBLE, "-2.5"), -2.5)
end

-- STRING is identity.
do
    check("STRING parse 'abc'", field_widget._parse_text(ft.STRING, "abc"), "abc")
end

-- 29.97 drop-frame parsing (sanity: the parser accepts it and frame math works).
do
    local v = field_widget._parse_text(ft.TIMECODE, "00:00:01:00", function() return rate_2997 end)
    check("parse 00:00:01:00 @29.97 → ≥29 frames",  v and v >= 29, true)
end

-- Lenient input (timecode_input.parse): right-aligned shorthand and bare
-- digits, matching the behavior of the timeline's timecode entry widget.
-- "10:00" at 24 fps = 10 seconds + 0 frames = 240 frames.
do
    local v = field_widget._parse_text(ft.TIMECODE, "10:00", function() return rate_24 end)
    check("parse '10:00' @24 → 240 (right-aligned: 10s:00f)", v, 240)
end

-- "1:23" right-aligned at 24 fps = 1 second + 23 frames = 47 frames.
do
    local v = field_widget._parse_text(ft.TIMECODE, "1:23", function() return rate_24 end)
    check("parse '1:23' @24 → 47 (right-aligned: 1s:23f)", v, 47)
end

-- Bare digits "1234" right-aligned at 24 fps = 12 seconds + 34 frames. Since
-- 34 >= 24 (rolls over), it's 12s + 34f → frame-only interpretation per
-- timecode_input semantics.
do
    local v = field_widget._parse_text(ft.TIMECODE, "1234", function() return rate_24 end)
    check("parse bare '1234' → non-nil integer",
        type(v) == "number" and v >= 0, true)
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_timecode_parse_format.lua passed")
