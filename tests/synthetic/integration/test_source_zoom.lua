-- Integration: SequenceMonitor viewport zoom / pan state machine.
--
-- Domain rules pinned:
--   (1) load_sequence resets viewport to full extent: [start_frame, total_frames).
--   (2) zoom_by(factor < 1) reduces viewport duration, centered on playhead.
--       New duration = floor(old_dur * factor), clamped to MIN_VIEWPORT_FRAMES.
--   (3) zoom_by(factor > 1) increases viewport duration, clamped to physical
--       extent (total_frames - start_frame). Zooming past full = zoom_to_fit.
--   (4) zoom_by enforces a minimum viewport of MIN_VIEWPORT_FRAMES=30 frames
--       regardless of factor; a single factor=0.001 cannot shrink below 30.
--   (5) zoom_to_fit resets viewport to [start_frame, total_frames). Reversible.
--   (6) set_viewport clamps start to [start_frame, total_frames-duration] and
--       duration to [MIN_VIEWPORT_FRAMES, physical_extent].
--   (7) When playhead is near start, centering would produce start < start_frame;
--       start is clamped to start_frame (duration unchanged).
--   (8) When playhead is near end, centering would produce start > max_start;
--       start is clamped to max_start = total_frames - new_duration (duration unchanged).
--   (9) set_playhead: playhead exits viewport right → viewport shifts so
--       playhead is the last visible frame.
--  (10) set_playhead: playhead exits viewport left → viewport shifts left
--       to the playhead's position.
--  (11) set_playhead at full extent: no viewport shift (everything is visible).
--  (12) Viewport resets to full extent on each load_sequence call.
--  (13) zoom_by(1.0) is identity for duration; re-centers on playhead (same as
--       any other factor but net-zero change when already centered).
--  (14) zoom_by postcondition invariants hold for all factors:
--       viewport_start >= start_frame, viewport_duration >= MIN_VIEWPORT_FRAMES,
--       viewport_start + viewport_duration <= total_frames.
--  (15) zoom_by(0), zoom_by(negative), zoom_by(nil), zoom_by(string) → error.
--  (16) set_viewport(nil, 100), set_viewport(0, nil), set_viewport("a", 100) → error.
--  (17) zoom_by on unloaded monitor (total_frames = 0) is a silent no-op.
--  (18) content_changed signal with shrunk total_frames clamps viewport so
--       viewport_end ≤ new total_frames.
--
-- Replaces tests/synthetic/lua/test_source_zoom.lua, which poisoned
-- package.loaded (qt_constants, logger, renderer, mixer, signals,
-- command_manager), faked _G.qt_create_single_shot_timer, and faked
-- _G.timeline. The mock version could not catch regressions in:
--   * signal wiring inside _wire_signals (content_changed clamping)
--   * real Qt widget construction failing (CREATE_TIMELINE / CREATE_GPU_VIDEO_SURFACE)
--   * transport bootstrap ordering (engine nil before transport.init)
--   * audio_bus_rate resolver requiring a record sequence
--   * seek_to_frame's interaction with the real PlaybackEngine
-- This integration test runs with real C++ bindings throughout.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_source_zoom.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_source_zoom.lua ===")

require("test_env")

local database  = require("core.database")

-- ── DB bootstrap ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_source_zoom_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_zoom', 'ZoomProj', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now)))

assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
    VALUES ('media_zoom', 'proj_zoom', '/test/zoom_clip.mov', 'ZoomClip', 300, 24, 1,
        1920, 1080, 2, 48000, %d, %d)
]], now, now)))

-- 300-frame master at 24fps = 12.5s. Enough room to exercise zoom + pan.
local mc_id = require("test_env").create_test_masterclip_sequence(
    "proj_zoom", "ZoomClip", 24, 1, 300, "media_zoom")

-- record sequence required so audio_bus_rate resolver finds a sample rate
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('rec_zoom', 'proj_zoom', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 300, 0, %d, %d)
]], now, now)))

-- ── Monitor bootstrap ─────────────────────────────────────────────────────────
local monitors = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "proj_zoom",
})
local sm = monitors.source

-- ── Test 1: viewport initializes to full extent on load_sequence ──────────────
print("\n--- Test 1: viewport init on load_sequence ---")
sm:load_sequence(mc_id)
assert(sm.total_frames == 300, string.format(
    "total_frames should be 300, got %d", sm.total_frames))
assert(sm.viewport_start == 0, string.format(
    "viewport_start should be 0, got %d", sm.viewport_start))
assert(sm.viewport_duration == 300, string.format(
    "viewport_duration should be 300, got %d", sm.viewport_duration))
print("  ok: viewport = [0, 300)")

