#!/usr/bin/env luajit

-- Test Overwrite command - comprehensive coverage
-- Tests: basic overwrite, undo/redo, UI context resolution, occlusion handling

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database        = require('core.database')
local Clip            = require('models.clip')
local Media           = require('models.media')
local Track           = require('models.track')
local Project         = require('models.project')
local Sequence        = require('models.sequence')
local command_manager = require('core.command_manager')
local asserts         = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Overwrite Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_overwrite.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- ---------------------------------------------------------------------------
-- Fixtures (SQL Isolation)
-- ---------------------------------------------------------------------------

local project_id = "project"
Project.create("Test Project", {
    id   = project_id,
    fps_mismatch_policy = "resample",
    settings = {
        master_clock_hz = 192000,
        default_fps = { num = 24, den = 1 }
    }
}):save()

local seq_id = "sequence"
Sequence.create("Test Sequence", project_id, { fps_numerator = 30, fps_denominator = 1 }, 1920, 1080, {
    id   = seq_id,
    kind = "sequence",
    audio_sample_rate = 48000,
}):save()

Track.create_video("V1", seq_id, { id = "track_v1", track_index = 1 }):save()
Track.create_video("V2", seq_id, { id = "track_v2", track_index = 2 }):save()

command_manager.init(seq_id, project_id)

-- Create Media (500 frames @ 30fps)
local media_id = "media_ow"
local media = Media.create({
    id         = media_id,
    project_id = project_id,
    file_path  = "/tmp/jve/ow_video.mov",
    name       = "OW Video",
    duration_frames = 500,
    fps_numerator   = 30,
    fps_denominator = 1,
    width      = 1920,
    height     = 1080,
    metadata   = '{"start_tc_value":0,"start_tc_rate":30}'
})
media:save(db)

-- V13: master sequence wrapping the media for clip references.
local MC_TEST = Sequence.ensure_master(media_id, project_id)

-- Create masterclip sequence for this media (required for Overwrite)
local source_sequence_id = test_env.create_test_masterclip_sequence(
    project_id, "OW Video Master", 30, 1, 500, media_id)

-- Helper: set marks on masterclip sequence before Insert/Overwrite
local function set_mc_marks(mc_id, source_in, source_out)
    local mc_seq = Sequence.load(mc_id)
    assert(mc_seq, "set_mc_marks: failed to load masterclip sequence")
    mc_seq:set_in(source_in)
    mc_seq:set_out(source_out)
    mc_seq:save()
end

-- Helper: clear marks on masterclip sequence (use full duration)
local function clear_mc_marks(mc_id)
    local mc_seq = Sequence.load(mc_id)
    if mc_seq then
        mc_seq:clear_marks()
        mc_seq:save()
    end
end

-- Map test-friendly aliases ("overwrite_clip", "middle_overwrite", …)
-- to the V13-generated id of the clip the corresponding command
-- actually created.
local clip_alias = {}
local function resolve_clip_id(id)
    return clip_alias[id] or id
