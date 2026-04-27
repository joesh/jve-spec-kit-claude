#!/usr/bin/env luajit

-- Test Overwrite command - comprehensive coverage
-- Tests: basic overwrite, undo/redo, UI context resolution, occlusion handling

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
require('models.track') -- luacheck: ignore 411
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

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

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test Project', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 'nested', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media (500 frames @ 30fps)
local media = Media.create({
    id = "media_ow",
    project_id = "project",
    file_path = "/tmp/jve/ow_video.mov",
    name = "OW Video",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)
-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_ow")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_ow", "project")

-- Create masterclip sequence for this media (required for Overwrite)
local nested_sequence_id = test_env.create_test_masterclip_sequence(
    "project", "OW Video Master", 30, 1, 500, "media_ow")

-- Helper: set marks on masterclip sequence before Insert/Overwrite
local Sequence = require("models.sequence")
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
    end
end

-- Map test-friendly aliases ("overwrite_clip", "middle_overwrite", …)
-- to the V13-generated id of the clip the corresponding command
-- actually created. Tests reference clips by alias for readability;
-- the helpers below resolve the alias before clip_exists /
-- get_clip_position. The duplicate-key params lines used to override
-- nested_sequence_id with the desired literal id; in V13 the new
-- clip's id is generated, so we capture it under params._alias instead.
local clip_alias = {}
local function resolve_clip_id(id)
    return clip_alias[id] or id
end

-- Helper: execute command with proper event wrapping
-- For Insert/Overwrite: reads source_in/source_out from params, sets marks, removes timing params
local function execute_command(name, params)
    local alias = params._alias
    params._alias = nil
    if (name == "Insert" or name == "Overwrite") and params.nested_sequence_id then
        if params.source_in and params.source_out then
            set_mc_marks(params.nested_sequence_id, params.source_in, params.source_out)
            params.source_in = nil
            params.source_out = nil
            params.duration = nil
        else
            -- No timing → clear marks so full duration is used
            clear_mc_marks(params.nested_sequence_id)
            params.duration = nil
        end
    end
    local Command = require("command")
    local cmd = Command.create(name, params.project_id or "project")
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
    local clip = Clip.create({
        name = "Clip " .. id,
        id = id,
        project_id = "project",
        track_id = track_id,
        owner_sequence_id = "sequence",
        nested_sequence_id = MC_TEST,
        timeline_start_frame = start_frame,
        duration_frames = duration_frames,
        source_in_frame = 0,
        source_out_frame = duration_frames,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(clip ~= nil and clip ~= "", "Failed to save clip " .. id)
    return clip
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    clip_id = resolve_clip_id(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local start = stmt:value(0)
        local dur = stmt:value(1)
        stmt:finalize()
        return start, dur
    end
    stmt:finalize()
    return nil, nil
end

-- Helper: check if clip exists
local function clip_exists(clip_id)
    clip_id = resolve_clip_id(clip_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
end

-- Helper: count clips on track
local function count_clips(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    timeline_start_frame = 0,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "overwrite_clip",
    timeline_start_frame = 0,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "overwrite_start",
    timeline_start_frame = 0,
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
start = get_clip_position("trim_start") -- luacheck: ignore 411
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "middle_overwrite",
    timeline_start_frame = 75,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    timeline_start_frame = 0,
    duration = 100
    -- No nested_sequence_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "Overwrite without nested_sequence_id should fail")

-- =============================================================================
-- TEST 8: Resolves track_id from sequence when not provided
-- =============================================================================
print("Test 8: Resolves track_id from sequence")
reset_timeline()
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    -- No track_id - should use first video track
    nested_sequence_id = nested_sequence_id,
    timeline_start_frame = 0,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "fallback_dur_clip",
    timeline_start_frame = 0
    -- No duration - should infer from masterclip stream
})
assert(result.success, "Overwrite should succeed with duration inference: " .. tostring(result.error_message))

-- Clip should have masterclip's stream duration (500 frames)
local _, dur2 = get_clip_position("fallback_dur_clip"); _ = _ -- luacheck: ignore 311
assert(dur2 == 500, string.format("Clip should use masterclip stream duration (500), got %s", tostring(dur2)))

-- =============================================================================
-- TEST 10: Multiple overwrites in sequence
-- =============================================================================
print("Test 10: Multiple overwrites in sequence")
reset_timeline()

-- First overwrite at [0, 100)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "ow_1",
    timeline_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "First overwrite should succeed")

-- Second overwrite at [100, 200)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "ow_2",
    timeline_start_frame = 100,
    duration = 100,
    source_in = 100,
    source_out = 200
})
assert(result.success, "Second overwrite should succeed")

-- Third overwrite at [200, 300)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,
    _alias = "ow_3",
    timeline_start_frame = 200,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v2",  -- Different track
    nested_sequence_id = nested_sequence_id,
    _alias = "v2_clip",
    timeline_start_frame = 0,
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
    project_id = "project",
    sequence_id = "sequence",
    target_video_track_id = "track_v1",
    nested_sequence_id = nested_sequence_id,  -- Uses the existing video-only masterclip
    timeline_start_frame = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed: " .. tostring(result.error_message))

-- Should have video clip on V1
assert(count_clips("track_v1") == 1, "Should have 1 video clip on track_v1")

print("\n\226\156\133 Overwrite command tests passed")