-- ── Test 2: zoom_by(0.8) reduces viewport by 20%, centered on playhead ────────
print("\n--- Test 2: zoom_by(0.8) centers on playhead ---")
-- Playhead at 150 (midpoint). zoom_by(0.8): new_dur = floor(300*0.8) = 240.
-- Center on 150: new_start = 150 - floor(240/2) = 150 - 120 = 30.
-- Invariant: [30, 270) is within [0, 300). ✓
sm.playhead = 150
sm:zoom_by(0.8)
assert(sm.viewport_duration == 240, string.format(
    "viewport_duration should be 240, got %d", sm.viewport_duration))
assert(sm.viewport_start == 30, string.format(
    "viewport_start should be 30, got %d", sm.viewport_start))
print("  ok: viewport = [30, 270) dur=240")

-- ── Test 3: zoom_by(1.25) increases viewport, clamps to full extent ───────────
print("\n--- Test 3: zoom_by(1.25) expands to full extent ---")
-- From [30, 270) dur=240. zoom_by(1.25): new_dur = floor(240*1.25)=300 (full).
-- Center on 150: start = 150-150=0. Clamp: max(0, min(0, 300-300))=0.
sm:zoom_by(1.25)
assert(sm.viewport_duration == 300, string.format(
    "viewport_duration should be 300 (full extent), got %d", sm.viewport_duration))
assert(sm.viewport_start == 0, string.format(
    "viewport_start should be 0, got %d", sm.viewport_start))
print("  ok: viewport = [0, 300) dur=300 (full)")

-- ── Test 4: zoom_by enforces minimum 30 frames ────────────────────────────────
print("\n--- Test 4: minimum viewport enforced ---")
-- From full [0,300). One extreme zoom in, playhead at center.
sm.playhead = 150
sm:zoom_by(0.001)
assert(sm.viewport_duration == 30, string.format(
    "minimum viewport should be 30, got %d", sm.viewport_duration))
-- start = 150 - floor(30/2) = 150 - 15 = 135. Clamp: max(0,min(135,270))=135.
assert(sm.viewport_start == 135, string.format(
    "viewport_start should be 135 (centered on ph=150 with dur=30), got %d",
    sm.viewport_start))
print("  ok: clamped to 30 frames, start=135")

-- ── Test 5: zoom_to_fit resets to full extent ─────────────────────────────────
print("\n--- Test 5: zoom_to_fit ---")
-- Currently [135, 165). zoom_to_fit should restore full extent.
sm:zoom_to_fit()
assert(sm.viewport_start == 0, string.format(
    "viewport_start should be 0, got %d", sm.viewport_start))
assert(sm.viewport_duration == 300, string.format(
    "viewport_duration should be 300, got %d", sm.viewport_duration))
print("  ok: reset to [0, 300)")

-- ── Test 6: set_viewport clamping ─────────────────────────────────────────────
print("\n--- Test 6: set_viewport clamping ---")
-- Over-large start + duration: both clamp.
sm:set_viewport(-10, 500)
assert(sm.viewport_start == 0, string.format(
    "start clamped to 0, got %d", sm.viewport_start))
assert(sm.viewport_duration == 300, string.format(
    "duration clamped to physical=300, got %d", sm.viewport_duration))

-- start would push viewport past end: clamped to total_frames - duration.
-- start=280, dur=100 → max_start = 300-100=200, so start=200.
sm:set_viewport(280, 100)
assert(sm.viewport_start == 200, string.format(
    "start clamped to total_frames-dur=200, got %d", sm.viewport_start))
assert(sm.viewport_duration == 100, string.format(
    "dur should be 100, got %d", sm.viewport_duration))
print("  ok: clamping works")

-- ── Test 7: zoom_by near start — playhead at frame 10 ─────────────────────────
print("\n--- Test 7: zoom_by near start ---")
sm:zoom_to_fit()
sm.playhead = 10
sm:zoom_by(0.5)
-- new_dur = floor(300*0.5)=150. center on 10: start=10-75=-65→ clamped to 0.
assert(sm.viewport_start == 0, string.format(
    "start clamped to 0 near sequence start, got %d", sm.viewport_start))
assert(sm.viewport_duration == 150, string.format(
    "dur should be 150, got %d", sm.viewport_duration))
print("  ok: clamped start to 0")

-- ── Test 8: zoom_by near end — playhead at frame 290 ──────────────────────────
print("\n--- Test 8: zoom_by near end ---")
sm:zoom_to_fit()
sm.playhead = 290
sm:zoom_by(0.5)
-- new_dur=150. center on 290: start=290-75=215. max_start=300-150=150. clamp→150.
assert(sm.viewport_start == 150, string.format(
    "start clamped to max_start=150 near end, got %d", sm.viewport_start))
assert(sm.viewport_duration == 150, string.format(
    "dur should be 150, got %d", sm.viewport_duration))
print("  ok: clamped start to 150 (max_start)")

