-- Integration: monitor mark bar wheel/trackpad gesture → command dispatch.
--
-- Domain rules pinned:
--   (1) compute_wheel_frame_delta(delta_x, width, viewport_duration) is a
--       pure linear mapping: floor((delta_x / width) * viewport_duration + 0.5).
--       The conversion lives in the module so the dispatch math is independently
--       testable; clamping is the consuming command's responsibility.
--   (2) ScrubMonitorPlayhead advances the playhead by delta_frames, clamped
--       to [start_frame, total_frames-1]. Plain-wheel right = later in timeline.
--   (3) PanMonitorMarkBar shifts the viewport by delta_frames, clamped so
--       viewport stays within [start_frame, total_frames). Opt+wheel right =
--       viewport moves right (shows later frames).
--   (4) Zero delta_frames: no movement occurs (playhead and viewport unchanged).
--   (5) Negative delta_frames: scrub earlier; viewport shifts left.
--   (6) ScrubMonitorPlayhead clamps at sequence boundaries:
--         playhead + delta > total_frames-1 → clamps to total_frames-1.
--         playhead + delta < start_frame    → clamps to start_frame.
--
-- Replaces tests/synthetic/lua/test_monitor_mark_bar_wheel_scrubs.lua, which
-- stubbed command_manager, _G.timeline, and package.loaded poisons that made
-- the test exercise its own fakes rather than the real dispatch path. The
-- stub version could not catch regressions in:
--   * the real command executor's clamping logic
--   * misregistration of either command in the registry
--   * panel_manager.get_sequence_monitor failing to find the monitor
-- This integration test drives the real commands through the real
-- command_manager, panel_manager, and SequenceMonitor state machine.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_monitor_mark_bar_wheel.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_monitor_mark_bar_wheel.lua ===")

require("test_env")

local database      = require("core.database")
local command_manager = require("core.command_manager")

-- ── DB bootstrap ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_monitor_mark_bar_wheel_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_mmb', 'MarkBarWheel',
            'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
    VALUES ('media_mmb', 'proj_mmb', '/test/mmb_clip.mov', 'MMBClip', 240, 24, 1,
        1920, 1080, 2, 48000, %d, %d);
]], now, now, now, now)))

-- 240-frame master sequence at 24fps = 10s. Non-trivial length so clamping
-- and delta math both have room to exercise boundary and midpoint cases.
local mc_id = require("test_env").create_test_masterclip_sequence(
    "proj_mmb", "MMBClip", 24, 1, 240, "media_mmb")

-- record sequence required so audio_bus_rate resolver can find a sample rate
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('rec_mmb', 'proj_mmb', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 240, 0, %d, %d)
]], now, now)))

-- ── Monitor bootstrap ─────────────────────────────────────────────────────────
local monitors = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "proj_mmb",
})
local sm = monitors.source
sm:load_sequence(mc_id)

-- post-load: total_frames = 240, start_frame = 0, viewport [0, 240)
assert(sm.total_frames == 240, string.format(
    "setup: total_frames expected 240, got %d", sm.total_frames))
assert(sm.viewport_duration == 240, string.format(
    "setup: viewport_duration expected 240, got %d", sm.viewport_duration))

-- ── Part 1: compute_wheel_frame_delta pure math ───────────────────────────────
print("\n-- (1) compute_wheel_frame_delta pure math --")
local m = require("ui.monitor_mark_bar")

-- Bar width=200, viewport_duration=1000: 1 px = 5 frames.
local W, VD = 200, 1000
assert(m.compute_wheel_frame_delta(0, W, VD) == 0,
    "zero pixel delta → zero frames")
assert(m.compute_wheel_frame_delta(20, W, VD) == 100,
    "+20 px / 200px wide / 1000-frame vp = +100 frames")
assert(m.compute_wheel_frame_delta(-40, W, VD) == -200,
    "-40 px / 200px wide / 1000-frame vp = -200 frames")

-- Bar width=400, viewport_duration=240 (matches loaded sequence): 1 px = 0.6 frames.
-- delta_x=5: floor(5/400 * 240 + 0.5) = floor(3.0 + 0.5) = floor(3.5) = 3
assert(m.compute_wheel_frame_delta(5, 400, 240) == 3,
    "5px / 400px / 240-frame vp = 3 frames (floor of 3.5)")
-- delta_x=1: floor(1/400 * 240 + 0.5) = floor(0.6 + 0.5) = floor(1.1) = 1
assert(m.compute_wheel_frame_delta(1, 400, 240) == 1,
    "1px / 400px / 240-frame vp = 1 frame (rounds to 1)")
print("  PASS compute_wheel_frame_delta math")

-- ── Part 2: ScrubMonitorPlayhead — plain right scrub ─────────────────────────
print("\n-- (2) ScrubMonitorPlayhead plain right scrub --")
-- Place playhead at frame 60; scrub forward 24 frames (=1s at 24fps).
-- Using non-trivial midpoint value, not 0 offset.
sm:set_playhead(60)
assert(sm.playhead == 60, "setup: playhead at 60")

local ok = command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "source_monitor",
    delta_frames    = 24,
})
assert(ok, "ScrubMonitorPlayhead must return truthy")
assert(sm.playhead == 84, string.format(
    "scrub +24 from 60 → 84; got %d", sm.playhead))
print("  PASS playhead 60 + delta 24 = 84")

