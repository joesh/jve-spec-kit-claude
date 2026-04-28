#!/usr/bin/env luajit
--- Round-trip: typing a TC into the timeline_panel playhead-counter widget
-- stores the absolute frame whose displayed TC matches the input.
--
-- Under V13 the playhead lives in absolute timecode space — the same space
-- as clip placements and sequence start_timecode_frame. So when the user
-- pastes "01:01:30:15" into the counter:
--   1. Parse "01:01:30:15" at the sequence rate → absolute frame 92265
--   2. Store 92265 directly as sequence.playhead_position
--   3. The ruler/counter then displays 92265 / fps = 01:01:30:15
--
-- Relative input ("+10", "-25") is a delta off the current absolute
-- playhead — already in the correct space, no extra math.
--
-- This test exercises the parse logic the timeline_panel widget uses.
-- The Qt-bound widget layer is not in scope here.
require("test_env")

local timecode_input = require("core.timecode_input")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
    end
end

print("=== test_timecode_playhead_counter_round_trip ===\n")

local rate = { fps_numerator = 25, fps_denominator = 1 }

-- Mirrors timeline_panel.parse_typed_timecode_to_raw_frame: parse at the
-- sequence rate (with current playhead as base for relative inputs);
-- absolute input lands in absolute space; relative input is a delta off
-- the current position. No offset subtracted under absolute convention.
local function parse_typed_tc(text, current_frame)
    local parsed = timecode_input.parse(text, rate, { base_time = current_frame })
    if not parsed then return nil end
    return parsed.frames
end

-- Absolute paste: typed TC IS the absolute frame number.
check("paste '01:01:30:15' → absolute 92265 (offline clip)",
    parse_typed_tc("01:01:30:15", 0), 92265)
check("paste '00:59:50:00' (start of sequence) → absolute 89750",
    parse_typed_tc("00:59:50:00", 0), 89750)
check("paste '01:00:00:00' → absolute 90000",
    parse_typed_tc("01:00:00:00", 0), 90000)

-- Relative paste: input is delta off current absolute frame.
check("relative '+10' from current=92265 → 92275",
    parse_typed_tc("+10", 92265), 92275)
check("relative '-25' from current=92265 → 92240",
    parse_typed_tc("-25", 92265), 92240)

-- Round-trip via format_timecode: typed TC == format(parse(typed)).
local frame_utils = require("core.frame_utils")
local typed = "01:01:30:15"
local stored = parse_typed_tc(typed, 0)
local displayed = frame_utils.format_timecode(stored, rate)
check("round-trip: typed == format(parse(typed))", displayed, typed)

if fail > 0 then
    print(string.format("\n--- %d passed, %d FAILED ---", pass, fail))
    os.exit(1)
end
print(string.format("\n✅ %d assertions passed", pass))