-- ── Test 9: Playhead follow — exits viewport right ────────────────────────────
print("\n--- Test 9: playhead follow right ---")
sm:set_viewport(0, 100)   -- viewport = [0, 100)
sm:set_playhead(120)       -- playhead exits right

-- After seek: viewport must contain playhead.
-- _ensure_playhead_visible: playhead(120) >= vp_end(100), so
-- viewport_start = 120 - 100 + 1 = 21. Clamp: max(0, min(21,200))=21.
assert(sm.viewport_start > 0, string.format(
    "viewport must shift right; start=%d", sm.viewport_start))
assert(sm.playhead >= sm.viewport_start, string.format(
    "playhead(%d) must be >= viewport_start(%d)", sm.playhead, sm.viewport_start))
assert(sm.playhead < sm.viewport_start + sm.viewport_duration, string.format(
    "playhead(%d) must be < viewport_end(%d)",
    sm.playhead, sm.viewport_start + sm.viewport_duration))
print(string.format("  ok: viewport shifted right to [%d, %d)",
    sm.viewport_start, sm.viewport_start + sm.viewport_duration))

-- ── Test 10: Playhead follow — exits viewport left ────────────────────────────
print("\n--- Test 10: playhead follow left ---")
sm:set_viewport(100, 100)  -- viewport = [100, 200)
sm:set_playhead(50)         -- playhead exits left

-- _ensure_playhead_visible: playhead(50) < viewport_start(100), so
-- viewport_start = playhead = 50.
assert(sm.viewport_start == 50, string.format(
    "viewport_start should be 50 (shifted to playhead), got %d", sm.viewport_start))
assert(sm.viewport_duration == 100, "duration unchanged after left follow")
print("  ok: viewport shifted left, start=50")

-- ── Test 11: No viewport shift at full extent ─────────────────────────────────
print("\n--- Test 11: no shift at full zoom ---")
sm:zoom_to_fit()    -- [0, 300)
sm:set_playhead(150)
assert(sm.viewport_start == 0, string.format(
    "viewport_start should stay 0 at full zoom, got %d", sm.viewport_start))
assert(sm.viewport_duration == 300, string.format(
    "viewport_duration should stay 300 at full zoom, got %d", sm.viewport_duration))
print("  ok: no shift at full extent")

-- ── Test 12: Viewport resets on load_sequence ─────────────────────────────────
print("\n--- Test 12: viewport resets on load_sequence ---")
sm:set_viewport(50, 100)
assert(sm.viewport_start == 50, "pre-condition: viewport_start=50")
sm:load_sequence(mc_id)
assert(sm.viewport_start == 0, string.format(
    "viewport_start must reset to 0 on load, got %d", sm.viewport_start))
assert(sm.viewport_duration == 300, string.format(
    "viewport_duration must reset to 300 on load, got %d", sm.viewport_duration))
print("  ok: viewport reset to [0, 300) on load_sequence")

-- ── Test 13: zoom_by(1.0) — identity for duration, re-centers on playhead ─────
print("\n--- Test 13: zoom_by(1.0) is identity ---")
sm:set_viewport(50, 100)
sm.playhead = 100
-- new_dur = floor(100*1.0) = 100 (unchanged).
-- Center on 100: start = 100 - 50 = 50. Already at 50.
sm:zoom_by(1.0)
assert(sm.viewport_duration == 100, string.format(
    "zoom_by(1.0) preserves duration=100, got %d", sm.viewport_duration))
assert(sm.viewport_start == 50, string.format(
    "zoom_by(1.0) re-centers on playhead=100: start=50, got %d", sm.viewport_start))
print("  ok: zoom_by(1.0) identity")

-- ── Test 14: zoom_by postcondition invariants for all factors ─────────────────
print("\n--- Test 14: zoom_by postcondition invariants ---")
sm:load_sequence(mc_id)
sm.playhead = 50    -- near-start value, exercises clamping
for _, factor in ipairs({0.001, 0.1, 0.5, 0.8, 1.0, 1.25, 2.0, 10.0}) do
    sm:zoom_by(factor)
    assert(sm.viewport_start >= 0, string.format(
        "postcond: viewport_start >= 0 (got %d, factor=%.3f)",
        sm.viewport_start, factor))
    assert(sm.viewport_duration >= 30, string.format(
        "postcond: viewport_duration >= 30 (got %d, factor=%.3f)",
        sm.viewport_duration, factor))
    assert(sm.viewport_start + sm.viewport_duration <= sm.total_frames, string.format(
        "postcond: viewport end <= total_frames (got %d+%d=%d > %d, factor=%.3f)",
        sm.viewport_start, sm.viewport_duration,
        sm.viewport_start + sm.viewport_duration, sm.total_frames, factor))
end
print("  ok: invariants hold for all zoom factors")

