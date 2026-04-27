#!/usr/bin/env luajit

-- Regression: B6 — Insert/Overwrite must use source viewer in/out marks
-- when they are set, not the full media source_in/source_out range.
--
-- Source viewer marks are resolved in gather_context_for_command.lua's
-- resolve_clip_marks, which checks if the source monitor is showing
-- the clip and uses its marks if set.

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== B6: Insert respects source viewer marks ===")

-- Stub logger
package.loaded["core.logger"] = {
    info = function() end, debug = function() end,
    warn = function() end, error = function() end,
    trace = function() end,
    for_area = function() return { event = function() end, detail = function() end, warn = function() end, error = function() end } end,
}

-- Marks now live on the masterclip sequence object (not the source viewer).
-- No source viewer mock needed.

-- Pre-load mocks BEFORE gather_context requires them
package.loaded["core.utils.track_resolver"] = {
    resolve_video_track = function() return {id = "track_v1"} end,
    resolve_audio_track = function() return {id = "track_a1"} end,
}
package.loaded["core.utils.clip_media"] = {
    has_video = function() return true end,
    audio_channel_count = function() return 0 end,
}

-- Master clip with full source range (0-100)
local master_clip = {
    clip_id = "master_1",
    id = "master_1",
    project_id = "proj1",
    name = "TestMedia",
    media_id = "media_1",
    source_in = 0,
    source_out = 100,
    duration = 100,
    frame_rate = {fps_numerator = 24, fps_denominator = 1},
}

local media = {
    id = "media_1",
    duration = 100,
    frame_rate = {fps_numerator = 24, fps_denominator = 1},
}

-- Load gather_context (the module being tested)
local gather_context = require("core.gather_context_for_command")

-- We can't call gather_edit_context directly (needs timeline_state etc.)
-- but we can test the source viewer mark resolution via gather_single_clip_context
-- with a mock timeline_state, or test the exported behavior via a mock.

-- For this test, we use gather_edit_context with a mock timeline_state
local mock_timeline_state = {
    get_sequence_id = function() return "seq1" end,
    get_project_id = function() return "proj1" end,
    get_playhead_position = function() return 0 end,
}

-- Mock sequence load (gather_context loads sequence to get FPS)
local Sequence = require("models.sequence")
local _orig_load = Sequence.load
Sequence.load = function(id)
    if id == "seq1" then
        return {
            id = "seq1",
            frame_rate = {fps_numerator = 24, fps_denominator = 1},
        }
    end
    return _orig_load(id)
end

-- ─── Test 1: Sequence marks applied → group uses mark range ───
print("\n--- insert with source marks → uses marks ---")
do
    -- Marks live on the masterclip (sequence marks, set by I/O keys)
    master_clip.mark_in = 10
    master_clip.mark_out = 50

    local result = gather_context.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = mock_timeline_state,
        media_map = {["media_1"] = media},
    })

    assert(result.groups and #result.groups == 1, "should build 1 group")
    local clip = result.groups[1].clips[1]
    check("source_in = mark_in (10)", clip.source_in == 10)
    check("source_out = mark_out (50)", clip.source_out == 50)
    check("duration = 40", clip.duration == 40)
end

-- ─── Test 2: No marks → uses clip's original range ───
print("\n--- no marks → uses original range ---")
do
    master_clip.mark_in = nil
    master_clip.mark_out = nil

    local result = gather_context.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = mock_timeline_state,
        media_map = {["media_1"] = media},
    })

    local clip = result.groups[1].clips[1]
    check("source_in = original (0)", clip.source_in == 0)
    check("source_out = original (100)", clip.source_out == 100)
    check("duration = 100", clip.duration == 100)
end

-- ─── Test 3: No marks on clip → uses original range (regardless of viewer) ───
print("\n--- no marks on clip → original range ---")
do
    master_clip.mark_in = nil
    master_clip.mark_out = nil

    local result = gather_context.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = mock_timeline_state,
        media_map = {["media_1"] = media},
    })

    local clip = result.groups[1].clips[1]
    check("different viewer → source_in = original (0)", clip.source_in == 0)
    check("different viewer → source_out = original (100)", clip.source_out == 100)
end

-- ─── Test 4: Master clip source range not mutated by gather_context ───
print("\n--- gather_context doesn't mutate master_clip ---")
do
    master_clip.mark_in = 10
    master_clip.mark_out = 50

    gather_context.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = mock_timeline_state,
        media_map = {["media_1"] = media},
    })

    check("master_clip.source_in unchanged (0)", master_clip.source_in == 0)
    check("master_clip.source_out unchanged (100)", master_clip.source_out == 100)
end

-- Restore
Sequence.load = _orig_load

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_insert_respects_source_marks.lua passed")
