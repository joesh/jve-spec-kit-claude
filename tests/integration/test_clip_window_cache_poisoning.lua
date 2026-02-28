-- Integration test: _send_clips_to_tmb(0) cache poisoning through PlaybackEngine.
--
-- Uses REAL C++ TMB, PlaybackController, GPUVideoSurface with Anamnesis fixture
-- media. Mocks only the Sequence model (frame-dependent clip lookup) and Renderer.
--
-- Reproduces the real bug with two tracks (V1 + V3):
--   _send_clips_to_tmb(0) loads ONE clip per track via get_next_video(0):
--     V1: v1-helen-vhs   [122097, 122928)
--     V3: v3-18-097-002  [122960, 123003)
--   Clip window union = [122097, 123003).
--
--   Saved playhead at frame 122940 — inside the window but in the gap between
--   loaded clips. v1-30-124-001 [122928, 122960) exists in DB but was never fed
--   to TMB. seek(122940) sees 122940 ∈ [122097, 123003) → skips re-query →
--   TMB has no clip on any track at 122940 → gap → no frame displayed.
--
-- Must run via: JVEEditor --test tests/integration/test_clip_window_cache_poisoning.lua

--------------------------------------------------------------------------------
-- Pre-load mocks BEFORE requiring playback_engine
-- (playback_engine requires these at load time via top-level require())
--------------------------------------------------------------------------------

-- Logger mock (must exist before playback_engine loads)
package.loaded["core.logger"] = {
    for_area = function()
        return {
            event = function() end,
            detail = function() end,
            warn = function() end,
            error = function() end,
        }
    end,
}

-- Signals mock
package.loaded["core.signals"] = {
    connect = function() return "conn_id" end,
    disconnect = function() end,
    emit = function() end,
}

-- Renderer mock
package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 25, fps_den = 1,
            kind = "timeline", name = "Anamnesis",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function() return nil, nil end,
}

--------------------------------------------------------------------------------
-- Anamnesis V1 clip layout (same as test_tmb_real_timeline.lua)
--------------------------------------------------------------------------------

local ienv = require("integration.integration_test_env")
local EMP = ienv.require_emp()

local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis")

local media = {
    vfx_01    = MEDIA_DIR .. "/A016_C003_VFX_01.mov",
    day5_c003 = MEDIA_DIR .. "/A016_C003.mov",
    day4_c002 = MEDIA_DIR .. "/A012_C002.mov",
    day4_c008 = MEDIA_DIR .. "/A012_C008.mov",
    day4_c005 = MEDIA_DIR .. "/A012_C005.mov",
    day4_c010 = MEDIA_DIR .. "/A012_C010.mov",
}

-- Verify fixture media exists
for name, path in pairs(media) do
    local f = io.open(path, "r")
    assert(f, "Missing fixture: " .. name .. " at " .. path)
    f:close()
end

-- Clip definitions per track (sequence entry format for Sequence:get_video_at)
local tracks = {
    [1] = {
        track_id = "track_v1",
        clips = {
            { id = "v1-helen-vhs",  tl_start = 122097, dur = 831, src_in = 0, path = media.vfx_01 },
            { id = "v1-30-124-001", tl_start = 122928, dur = 32,  src_in = 0, path = media.day5_c003 },
            { id = "v1-18-097-002", tl_start = 122960, dur = 43,  src_in = 0, path = media.day4_c002 },
            { id = "v1-18-100-001", tl_start = 123003, dur = 40,  src_in = 0, path = media.day4_c008 },
            { id = "v1-18-098-003", tl_start = 123043, dur = 129, src_in = 0, path = media.day4_c005 },
            { id = "v1-18-100-003", tl_start = 123172, dur = 114, src_in = 0, path = media.day4_c010 },
        },
    },
    [3] = {
        track_id = "track_v3",
        clips = {
            { id = "v3-18-097-002", tl_start = 122960, dur = 43, src_in = 0, path = media.day4_c002 },
            { id = "v3-18-100-001", tl_start = 123003, dur = 40, src_in = 0, path = media.day4_c008 },
            { id = "v3-18-100-003", tl_start = 123172, dur = 114, src_in = 0, path = media.day4_c010 },
        },
    },
}

--- Build a Sequence model entry from a compact clip definition + track index.
local function make_entry(clip_def, track_idx)
    local t = tracks[track_idx]
    return {
        clip = {
            id = clip_def.id,
            timeline_start = clip_def.tl_start,
            duration = clip_def.dur,
            source_in = clip_def.src_in,
            source_out = clip_def.src_in + clip_def.dur,
            rate = { fps_numerator = 25, fps_denominator = 1 },
        },
        track = { id = t.track_id, track_index = track_idx },
        media_path = clip_def.path,
        media_fps_num = 25,
        media_fps_den = 1,
    }
