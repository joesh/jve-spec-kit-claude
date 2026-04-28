#!/usr/bin/env luajit
--- Regression: every TC display path formats the absolute frame at the
--- sequence's frame rate, with NO additional offset. Under V13, all
--- timeline positions (clips, marks, playhead, sequence start) are stored
--- in absolute timecode space — so the displayed TC is just the formatted
--- frame; start_timecode_frame is metadata about WHERE the sequence sits
--- in absolute TC space, not math added at display time.
---
--- Bug previously seen: formatters added start_timecode_frame at display
--- time, doubling the offset (frame 89750 displayed as 01:59:40:00 when
--- the sequence start was 00:59:50:00 = 89750).

require("test_env")

local frame_utils = require("core.frame_utils")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
    end
end

print("=== test_timecode_display_applies_start_tc ===\n")

local seq_25fps = {
    frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    start_timecode_frame = 89750,  -- 00:59:50:00
}

-- ----- Contract: format_timecode is the only TC formatter; no offset added -----
print("Contract: frame_utils.format_timecode(absolute_frame, frame_rate)")

check("frame 89750 (sequence start, absolute) → 00:59:50:00",
    frame_utils.format_timecode(89750, seq_25fps.frame_rate),
    "00:59:50:00")

check("frame 89775 (start + 1 second) → 00:59:51:00",
    frame_utils.format_timecode(89775, seq_25fps.frame_rate),
    "00:59:51:00")

-- The first offline clip in anamnesis-gold-timeline lives at absolute
-- frame 92265 (= 1h 1m 30s 15f @ 25 fps).
check("frame 92265 (first offline clip, absolute) → 01:01:30:15",
    frame_utils.format_timecode(92265, seq_25fps.frame_rate),
    "01:01:30:15")

-- ----- Removed alias: format_sequence_timecode must not exist -----
print("Removed: format_sequence_timecode (alias deleted)")
check("format_sequence_timecode is nil", frame_utils.format_sequence_timecode, nil)

-- ----- The dropped tc_start opt: format_timecode ignores it (and never
-- accepted it after the V13 sweep). The opts table now only carries
-- drop_frame and separator.
local with_opts = frame_utils.format_timecode(92265, seq_25fps.frame_rate,
    { drop_frame = false, separator = ":" })
check("opts {drop_frame, separator} still respected → 01:01:30:15",
    with_opts, "01:01:30:15")

-- ----- Boundary: zero start_tc still works (most masters carry tc_origin=0) -----
local seq_no_offset = {
    frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    start_timecode_frame = 0,
}
check("zero start_tc, frame 25 → 00:00:01:00",
    frame_utils.format_timecode(25, seq_no_offset.frame_rate),
    "00:00:01:00")

-- ----- Boundary: 23.976 fps, integer math (NDF) -----
-- 86400 frames @ 24fps integer math = 1 hour = 01:00:00:00.
local seq_23976 = {
    frame_rate = { fps_numerator = 24000, fps_denominator = 1001 },
    start_timecode_frame = 86400,
}
check("23.976 fps, frame 86400 (= 01:00:00:00 NDF math) → 01:00:00:00",
    frame_utils.format_timecode(86400, seq_23976.frame_rate),
    "01:00:00:00")

if fail > 0 then
    print(string.format("\n--- %d passed, %d FAILED ---", pass, fail))
    os.exit(1)
end
print(string.format("\n✅ %d assertions passed", pass))