-- ── Test 15: zoom_by rejects invalid factor ────────────────────────────────────
print("\n--- Test 15: zoom_by rejects invalid factor ---")
local expect_error = require("test_env").expect_error
expect_error(function() sm:zoom_by(0) end, "positive number")
expect_error(function() sm:zoom_by(-1) end, "positive number")
expect_error(function() sm:zoom_by(nil) end, "positive number")
expect_error(function() sm:zoom_by("two") end, "positive number")
print("  ok: zoom_by rejects 0, negative, nil, string")

-- ── Test 16: set_viewport rejects non-numbers ─────────────────────────────────
print("\n--- Test 16: set_viewport rejects non-numbers ---")
expect_error(function() sm:set_viewport(nil, 100) end, "must be numbers")
expect_error(function() sm:set_viewport(0, nil) end, "must be numbers")
expect_error(function() sm:set_viewport("a", 100) end, "must be numbers")
print("  ok: set_viewport rejects nil and string")

-- ── Test 17: zoom_by no-op on unloaded monitor ────────────────────────────────
print("\n--- Test 17: zoom_by no-op on unloaded monitor ---")
-- Create a fresh monitor that has never had load_sequence called.
-- total_frames = 0, viewport_duration = 0 → physical=0, early return.
local sm2 = require("ui.sequence_monitor").new({ view_id = "zoom_unloaded_test" })
sm2:zoom_by(0.8)
assert(sm2.viewport_duration == 0, string.format(
    "unloaded monitor: viewport_duration stays 0, got %d", sm2.viewport_duration))
assert(sm2.viewport_start == 0, string.format(
    "unloaded monitor: viewport_start stays 0, got %d", sm2.viewport_start))
sm2:destroy()
print("  ok: zoom_by no-op on unloaded monitor")

-- ── Test 18: content shrink (real clip delete) clamps viewport ────────────────
print("\n--- Test 18: content_changed clamps viewport ---")
-- A timeline sequence's duration is the end of its last clip (NLE convention).
-- Deleting the tail clip while zoomed in past the new end must pull the
-- viewport back inside the content: zoom level (duration) is preserved when
-- it still fits, and the window slides left so viewport_end == new total.
-- Two 150-frame clips back-to-back → content end 300. Delete the tail clip
-- via the real DeleteClip command: command_manager emits content_changed,
-- the engine re-reads content bounds from the DB (priority 100), then the
-- monitor clamps (priority 110). All real-path — no signal is hand-fired.
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('tl_zoom', 'proj_zoom', 'TLZoom', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 300, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('tl_zoom_v1', 'tl_zoom', 'V1', 'VIDEO', 1, 1);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
    VALUES
        ('tl_zoom_c1', 'proj_zoom', 'Head', 'tl_zoom_v1', '%s', 'tl_zoom',
         0, 150, 0, 150, 1, 'resample', 1.0, 0, %d, %d),
        ('tl_zoom_c2', 'proj_zoom', 'Tail', 'tl_zoom_v1', '%s', 'tl_zoom',
         150, 150, 150, 300, 1, 'resample', 1.0, 0, %d, %d);
]], now, now, mc_id, now, now, mc_id, now, now)))

sm:load_sequence("tl_zoom")
assert(sm.total_frames == 300, string.format(
    "pre-condition: timeline content end = 300, got %d", sm.total_frames))
sm:set_viewport(150, 100)
assert(sm.viewport_start == 150 and sm.viewport_duration == 100,
    "pre-condition: viewport = [150, 250)")

-- Undoable commands require an active project/sequence context (the same
-- state the app sets when a timeline becomes active).
local command_manager = require("core.command_manager")
command_manager.init("tl_zoom", "proj_zoom")
command_manager.activate_timeline_stack("tl_zoom")

local del_result = command_manager.execute("DeleteClip", {
    sequence_id = "tl_zoom",
    clip_id     = "tl_zoom_c2",
})
assert(del_result.success, string.format(
    "DeleteClip must succeed; got error: %s", tostring(del_result.error_message)))

-- Content end is now 150 (end of the remaining clip). Viewport duration 100
-- still fits, so it is preserved; the window slides left to [50, 150).
assert(sm.total_frames == 150, string.format(
    "total_frames must shrink to 150 after tail delete, got %d", sm.total_frames))
assert(sm.viewport_duration == 100, string.format(
    "zoom level (duration=100) preserved when it still fits, got %d",
    sm.viewport_duration))
assert(sm.viewport_start == 50, string.format(
    "viewport slides left to keep end within content: start=50, got %d",
    sm.viewport_start))
print(string.format("  ok: viewport clamped to [%d, %d) after tail-clip delete",
    sm.viewport_start, sm.viewport_start + sm.viewport_duration))

-- ── Cleanup ───────────────────────────────────────────────────────────────────
sm:destroy()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_source_zoom.lua")
