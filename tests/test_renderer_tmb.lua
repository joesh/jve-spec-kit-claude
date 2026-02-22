#!/usr/bin/env luajit
--- Test Renderer with TMB-based video path.
--
-- Tests the renderer's get_video_frame(tmb, video_track_indices, playhead_frame)
-- using mocked EMP TMB bindings. Verifies:
-- - Normal frame decode returns frame + metadata
-- - Gap returns nil, nil
-- - Offline returns offline frame + metadata
-- - Multi-track priority (first element in array = highest priority = wins)
-- - Empty track list returns nil, nil
--
-- @file test_renderer_tmb.lua

require('test_env')

print("=== test_renderer_tmb.lua ===")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

-- Track TMB_GET_VIDEO_FRAME calls for verification
local tmb_get_video_calls = {}

-- Configurable per-track frame map: {[track_idx] = {[frame] = {handle, metadata}}}
local track_frame_map = {}

local function reset_mocks()
    tmb_get_video_calls = {}
    track_frame_map = {}
end

-- Mock qt_constants with TMB bindings
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_GET_VIDEO_FRAME = function(tmb, track_idx, frame)
            tmb_get_video_calls[#tmb_get_video_calls + 1] = {
                tmb = tmb, track_idx = track_idx, frame = frame,
            }
            local track = track_frame_map[track_idx]
            if track then
                local entry = track[frame]
                if entry then
                    return entry.handle, entry.metadata
                end
            end
            -- Default: gap (nil frame, not offline)
            return nil, { clip_id = "", offline = false }
        end,
        COMPOSE_OFFLINE_FRAME = function(png_path, lines)
            return "offline_frame_handle"
        end,
    },
}

-- Mock offline_frame_cache (uses real module which calls COMPOSE_OFFLINE_FRAME)
-- Actually load the real module — it will use our mocked EMP.COMPOSE_OFFLINE_FRAME
-- For simplicity, mock it directly:
package.loaded["core.media.offline_frame_cache"] = {
    get_frame = function(metadata)
        -- Return a composited frame handle for offline clips
        return "offline_composed_" .. (metadata.clip_id or "unknown")
    end,
}

-- Mock Sequence model (needed by renderer.get_sequence_info)
package.loaded["models.sequence"] = {
    load = function(seq_id)
        return {
            id = seq_id,
            frame_rate = { fps_numerator = 24, fps_denominator = 1 },
            width = 1920,
            height = 1080,
            name = "TestSeq",
            kind = "timeline",
            audio_sample_rate = 48000,
        }
    end,
}

local Renderer = require("core.renderer")
local mock_tmb = "test_tmb_handle"