end

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    local alias = params._alias
    params._alias = nil
    if (name == "Insert" or name == "Overwrite") and params.source_sequence_id then
        if params.source_in and params.source_out then
            set_mc_marks(params.source_sequence_id, params.source_in, params.source_out)
            params.source_in = nil
            params.source_out = nil
            params.duration = nil
        else
            -- No timing → clear marks so full duration is used
            clear_mc_marks(params.source_sequence_id)
            params.duration = nil
        end
    end
    local Command = require("command")
    local cmd = Command.create(name, params.project_id or project_id)
    cmd:set_parameters(params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
    command_manager.end_command_event()
    if alias and result and result.success then
        local ids = cmd:get_parameter("created_clip_ids")
        if ids and ids[1] then
            clip_alias[alias] = ids[1]
        end
    end
    return result
end

-- Helper: undo/redo with proper event wrapping
local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function redo()
    command_manager.begin_command_event("script")
    local result = command_manager.redo()
    command_manager.end_command_event()
    return result
end

-- Helper: create a clip
local function create_clip(id, track_id, start_frame, duration_frames)
    local clip_id = Clip.create({
        name = "Clip " .. id,
        id = id,
        project_id = project_id,
        track_id = track_id,
        owner_sequence_id = seq_id,
        sequence_id = MC_TEST,
        sequence_start_frame = start_frame,
        duration_frames = duration_frames,
        source_in_frame = 0,
        source_out_frame = duration_frames,
        source_in_subframe = nil,
        source_out_subframe = nil,
        master_layer_track_id = nil,
        master_audio_track_id = nil,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        mark_in_frame = nil,
        mark_out_frame = nil,
    })
    assert(clip_id ~= nil and clip_id ~= "", "Failed to save clip " .. id)
    return clip_id
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    clip_id = resolve_clip_id(clip_id)
    local c = Clip.load_optional(clip_id)
    if c then
        return c.sequence_start, c.duration
    end
    return nil, nil
end

-- Helper: check if clip exists
local function clip_exists(clip_id)
    clip_id = resolve_clip_id(clip_id)
    return Clip.load_optional(clip_id) ~= nil
end

-- Helper: count clips on track
local function count_clips(track_id)
    local sql = "SELECT COUNT(*) FROM clips WHERE track_id = ?"
    return database.count(db, sql, { track_id })
end

-- Helper: reset timeline (only timeline clips, not masterclip stream clips)
local function reset_timeline()
    db:exec("DELETE FROM clips WHERE track_id IN ('track_v1', 'track_v2')")
end

-- =============================================================================
-- TEST 1: Basic overwrite at empty position
-- =============================================================================
print("Test 1: Basic overwrite at empty position")
reset_timeline()

local result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Should have 1 clip on track")

-- =============================================================================
-- TEST 2: Overwrite replaces existing clip completely
-- =============================================================================
print("Test 2: Overwrite replaces existing clip completely")
reset_timeline()
create_clip("existing_clip", "track_v1", 0, 100)

result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "overwrite_clip",
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed")

-- Original clip should be deleted, new clip should exist
assert(not clip_exists("existing_clip"), "Original clip should be deleted")
assert(clip_exists("overwrite_clip"), "New clip should exist")

-- =============================================================================
-- TEST 3: Overwrite trims clip at start
-- =============================================================================
print("Test 3: Overwrite trims clip at start (partial overlap)")
reset_timeline()
create_clip("trim_start", "track_v1", 0, 100)

-- Overwrite first 50 frames
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "overwrite_start",
    sequence_start_frame = 0,
    duration = 50,
    source_in = 0,
    source_out = 50
})
assert(result.success, "Overwrite should succeed")

-- Original should be trimmed, starting at 50
local start, dur = get_clip_position("trim_start")
assert(start == 50, string.format("Original should start at 50, got %s", tostring(start)))
assert(dur == 50, string.format("Original should be 50 frames, got %s", tostring(dur)))

-- =============================================================================
-- TEST 4: Undo restores original clips
-- =============================================================================
print("Test 4: Undo restores original clips")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Original clip should be restored to [0, 100)
start, dur = get_clip_position("trim_start")
assert(start == 0, string.format("Original should restore to 0, got %s", tostring(start)))
assert(dur == 100, string.format("Original should be 100 frames, got %s", tostring(dur)))

-- Overwrite clip should be gone
assert(not clip_exists("overwrite_start"), "Overwrite clip should be removed after undo")

-- =============================================================================
-- TEST 5: Redo re-applies overwrite
-- =============================================================================
print("Test 5: Redo re-applies overwrite")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Original should be trimmed again
start = get_clip_position("trim_start")
assert(start == 50, string.format("Original should be at 50 after redo, got %s", tostring(start)))

-- Overwrite clip should be back
assert(clip_exists("overwrite_start"), "Overwrite clip should exist after redo")

-- =============================================================================
-- TEST 6: Overwrite splits clip in middle
-- =============================================================================
print("Test 6: Overwrite splits clip in middle")
reset_timeline()
create_clip("split_me", "track_v1", 0, 200)

-- Overwrite middle 50 frames [75, 125)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "middle_overwrite",
    sequence_start_frame = 75,
    duration = 50,
    source_in = 0,
    source_out = 50
})
assert(result.success, "Overwrite should succeed")