end

--- Frame-dependent clip lookup: one entry per track covering `frame`.
local function get_video_at(_, frame)
    local results = {}
    for idx, t in pairs(tracks) do
        for _, c in ipairs(t.clips) do
            if frame >= c.tl_start and frame < c.tl_start + c.dur then
                results[#results + 1] = make_entry(c, idx)
                break  -- one per track
            end
        end
    end
    return results
end

--- Next clip on each track at or after boundary.
local function get_next_video(_, boundary)
    local results = {}
    for idx, t in pairs(tracks) do
        for _, c in ipairs(t.clips) do
            if c.tl_start >= boundary then
                results[#results + 1] = make_entry(c, idx)
                break  -- one per track
            end
        end
    end
    return results
end

-- Mock Sequence model with frame-dependent lookups
local mock_sequence = {
    id = "anamnesis-test",
    compute_content_end = function()
        -- Last V1 clip: v1-18-100-003 at 123172 + 114 = 123286
        return 123286
    end,
    get_video_at = get_video_at,
    get_next_video = get_next_video,
    get_prev_video = function() return {} end,
    get_audio_at = function() return {} end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

--------------------------------------------------------------------------------
-- Load PlaybackEngine (uses real qt_constants, mocked Sequence/Renderer/Signals)
--------------------------------------------------------------------------------

local PlaybackEngine = require("core.playback.playback_engine")

print("=== test_clip_window_cache_poisoning.lua (integration) ===")

--------------------------------------------------------------------------------
-- Create real GPUVideoSurface
--------------------------------------------------------------------------------

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")

local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_clip_window_cache_poisoning.lua passed (skipped)")
    return
end
print("  ✓ Created real GPUVideoSurface")

--------------------------------------------------------------------------------
-- Create PlaybackEngine, wire surface, load sequence
--------------------------------------------------------------------------------

local engine = PlaybackEngine.new({
    on_show_frame = function() end,
    on_show_gap = function() end,
    on_set_rotation = function() end,
    on_set_par = function() end,
    on_position_changed = function() end,
})

engine:set_surface(surface)
print("  ✓ PlaybackEngine created, surface wired")

-- load_sequence: creates TMB + PlaybackController internally.
local total = mock_sequence.compute_content_end()
engine:load_sequence("anamnesis-test", total)
print(string.format("  ✓ Loaded sequence: %d total frames", total))

-- With fix: no _send_clips_to_tmb(0), so clip window is nil after load.
-- With bug: clip window [122097, 123003) from pre-loading first clips.
assert(engine._tmb_clip_window == nil,
    "clip window must be nil after load_sequence (no pre-load)")
print("  ✓ No clip window after load (no cache poisoning)")

-- Playhead 122940: inside v1-30-124-001 [122928, 122960) on V1.
-- With bug, this falls in the gap between the two pre-loaded clips:
--   V1: v1-helen-vhs ends at 122928 (before 122940)
--   V3: v3-18-097-002 starts at 122960 (after 122940)
local SAVED_PLAYHEAD = 122940

--------------------------------------------------------------------------------
-- Seek to saved playhead — this is where the bug manifests
--------------------------------------------------------------------------------

local count_before = EMP.SURFACE_FRAME_COUNT(surface)

engine:seek(SAVED_PLAYHEAD)

local count_after = EMP.SURFACE_FRAME_COUNT(surface)
print(string.format("  Surface frame count: before=%d after=%d", count_before, count_after))

-- With the bug: TMB has v1-helen-vhs (ends 122928) and v3-18-097-002 (starts 122960).
-- Neither covers 122940. deliverFrame → gap on all tracks → no frame.
-- Fixed: no _send_clips_to_tmb(0) in load_sequence → seek(122940) queries fresh →
-- feeds v1-30-124-001 [122928, 122960) to TMB → frame delivered.
assert(count_after > count_before,
    string.format("REGRESSION: seek(%d) delivered no frame to surface! " ..
        "count before=%d after=%d. " ..
        "Cause: _send_clips_to_tmb(0) in load_sequence poisoned clip window cache — " ..
        "seek skipped re-query, TMB has no clip at playhead.",
        SAVED_PLAYHEAD, count_before, count_after))

print(string.format("  ✓ seek(%d) delivered frame to surface", SAVED_PLAYHEAD))

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

if engine._playback_controller then
    qt_constants.PLAYBACK.CLOSE(engine._playback_controller)
end
if engine._tmb then
    EMP.TMB_CLOSE(engine._tmb)
end

print("✅ test_clip_window_cache_poisoning.lua passed")
