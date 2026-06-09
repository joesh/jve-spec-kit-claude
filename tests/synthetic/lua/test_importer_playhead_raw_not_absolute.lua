#!/usr/bin/env luajit
--- Importer must store sequence.playhead_frame in absolute timecode space
--- (matching the rest of V13 — clip placements, marks, sequence start TC,
--- and engine all live in absolute frames). The display path is just
--- format_timecode(playhead, rate); no offset is added at format time.
---
--- Bug fixed Apr 27 2026: pre-V13 the importer subtracted
--- start_timecode_frame from the parsed playhead before storing, on the
--- (correct-at-the-time) assumption that display formatters would re-add
--- it. After the V13 absolute sweep that double-translation became a bug
--- (display showed 01:59:40:00 for a sequence start of 00:59:50:00).
---
--- Contract now: importer emits ABSOLUTE frames. The helpers below also
--- accept ABSOLUTE inputs (Resolve's CurPlayheadPosition, clip start_value,
--- min_start_frame are all absolute display-TC).

require("test_env")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s",
            label, tostring(got), tostring(want)))
    end
end

print("=== test_importer_playhead_raw_not_absolute ===\n")

local importer_core = require("importers.importer_core")

assert(type(importer_core._compute_playhead_frame) == "function",
    "importer_core must expose _compute_playhead_frame for unit testing")
assert(type(importer_core._compute_view_start_frame) == "function",
    "importer_core must expose _compute_view_start_frame for unit testing")

local fps_25 = { num = 25, den = 1 }
local start_tc = 89750  -- 00:59:50:00 @ 25fps (matches anamnesis-gold-timeline)

-- Case 1: src_playhead_rel parked at sequence start. Stored absolute = start_tc.
check("src_scale present, src_playhead_rel=89750 (parked at start) → absolute 89750",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
        src_playhead_rel = start_tc,
    }),
    89750)

-- Case 2: source DRP with playhead 250 frames past start → absolute start+250.
check("src_scale present, src_playhead_rel=90000 (250f past start) → absolute 90000",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
        src_playhead_rel = start_tc + 250,
    }),
    90000)

-- Case 3: src_scale present but src_playhead_rel missing → defaults to start.
check("src_scale present, src_playhead_rel nil → defaults to start_tc → absolute 89750",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
    }),
    89750)

-- Case 4: no source UI state, no clips → absolute = start_tc.
check("no src_scale, no clips → absolute start_tc 89750",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
    }),
    89750)

-- Case 5: no source UI state, first clip at absolute frame 92265 → absolute 92265.
check("no src_scale, min_start_frame=92265 → absolute 92265",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
        min_start_frame = 92265,
    }),
    92265)

-- Case 6: zero start TC, src_playhead_rel=100 → absolute 100.
check("zero start_tc, src_playhead_rel=100 → absolute 100",
    importer_core._compute_playhead_frame({
        start_timecode_frame = 0,
        src_scale = 0.5,
        src_playhead_rel = 100,
    }),
    100)

-- Case 7: src_playhead_rel < start_tc (defensive — shouldn't happen, but
-- if it does we clamp UP to start_tc; pre-content space is invalid).
check("src_playhead_rel before start_tc → clamps UP to start_tc",
    importer_core._compute_playhead_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
        src_playhead_rel = start_tc - 100,
    }),
    start_tc)

-- ---------------------------------------------------------------
-- view_start_frame — same absolute contract.
-- ---------------------------------------------------------------

-- Case 8: source UI state, playhead at start, viewport centers around it
-- but cannot go below start_tc.
check("playhead 89750, view_dur 1000 → view_start clamps at start_tc 89750",
    importer_core._compute_view_start_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
        playhead_frame = 89750,
        view_duration = 1000,
    }),
    89750)

-- Case 9: playhead deep in timeline, viewport centers around it.
check("playhead 95000, view_dur 1000 → view_start 94500 (95000-500)",
    importer_core._compute_view_start_frame({
        start_timecode_frame = start_tc,
        src_scale = 0.5,
        playhead_frame = 95000,
        view_duration = 1000,
    }),
    94500)

-- ---------------------------------------------------------------
-- Round-trip: stored absolute playhead 89750 displays as 00:59:50:00
-- via the canonical formatter — no doubling.
-- ---------------------------------------------------------------
local frame_utils = require("core.frame_utils")
local rate = { fps_numerator = 25, fps_denominator = 1 }
local stored = importer_core._compute_playhead_frame({
    start_timecode_frame = start_tc,
})
check("stored absolute playhead 89750 displays as 00:59:50:00",
    frame_utils.format_timecode(stored, rate),
    "00:59:50:00")

if fail > 0 then
    print(string.format("\n--- %d passed, %d FAILED ---", pass, fail))
    os.exit(1)
end
print(string.format("\n✅ %d assertions passed", pass))

-- Suppress unused-warning on fps_25.
local _ = fps_25
