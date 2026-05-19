#!/usr/bin/env luajit

-- Measurement (NOT a regression assertion): how long does TimelineTab:get_marks
-- take per call? It pulls fresh via Sequence.load → SQL prepare/exec/24-col row
-- assembly every time. Ruler/render code in timeline_panel.lua reads display
-- marks on every redraw — including playback's ~60Hz tick. We want a number
-- before deciding whether to cache.
--
-- The test PRINTS but does NOT assert thresholds. Run manually; consult the
-- output before changing TimelineTab.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTab = require("ui.timeline.timeline_tab")

local DB = "/tmp/jve/test_timeline_tab_get_marks_perf.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        mark_in_frame, mark_out_frame,
        start_timecode_frame, video_scroll_offset, audio_scroll_offset,
        video_audio_split_ratio, created_at, modified_at, mutation_generation)
    VALUES ('seq', 'p', 'S', 'sequence',
        24, 1, 48000, 1920, 1080,
        0, 0, 1000,
        100, 500,
        0, 0, 0,
        0.5, %d, %d, 0);
]], now, now, now, now)))

local tab = TimelineTab.new("record", "seq")
assert(tab)

-- Warm: one call to ensure prepare/cache paths are hot. Without this the
-- first sample dominates.
tab:get_marks()

local N = 10000
local t0 = os.clock()
for _ = 1, N do
    local m = tab:get_marks()
    assert(m.in_frame == 100 and m.out_frame == 500)
end
local elapsed = os.clock() - t0
local per_call_us = (elapsed / N) * 1e6

print("=== TimelineTab:get_marks perf ===")
print(string.format("  %d calls in %.3fs", N, elapsed))
print(string.format("  %.2f µs/call", per_call_us))
print(string.format("  60Hz frame budget: 16667 µs"))
print(string.format("  per-frame share if called once per redraw: %.4f%%",
    per_call_us / 16667 * 100))
print(string.format("  60Hz cost for 1000 calls/frame (worst): %.2f%%",
    (per_call_us * 1000) / 16667 * 100))

print("\n(no assertion — read the numbers and decide on caching)")