--------------------------------------------------------------------------------
-- Test 1: Normal frame decode returns frame + metadata
--------------------------------------------------------------------------------
print("\n--- normal frame decode ---")
do
    reset_mocks()
    track_frame_map[1] = {
        [10] = {
            handle = "frame_10",
            metadata = {
                clip_id = "clip_a",
                media_path = "/test/clip_a.mov",
                source_frame = 10,
                rotation = 90,
                clip_fps_num = 24,
                clip_fps_den = 1,
                clip_start_frame = 0,
                clip_end_frame = 100,
                offline = false,
            },
        },
    }

    local frame, meta = Renderer.get_video_frame(mock_tmb, {1}, 10)
    assert(frame == "frame_10", string.format(
        "Expected frame 'frame_10', got %s", tostring(frame)))
    assert(meta, "Expected non-nil metadata")
    assert(meta.clip_id == "clip_a", "Expected clip_id='clip_a'")
    assert(meta.media_path == "/test/clip_a.mov", "Expected correct media_path")
    assert(meta.source_frame == 10, "Expected source_frame=10")
    assert(meta.rotation == 90, "Expected rotation=90")
    assert(meta.clip_fps_num == 24, "Expected clip_fps_num=24")
    assert(meta.clip_start_frame == 0, "Expected clip_start_frame=0")
    assert(meta.clip_end_frame == 100, "Expected clip_end_frame=100")
    assert(meta.offline == false, "Expected offline=false")

    -- Verify TMB_GET_VIDEO_FRAME was called correctly
    assert(#tmb_get_video_calls == 1, "Expected 1 TMB call")
    assert(tmb_get_video_calls[1].tmb == mock_tmb, "TMB handle passed through")
    assert(tmb_get_video_calls[1].track_idx == 1, "Track index passed through")
    assert(tmb_get_video_calls[1].frame == 10, "Frame passed through")

    print("  normal frame decode passed")
end

--------------------------------------------------------------------------------
-- Test 2: Gap returns nil, nil
--------------------------------------------------------------------------------
print("\n--- gap returns nil,nil ---")
do
    reset_mocks()
    -- No entries in track_frame_map → all frames are gaps

    local frame, meta = Renderer.get_video_frame(mock_tmb, {1}, 50)
    assert(frame == nil, "Expected nil frame for gap")
    assert(meta == nil, "Expected nil metadata for gap")

    print("  gap returns nil,nil passed")
end

--------------------------------------------------------------------------------
-- Test 3: Empty track list returns nil, nil
--------------------------------------------------------------------------------
print("\n--- empty track list ---")
do
    reset_mocks()

    local frame, meta = Renderer.get_video_frame(mock_tmb, {}, 10)
    assert(frame == nil, "Expected nil frame with no tracks")
    assert(meta == nil, "Expected nil metadata with no tracks")
    assert(#tmb_get_video_calls == 0, "No TMB calls with empty track list")

    print("  empty track list passed")
end

--------------------------------------------------------------------------------
-- Test 4: Offline returns composited frame + metadata
--------------------------------------------------------------------------------
print("\n--- offline frame ---")
do
    reset_mocks()
    track_frame_map[1] = {
        [20] = {
            handle = nil,  -- offline: no decoded frame
            metadata = {
                clip_id = "clip_offline",
                media_path = "/missing/video.mov",
                source_frame = 20,
                rotation = 0,
                clip_fps_num = 24,
                clip_fps_den = 1,
                clip_start_frame = 0,
                clip_end_frame = 48,
                offline = true,
            },
        },
    }

    local frame, meta = Renderer.get_video_frame(mock_tmb, {1}, 20)
    assert(frame ~= nil, "Expected non-nil frame for offline (composited)")
    assert(frame == "offline_composed_clip_offline",
        "Expected composited offline frame, got: " .. tostring(frame))
    assert(meta, "Expected non-nil metadata for offline")
    assert(meta.offline == true, "Expected offline=true in metadata")
    assert(meta.clip_id == "clip_offline", "Expected clip_id='clip_offline'")
    assert(meta.media_path == "/missing/video.mov", "Expected media_path")

    print("  offline frame passed")
end

--------------------------------------------------------------------------------
-- Test 5: Multi-track priority (first element in array wins)
--------------------------------------------------------------------------------
print("\n--- multi-track priority ---")
do
    reset_mocks()
    -- Track 1 (first in array): clip at frame 30
    track_frame_map[1] = {
        [30] = {
            handle = "frame_track1",
            metadata = {
                clip_id = "clip_v1",
                media_path = "/v1.mov",
                source_frame = 30,
                rotation = 0,
                offline = false,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 100,
            },
        },
    }
    -- Track 2 (below): also has clip at frame 30
    track_frame_map[2] = {
        [30] = {
            handle = "frame_track2",
            metadata = {
                clip_id = "clip_v2",
                media_path = "/v2.mov",
                source_frame = 30,
                rotation = 180,
                offline = false,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 200,
            },
        },
    }

    -- Array order: {1, 2} — first element (track 1) wins
    local frame, meta = Renderer.get_video_frame(mock_tmb, {1, 2}, 30)
    assert(frame == "frame_track1", "First element in array should win")
    assert(meta.clip_id == "clip_v1", "Should return track 1's clip_id")
    assert(meta.rotation == 0, "Should return track 1's rotation")

    -- Only track 1 should be queried (short-circuit on first hit)
    assert(#tmb_get_video_calls == 1,
        "Should stop after first track with frame")

    print("  multi-track priority passed")
end

--------------------------------------------------------------------------------
-- Test 6: Multi-track gap on top → falls through to lower track
--------------------------------------------------------------------------------
print("\n--- multi-track fallthrough ---")
do
    reset_mocks()
    -- Track 1: gap at frame 40 (no entry)
    -- Track 2: clip at frame 40
    track_frame_map[2] = {
        [40] = {
            handle = "frame_track2",
            metadata = {
                clip_id = "clip_lower",
                media_path = "/lower.mov",
                source_frame = 40,
                rotation = 0,
                offline = false,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 100,
            },
        },
    }

    local frame, meta = Renderer.get_video_frame(mock_tmb, {1, 2}, 40)
    assert(frame == "frame_track2", "Should fall through to track 2")
    assert(meta.clip_id == "clip_lower", "Should return track 2's clip")

    -- Both tracks queried
    assert(#tmb_get_video_calls == 2,
        "Should query both tracks (track 1 gap, track 2 hit)")

    print("  multi-track fallthrough passed")
end

--------------------------------------------------------------------------------
-- Test 7: Offline on top track takes priority over clip on lower track
--------------------------------------------------------------------------------
print("\n--- offline takes priority over lower track ---")
do
    reset_mocks()
    -- Track 1: offline at frame 50
    track_frame_map[1] = {
        [50] = {
            handle = nil,
            metadata = {
                clip_id = "clip_offline_top",
                media_path = "/missing/top.mov",
                source_frame = 50,
                rotation = 0,
                offline = true,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 100,
            },
        },
    }
    -- Track 2: normal clip at frame 50
    track_frame_map[2] = {
        [50] = {
            handle = "frame_track2",
            metadata = {
                clip_id = "clip_normal",
                media_path = "/normal.mov",
                source_frame = 50,
                rotation = 0,
                offline = false,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 200,
            },
        },
    }

    local frame, meta = Renderer.get_video_frame(mock_tmb, {1, 2}, 50)
    assert(frame ~= nil, "Offline should return composited frame")
    assert(meta.offline == true, "Should return offline metadata from track 1")
    assert(meta.clip_id == "clip_offline_top", "Offline track 1 wins")

    -- Only track 1 queried (offline short-circuits)
    assert(#tmb_get_video_calls == 1,
        "Should stop at offline track (no fallthrough)")

    print("  offline priority passed")
end

--------------------------------------------------------------------------------
-- Test 8: NSF: offline_frame_cache.get_frame returns nil → assert (not silent nil)
--------------------------------------------------------------------------------
print("\n--- NSF: offline cache failure asserts ---")
do
    reset_mocks()

    -- Override offline_frame_cache to return nil (simulating cache failure)
    local ofc = package.loaded["core.media.offline_frame_cache"]
    local orig_get_frame = ofc.get_frame
    ofc.get_frame = function(metadata) return nil end

    track_frame_map[1] = {
        [60] = {
            handle = nil,
            metadata = {
                clip_id = "clip_cache_fail",
                media_path = "/missing/cache_fail.mov",
                source_frame = 60,
                rotation = 0,
                offline = true,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_start_frame = 0, clip_end_frame = 100,
            },
        },
    }

    local ok, err = pcall(function()
        Renderer.get_video_frame(mock_tmb, {1}, 60)
    end)
    assert(not ok, "Should assert when offline_frame_cache.get_frame returns nil")
    assert(tostring(err):find("offline_frame_cache"),
        "Error should mention offline_frame_cache, got: " .. tostring(err))

    ofc.get_frame = orig_get_frame
    print("  offline cache failure asserts passed")
end

--------------------------------------------------------------------------------
-- Test 9: get_sequence_info returns correct info
--------------------------------------------------------------------------------
print("\n--- get_sequence_info ---")
do
    local info = Renderer.get_sequence_info("test_seq")
    assert(info.fps_num == 24, "fps_num=24")
    assert(info.fps_den == 1, "fps_den=1")
    assert(info.width == 1920, "width=1920")
    assert(info.height == 1080, "height=1080")
    assert(info.name == "TestSeq", "name=TestSeq")
    assert(info.kind == "timeline", "kind=timeline")
    assert(info.audio_sample_rate == 48000, "audio_sample_rate=48000")

    print("  get_sequence_info passed")
end

print("\n✅ test_renderer_tmb.lua passed")