-- ── Part 3: ScrubMonitorPlayhead — negative scrub (earlier) ──────────────────
print("\n-- (3) ScrubMonitorPlayhead negative delta (scrub earlier) --")
-- Scrub back 48 frames from 84 → 36. Not zero-based; uses non-trivial value.
ok = command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "source_monitor",
    delta_frames    = -48,
})
assert(ok, "ScrubMonitorPlayhead (negative) must return truthy")
assert(sm.playhead == 36, string.format(
    "scrub -48 from 84 → 36; got %d", sm.playhead))
print("  PASS playhead 84 - delta 48 = 36")

-- ── Part 4: ScrubMonitorPlayhead clamps at far boundary ──────────────────────
print("\n-- (4) ScrubMonitorPlayhead clamps at total_frames - 1 --")
sm:set_playhead(220)
ok = command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "source_monitor",
    delta_frames    = 999,   -- would overshoot past end
})
assert(ok, "ScrubMonitorPlayhead (overshoot) must return truthy")
assert(sm.playhead == 239, string.format(
    "scrub from 220 + 999 clamps to total_frames-1 = 239; got %d", sm.playhead))
print("  PASS playhead clamped to 239 (total_frames-1)")

-- ── Part 5: ScrubMonitorPlayhead clamps at near boundary ─────────────────────
print("\n-- (5) ScrubMonitorPlayhead clamps at start_frame --")
sm:set_playhead(10)
ok = command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "source_monitor",
    delta_frames    = -999,  -- would undershoot past start
})
assert(ok, "ScrubMonitorPlayhead (undershoot) must return truthy")
assert(sm.playhead == 0, string.format(
    "scrub from 10 - 999 clamps to start_frame=0; got %d", sm.playhead))
print("  PASS playhead clamped to 0 (start_frame)")

-- ── Part 6: PanMonitorMarkBar — Opt+wheel right, viewport pans right ─────────
print("\n-- (6) PanMonitorMarkBar shifts viewport right --")
-- Zoom in to a 120-frame viewport at the start, then pan right by 30 frames.
-- viewport [0, 120) → after pan +30 → [30, 150).
sm:set_viewport(0, 120)
assert(sm.viewport_start == 0 and sm.viewport_duration == 120, "setup: viewport [0, 120)")

ok = command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "source_monitor",
    delta_frames    = 30,
})
assert(ok, "PanMonitorMarkBar must return truthy")
assert(sm.viewport_start == 30, string.format(
    "pan +30 from vp_start=0 → 30; got %d", sm.viewport_start))
assert(sm.viewport_duration == 120, string.format(
    "pan must preserve viewport_duration=120; got %d", sm.viewport_duration))
print("  PASS viewport_start 0 + delta 30 = 30, duration preserved")

-- ── Part 7: PanMonitorMarkBar — negative delta pans left ─────────────────────
print("\n-- (7) PanMonitorMarkBar shifts viewport left --")
-- viewport [30, 150), pan left by 15 → [15, 135).
ok = command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "source_monitor",
    delta_frames    = -15,
})
assert(ok, "PanMonitorMarkBar (negative) must return truthy")
assert(sm.viewport_start == 15, string.format(
    "pan -15 from vp_start=30 → 15; got %d", sm.viewport_start))
assert(sm.viewport_duration == 120, string.format(
    "pan left must preserve viewport_duration=120; got %d", sm.viewport_duration))
print("  PASS viewport_start 30 - delta 15 = 15, duration preserved")

-- ── Part 8: PanMonitorMarkBar clamps at far end ──────────────────────────────
print("\n-- (8) PanMonitorMarkBar clamps viewport at far end --")
-- viewport [15, 135). Pan by 9999 → max_start = 240-120=120; clamp to [120, 240).
ok = command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "source_monitor",
    delta_frames    = 9999,
})
assert(ok, "PanMonitorMarkBar (overshoot) must return truthy")
assert(sm.viewport_start == 120, string.format(
    "pan overshoot clamps to total_frames-viewport_duration = 120; got %d",
    sm.viewport_start))
assert(sm.viewport_duration == 120, "duration preserved after far-end clamp")
print("  PASS viewport_start clamped to 120 (total_frames - viewport_duration)")

-- ── Part 9: PanMonitorMarkBar clamps at near end ─────────────────────────────
print("\n-- (9) PanMonitorMarkBar clamps viewport at start_frame --")
-- viewport [120, 240). Pan by -9999 → clamp to start_frame=0.
ok = command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "source_monitor",
    delta_frames    = -9999,
})
assert(ok, "PanMonitorMarkBar (undershoot) must return truthy")
assert(sm.viewport_start == 0, string.format(
    "pan undershoot clamps to start_frame=0; got %d", sm.viewport_start))
assert(sm.viewport_duration == 120, "duration preserved after near-end clamp")
print("  PASS viewport_start clamped to 0 (start_frame)")

-- ── Part 10: zero delta_frames = no movement ─────────────────────────────────
print("\n-- (10) zero delta_frames produces no movement --")
sm:set_playhead(100)
-- delta=0: target = playhead + 0 = 100. Clamp: max(start_frame=0, min(100, 239))=100.
-- seek_to_frame is called but playhead is already 100; net state change = zero.
command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "source_monitor",
    delta_frames    = 0,
})
assert(sm.playhead == 100, string.format(
    "zero delta: playhead stays at 100; got %d", sm.playhead))

sm:set_viewport(0, 120)
command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "source_monitor",
    delta_frames    = 0,
})
assert(sm.viewport_start == 0, string.format(
    "zero delta: viewport_start stays at 0; got %d", sm.viewport_start))
print("  PASS zero delta_frames: no net movement")

-- ── Cleanup ───────────────────────────────────────────────────────────────────
sm:destroy()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_monitor_mark_bar_wheel.lua")
