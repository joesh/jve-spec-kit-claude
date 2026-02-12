#!/usr/bin/env luajit
-- Test timeline_playback.resolve_and_display():
-- - Clip at playhead -> media_cache.activate() + show_frame_at_time calls
-- - Gap at playhead -> show_gap() called
-- - Clip switch detection -> media_cache.activate() called on change, skipped when same

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")

-- Initialize database
local DB_PATH = "/tmp/jve/test_timeline_playback_resolve.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create minimal project/sequence at 24fps
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestSeq', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- V1 track
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Two media files
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/clip_a.mov', 'clip_a', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_b', 'proj', '/test/clip_b.mov', 'clip_b', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Clip A: frames 0-48, source_in=0
-- Clip B: frames 72-120, source_in=10
-- Gap between frames 48-72
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_a', 'proj', 'timeline', 'ClipA', 'v1', 'media_a', 0, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_b', 'proj', 'timeline', 'ClipB', 'v1', 'media_b', 72, 48, 10, 58, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Mock media_cache to track activate() calls
local activate_calls = {}
local mock_media_cache = {
    activate = function(path)
        table.insert(activate_calls, path)
    end,
    set_playhead = function() end,
    is_loaded = function() return true end,
    get_asset_info = function()
        return { fps_num = 24, fps_den = 1, duration_us = 8333333 }
    end,
}
package.loaded["core.media.media_cache"] = mock_media_cache

local timeline_playback = require("core.playback.timeline_playback")
require("core.playback.playback_helpers")

--------------------------------------------------------------------------------
-- Mock viewer_panel: records calls for verification
-- NOTE: viewer_panel no longer has set_source_for_timeline;
-- media_cache.activate() handles source switching directly.
--------------------------------------------------------------------------------
local function make_mock_viewer()
    local calls = {}
    return {
        calls = calls,
        show_frame = function(frame_idx)
            table.insert(calls, {fn = "show_frame", frame_idx = frame_idx})
        end,
        show_frame_at_time = function(source_time_us)
            table.insert(calls, {fn = "show_frame_at_time", source_time_us = source_time_us})
        end,
        show_gap = function()
            table.insert(calls, {fn = "show_gap"})
        end,
        set_rotation = function(degrees)
            table.insert(calls, {fn = "set_rotation", degrees = degrees})
        end,
    }
end

--------------------------------------------------------------------------------
-- Test 1: Clip at playhead -> media_cache.activate() + show_frame_at_time
--------------------------------------------------------------------------------
local function test_clip_at_playhead()
    activate_calls = {}
    local viewer = make_mock_viewer()

    -- Frame 10 is inside clip_a (0-48)
    local new_clip_id = timeline_playback.resolve_and_display(
        24, 1, "seq", nil,
        nil, nil, viewer, nil, 10)

    -- media_cache.activate() should be called for clip switch
    assert(#activate_calls == 1,
        string.format("Expected 1 activate call, got %d", #activate_calls))
    assert(activate_calls[1] == "/test/clip_a.mov",
        "Should activate clip_a media, got " .. tostring(activate_calls[1]))

    -- viewer_panel should get set_rotation + show_frame (in that order on clip switch)
    assert(#viewer.calls == 2,
        string.format("Expected 2 viewer calls (set_rotation, show_frame), got %d", #viewer.calls))
    assert(viewer.calls[1].fn == "set_rotation",
        "First call should be set_rotation, got " .. viewer.calls[1].fn)
    assert(viewer.calls[2].fn == "show_frame",
        "Second call should be show_frame, got " .. viewer.calls[2].fn)

    -- source_frame for frame 10 with source_in=0 = 10
    assert(viewer.calls[2].frame_idx == 10,
        string.format("source_frame: expected 10, got %s", tostring(viewer.calls[2].frame_idx)))

    -- Returned clip id should track current clip
    assert(new_clip_id == "clip_a",
        "new_clip_id should be clip_a, got " .. tostring(new_clip_id))

    print("  test_clip_at_playhead passed")
end

--------------------------------------------------------------------------------
-- Test 2: Gap at playhead -> show_gap()
--------------------------------------------------------------------------------
local function test_gap_at_playhead()
    activate_calls = {}
    local viewer = make_mock_viewer()

    -- Frame 60 is in the gap (clip_a ends at 48, clip_b starts at 72)
    local new_clip_id = timeline_playback.resolve_and_display(
        24, 1, "seq", "clip_a",
        nil, nil, viewer, nil, 60)

    -- No activate calls for gap
    assert(#activate_calls == 0,
        string.format("Expected 0 activate calls for gap, got %d", #activate_calls))

    assert(#viewer.calls == 1,
        string.format("Expected 1 call (show_gap), got %d", #viewer.calls))
    assert(viewer.calls[1].fn == "show_gap",
        "Call should be show_gap, got " .. viewer.calls[1].fn)

    -- returned clip id should be nil for gap
    assert(new_clip_id == nil,
        "new_clip_id should be nil after gap, got " .. tostring(new_clip_id))

    print("  test_gap_at_playhead passed")
end

--------------------------------------------------------------------------------
-- Test 3: Same clip -> no activate, only show_frame_at_time
--------------------------------------------------------------------------------
local function test_same_clip_skips_source_switch()
    activate_calls = {}
    local viewer = make_mock_viewer()

    -- Frame 20 is still in clip_a (0-48)
    local new_clip_id = timeline_playback.resolve_and_display(
        24, 1, "seq", "clip_a",
        nil, nil, viewer, nil, 20)

    -- No activate call when same clip
    assert(#activate_calls == 0,
        string.format("Expected 0 activate calls (same clip), got %d", #activate_calls))

    assert(#viewer.calls == 1,
        string.format("Expected 1 call (show_frame only, no source switch), got %d", #viewer.calls))
    assert(viewer.calls[1].fn == "show_frame",
        "Call should be show_frame, got " .. viewer.calls[1].fn)

    assert(new_clip_id == "clip_a", "should remain clip_a")

    print("  test_same_clip_skips_source_switch passed")
end

--------------------------------------------------------------------------------
-- Test 4: Clip switch -> media_cache.activate() called for new clip
--------------------------------------------------------------------------------
local function test_clip_switch_triggers_source_change()
    activate_calls = {}
    local viewer = make_mock_viewer()

    -- Frame 80 is in clip_b (72-120, source_in=10)
    local new_clip_id = timeline_playback.resolve_and_display(
        24, 1, "seq", "clip_a",
        nil, nil, viewer, nil, 80)

    -- activate() should be called for new clip
    assert(#activate_calls == 1,
        string.format("Expected 1 activate call, got %d", #activate_calls))
    assert(activate_calls[1] == "/test/clip_b.mov",
        "Should activate clip_b media, got " .. tostring(activate_calls[1]))

    assert(#viewer.calls == 2,
        string.format("Expected 2 viewer calls (set_rotation, show_frame), got %d", #viewer.calls))

    -- source_frame for frame 80: offset = 80-72 = 8, source_in=10 → source_frame=18
    assert(viewer.calls[2].frame_idx == 18,
        string.format("source_frame: expected 18, got %s", tostring(viewer.calls[2].frame_idx)))

    assert(new_clip_id == "clip_b",
        "new_clip_id should be clip_b, got " .. tostring(new_clip_id))

    print("  test_clip_switch_triggers_source_change passed")
end

-- Run all tests
test_clip_at_playhead()
test_gap_at_playhead()
test_same_clip_skips_source_switch()
test_clip_switch_triggers_source_change()

print("  test_timeline_playback_resolve.lua passed")
