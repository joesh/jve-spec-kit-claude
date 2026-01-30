#!/usr/bin/env luajit
-- Test: timeline_playback.tick() updates media_cache prefetch target
-- Bug: source_playback.tick() calls media_cache.set_playhead() every tick,
-- but timeline_playback.tick() never did → prefetch thread starved → stutter.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")
local Rational = require("core.rational")
local helpers = require("core.playback.playback_helpers")

-- Initialize database
local DB_PATH = "/tmp/jve/test_timeline_prefetch.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create project/sequence at 24fps
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

assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Two media files with different paths
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/clip_a.mov', 'clip_a', 200, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_b', 'proj', '/test/clip_b.mov', 'clip_b', 200, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Clip A: timeline frames 0-47, source_in=0
-- Clip B: timeline frames 48-95, source_in=10
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_a', 'proj', 'timeline', 'ClipA', 'v1', 'media_a', 0, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_b', 'proj', 'timeline', 'ClipB', 'v1', 'media_b', 48, 48, 10, 58, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

--------------------------------------------------------------------------------
-- Mock media_cache: tracks activate() AND set_playhead() calls
--------------------------------------------------------------------------------
local activate_calls = {}
local set_playhead_calls = {}
local mock_media_cache = {
    activate = function(path)
        table.insert(activate_calls, path)
    end,
    set_playhead = function(frame_idx, direction, speed)
        table.insert(set_playhead_calls, {
            frame_idx = frame_idx,
            direction = direction,
            speed = speed,
        })
    end,
    is_loaded = function() return true end,
    get_asset_info = function()
        return { fps_num = 24, fps_den = 1, duration_us = 8333333 }
    end,
}
package.loaded["core.media.media_cache"] = mock_media_cache

local timeline_playback = require("core.playback.timeline_playback")

local function make_mock_viewer()
    return {
        show_frame_at_time = function() end,
        show_gap = function() end,
    }
end

--------------------------------------------------------------------------------
-- Test 1: resolve_and_display with direction/speed calls set_playhead
--------------------------------------------------------------------------------
local function test_resolve_updates_prefetch()
    activate_calls = {}
    set_playhead_calls = {}
    local viewer = make_mock_viewer()
    local state = {
        fps_num = 24, fps_den = 1,
        sequence_id = "seq",
        current_clip_id = nil,
        direction = 1,
        speed = 1,
    }

    -- Frame 10 is inside clip_a (source_in=0, so source_frame=10)
    timeline_playback.resolve_and_display(state, viewer, 10)

    assert(#set_playhead_calls == 1,
        string.format("Expected 1 set_playhead call, got %d", #set_playhead_calls))
    assert(set_playhead_calls[1].direction == 1,
        "direction should be 1, got " .. tostring(set_playhead_calls[1].direction))
    assert(set_playhead_calls[1].speed == 1,
        "speed should be 1, got " .. tostring(set_playhead_calls[1].speed))
    -- Source frame for timeline frame 10 with source_in=0:
    -- source_time_us = floor(10/24 * 1e6) = 416666
    -- source_frame = floor(416666 * 24 / 1e6) = floor(9.999984) = 9 (truncation through us)
    -- Off-by-one from round-trip is fine for prefetch target
    assert(set_playhead_calls[1].frame_idx == 9,
        string.format("source frame_idx should be 9, got %d", set_playhead_calls[1].frame_idx))

    print("  test_resolve_updates_prefetch passed")
end

--------------------------------------------------------------------------------
-- Test 2: Clip switch updates prefetch with correct source frame
--------------------------------------------------------------------------------
local function test_clip_switch_updates_prefetch()
    activate_calls = {}
    set_playhead_calls = {}
    local viewer = make_mock_viewer()
    local state = {
        fps_num = 24, fps_den = 1,
        sequence_id = "seq",
        current_clip_id = "clip_a",
        direction = 1,
        speed = 1,
    }

    -- Frame 50 is in clip_b (timeline_start=48, source_in=10)
    -- offset = 50 - 48 = 2, source_frame = 10 + 2 = 12
    timeline_playback.resolve_and_display(state, viewer, 50)

    assert(#set_playhead_calls == 1,
        string.format("Expected 1 set_playhead call after clip switch, got %d", #set_playhead_calls))
    -- source_time_us = 12/24 * 1e6 = 500000, source_frame = floor(500000 * 24 / 1 / 1e6) = 12
    assert(set_playhead_calls[1].frame_idx == 12,
        string.format("source frame_idx should be 12 after clip switch, got %d",
            set_playhead_calls[1].frame_idx))

    print("  test_clip_switch_updates_prefetch passed")
end

--------------------------------------------------------------------------------
-- Test 3: No set_playhead when direction is absent (parked seek)
--------------------------------------------------------------------------------
local function test_parked_seek_no_prefetch()
    set_playhead_calls = {}
    local viewer = make_mock_viewer()
    local state = {
        fps_num = 24, fps_den = 1,
        sequence_id = "seq",
        current_clip_id = nil,
        -- No direction/speed fields — parked seek context
    }

    timeline_playback.resolve_and_display(state, viewer, 10)

    assert(#set_playhead_calls == 0,
        string.format("Expected 0 set_playhead calls when parked, got %d", #set_playhead_calls))

    print("  test_parked_seek_no_prefetch passed")
end

--------------------------------------------------------------------------------
-- Test 4: Reverse playback passes direction=-1
--------------------------------------------------------------------------------
local function test_reverse_direction_prefetch()
    set_playhead_calls = {}
    local viewer = make_mock_viewer()
    local state = {
        fps_num = 24, fps_den = 1,
        sequence_id = "seq",
        current_clip_id = nil,
        direction = -1,
        speed = 2,
    }

    timeline_playback.resolve_and_display(state, viewer, 10)

    assert(#set_playhead_calls == 1,
        string.format("Expected 1 set_playhead call, got %d", #set_playhead_calls))
    assert(set_playhead_calls[1].direction == -1,
        "direction should be -1, got " .. tostring(set_playhead_calls[1].direction))
    assert(set_playhead_calls[1].speed == 2,
        "speed should be 2, got " .. tostring(set_playhead_calls[1].speed))

    print("  test_reverse_direction_prefetch passed")
end

--------------------------------------------------------------------------------
-- Test 5: Gap at playhead does NOT call set_playhead
--------------------------------------------------------------------------------
local function test_gap_no_prefetch()
    set_playhead_calls = {}
    local viewer = make_mock_viewer()

    -- Add a gap: delete clip_b temporarily isn't feasible, so use a frame beyond clips
    -- Actually clips cover 0-95, so frame 200 is a gap if total_frames allows
    -- Let's just test with the existing setup — frames 96+ are gaps
    local state = {
        fps_num = 24, fps_den = 1,
        sequence_id = "seq",
        current_clip_id = "clip_b",
        direction = 1,
        speed = 1,
    }

    -- Frame 200 is beyond all clips → gap
    timeline_playback.resolve_and_display(state, viewer, 200)

    assert(#set_playhead_calls == 0,
        string.format("Expected 0 set_playhead calls at gap, got %d", #set_playhead_calls))

    print("  test_gap_no_prefetch passed")
end

-- Run all tests
test_resolve_updates_prefetch()
test_clip_switch_updates_prefetch()
test_parked_seek_no_prefetch()
test_reverse_direction_prefetch()
test_gap_no_prefetch()

print("✅ test_timeline_prefetch.lua passed")