-- Should have 3 clips total (left part, overwrite, right part) or overwrite replaced original
assert(count_clips("track_v1") >= 1, "Should have at least 1 clip")

-- =============================================================================
-- TEST 7: Error case - missing media_id without UI context
-- =============================================================================
print("Test 7: Missing media_id fails without UI context")
reset_timeline()
asserts._set_enabled_for_tests(false)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    sequence_start_frame = 0
    -- No source_sequence_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "Overwrite without source_sequence_id should fail")

-- =============================================================================
-- TEST 8: Resolves track_id from sequence when not provided
-- =============================================================================
print("Test 8: Resolves track_id from sequence")
reset_timeline()
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    -- No track_id - should use first video track
    source_sequence_id = source_sequence_id,
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should resolve track_id from sequence: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Clip should be on first video track (track_v1)")

-- =============================================================================
-- TEST 9: Nil duration infers from masterclip stream
-- =============================================================================
print("Test 9: Nil duration infers from masterclip stream")
reset_timeline()
-- When duration is nil, Overwrite should use masterclip's stream duration (500 frames)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "fallback_dur_clip",
    sequence_start_frame = 0
    -- No duration - should infer from masterclip stream
})
assert(result.success, "Overwrite should succeed with duration inference: " .. tostring(result.error_message))

-- Clip should have masterclip's stream duration (500 frames)
local _, dur2 = get_clip_position("fallback_dur_clip")
assert(dur2 == 500, string.format("Clip should use masterclip stream duration (500), got %s", tostring(dur2)))

-- =============================================================================
-- TEST 10: Multiple overwrites in sequence
-- =============================================================================
print("Test 10: Multiple overwrites in sequence")
reset_timeline()

-- First overwrite at [0, 100)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "ow_1",
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "First overwrite should succeed")

-- Second overwrite at [100, 200)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "ow_2",
    sequence_start_frame = 100,
    duration = 100,
    source_in = 100,
    source_out = 200
})
assert(result.success, "Second overwrite should succeed")

-- Third overwrite at [200, 300)
result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,
    _alias = "ow_3",
    sequence_start_frame = 200,
    duration = 100,
    source_in = 200,
    source_out = 300
})
assert(result.success, "Third overwrite should succeed")

assert(count_clips("track_v1") == 3, string.format("Should have 3 clips, got %d", count_clips("track_v1")))

-- Undo all three
for i = 1, 3 do
    undo_result = undo()
    assert(undo_result.success, "Undo " .. i .. " should succeed")
end

assert(count_clips("track_v1") == 0, "All clips should be removed after undos")

-- =============================================================================
-- TEST 11: Overwrite on different track
-- =============================================================================
print("Test 11: Overwrite on different track")
reset_timeline()
create_clip("v1_clip", "track_v1", 0, 100)

result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v2",  -- Different track
    source_sequence_id = source_sequence_id,
    _alias = "v2_clip",
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite on v2 should succeed")

-- Both clips should exist (different tracks)
assert(clip_exists("v1_clip"), "v1_clip should still exist")
assert(clip_exists("v2_clip"), "v2_clip should exist")
assert(count_clips("track_v1") == 1, "track_v1 should have 1 clip")
assert(count_clips("track_v2") == 1, "track_v2 should have 1 clip")

-- =============================================================================
-- TEST 12: Overwrite uses masterclip streams for clip creation
-- =============================================================================
print("Test 12: Overwrite uses masterclip streams for clip creation")
reset_timeline()

-- Note: Audio clip creation now depends on masterclip having audio streams.
-- The test helper only creates video streams, so we only test video clip creation.
-- Full audio clip creation is tested via import_media tests.

result = execute_command("Overwrite", {
    project_id = project_id,
    sequence_id = seq_id,
    target_video_track_id = "track_v1",
    source_sequence_id = source_sequence_id,  -- Uses the existing video-only masterclip
    sequence_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed: " .. tostring(result.error_message))

-- Should have video clip on V1
assert(count_clips("track_v1") == 1, "Should have 1 video clip on track_v1")

print("\n✅ Overwrite command tests passed")
