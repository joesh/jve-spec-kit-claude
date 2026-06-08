#!/usr/bin/env luajit

-- Test AddClipsToSequence command - THE algorithm for timeline edits
-- Tests: serial/stacked arrangement, insert/overwrite edit types, cross-track carving, linking

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database        = require('core.database')
local Clip            = require('models.clip')
local Media           = require('models.media')
local Track           = require('models.track')
local Project         = require('models.project')
local Sequence        = require('models.sequence')
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== AddClipsToSequence Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_add_clips_to_sequence.db"
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

-- Create Media (500 frames @ 30fps)
local media_id = "media_1"
Media.create({
    id         = media_id,
    project_id = project_id,
    file_path  = "/tmp/jve/video1.mov",
    name       = "Video 1",
    duration_frames = 500,
    fps_numerator   = 30,
    fps_denominator = 1,
    width      = 1920,
    height     = 1080,
    audio_channels  = 2,
    audio_sample_rate = 48000,
    metadata   = '{"start_tc_value":0,"start_tc_rate":30,"start_tc_audio_samples":0,"start_tc_audio_rate":48000}'
}):save()

-- V13: master sequence wrapping the media for clip references.
local MC_TEST = Sequence.ensure_master(media_id, project_id)

local seq_id = "sequence"
Sequence.create("Test Sequence", project_id, { fps_numerator = 30, fps_denominator = 1 }, 1920, 1080, {
    id   = seq_id,
    kind = "sequence",
    audio_sample_rate = 48000,
}):save()

Track.create_video("V1", seq_id, { id = "track_v1", track_index = 1 }):save()
Track.create_video("V2", seq_id, { id = "track_v2", track_index = 2 }):save()
Track.create_audio("A1", seq_id, { id = "track_a1", track_index = 1 }):save()
Track.create_audio("A2", seq_id, { id = "track_a2", track_index = 2 }):save()

command_manager.init(seq_id, project_id)

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
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

-- Helper: count clips on track
local function count_clips(track_id)
    local sql = "SELECT COUNT(*) FROM clips WHERE track_id = ?"
    return database.count(db, sql, { track_id })
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    local c = Clip.load_optional(clip_id)
    if c then
        return c.sequence_start, c.duration
    end
    return nil, nil
end

-- Helper: reset timeline.
local function reset_timeline()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM clip_links")
    local timeline_state = require("ui.timeline.timeline_state")
    if timeline_state.reload_clips then
        timeline_state.reload_clips(seq_id)
    end
end

-- Helper: create existing clip
local function create_clip(id, track_id, start_frame, duration_frames)
    local track = Track.load(track_id)
    assert(track, "create_clip: track not found: " .. tostring(track_id))
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type(track.track_type)
    
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
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
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
    
    local timeline_state = require("ui.timeline.timeline_state")
    if timeline_state.reload_clips then
        timeline_state.reload_clips(seq_id)
    end
    return clip_id
end

-- =============================================================================
-- TEST 1: Basic insert at empty timeline
-- =============================================================================
print("Test 1: Basic insert at empty timeline")
reset_timeline()

local groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Test Clip",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 100,
    }
}

local result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "insert",
    arrangement = "serial",
})
assert(result.success, "AddClipsToSequence should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Should have 1 clip on V1")

-- =============================================================================
-- TEST 2: Insert ripples existing clips
-- =============================================================================
print("Test 2: Insert ripples existing clips")
reset_timeline()
create_clip("existing", "track_v1", 0, 100)  -- Clip at [0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Inserted",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,  -- Insert at start
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "insert",
})
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 2, "Should have 2 clips on V1")

-- Existing clip should be pushed to frame 50
local start, dur = get_clip_position("existing")
assert(start == 50, string.format("Existing clip should be at 50, got %s", tostring(start)))
assert(dur == 100, "Existing clip should still be 100 frames")

-- =============================================================================
-- TEST 3: Overwrite does NOT ripple
-- =============================================================================
print("Test 3: Overwrite does not ripple")
reset_timeline()
create_clip("existing2", "track_v1", 0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Overwritten",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "overwrite",
})
assert(result.success, "Overwrite should succeed")

-- Existing clip should be trimmed, not pushed
start, dur = get_clip_position("existing2")
assert(start == 50, string.format("Existing should start at 50 after trim, got %s", tostring(start)))
assert(dur == 50, string.format("Existing should be 50 frames after trim, got %s", tostring(dur)))

-- =============================================================================
-- TEST 4: Serial arrangement places groups back-to-back
-- =============================================================================
print("Test 4: Serial arrangement")
reset_timeline()

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Clip A",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 100,
    },
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Clip B",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "insert",
    arrangement = "serial",
})
assert(result.success, "Serial insert should succeed")
assert(count_clips("track_v1") == 2, "Should have 2 clips on V1")

-- Verify positions: Clip A at 0, Clip B at 100
local stmt = db:prepare("SELECT sequence_start_frame FROM clips WHERE track_id = 'track_v1' ORDER BY sequence_start_frame")
stmt:exec()
local positions = {}
while stmt:next() do
    table.insert(positions, stmt:value(0))
end
stmt:finalize()
assert(positions[1] == 0, string.format("First clip should be at 0, got %s", tostring(positions[1])))
assert(positions[2] == 100, string.format("Second clip should be at 100, got %s", tostring(positions[2])))

-- =============================================================================
-- TEST 5: Video + audio group creates linked clips
-- =============================================================================
print("Test 5: Video + audio creates linked clips")
reset_timeline()

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "AV Clip",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            },
            {
                role = "audio",
                channel = 0,
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "AV Clip (Audio)",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_a1",
            }
        },
        duration = 100,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "insert",
})
assert(result.success, "AV insert should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Should have 1 clip on V1")
assert(count_clips("track_a1") == 1, "Should have 1 clip on A1")

-- Check clips are linked
local link_stmt = db:prepare("SELECT COUNT(*) FROM clip_links")
link_stmt:exec()
link_stmt:next()
local link_count = link_stmt:value(0)
link_stmt:finalize()
assert(link_count == 2, string.format("Should have 2 link entries, got %d", link_count))

-- =============================================================================
-- TEST 6: Undo reverses entire operation
-- =============================================================================
print("Test 6: Undo reverses entire operation")
-- Continuing from test 5
local undo_result = undo()
assert(undo_result.success, "Undo should succeed")
assert(count_clips("track_v1") == 0, "V1 should be empty after undo")
assert(count_clips("track_a1") == 0, "A1 should be empty after undo")

-- Links should be gone
local link_stmt2 = db:prepare("SELECT COUNT(*) FROM clip_links")
link_stmt2:exec()
link_stmt2:next()
link_count = link_stmt2:value(0)
link_stmt2:finalize()
assert(link_count == 0, "Links should be removed after undo")

-- =============================================================================
-- TEST 7: Redo restores clips and links
-- =============================================================================
print("Test 7: Redo restores clips and links")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed")
assert(count_clips("track_v1") == 1, "V1 should have clip after redo")
assert(count_clips("track_a1") == 1, "A1 should have clip after redo")

-- =============================================================================
-- TEST 8: Insert ripples ALL tracks (cross-track)
-- =============================================================================
print("Test 8: Insert ripples ALL tracks (cross-track)")
reset_timeline()
create_clip("v1_clip", "track_v1", 0, 100)
create_clip("v2_clip", "track_v2", 0, 100)
create_clip("a1_clip", "track_a1", 0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = media_id, sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = project_id,
                name = "Inserted",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = seq_id,
    project_id = project_id,
    edit_type = "insert",
})
assert(result.success, "Cross-track insert should succeed")

-- ALL existing clips should be rippled to 50
local v1_start, _ = get_clip_position("v1_clip")
assert(v1_start == 50, string.format("V1 clip should be at 50, got %s", tostring(v1_start)))

local v2_start, _ = get_clip_position("v2_clip")
assert(v2_start == 50, string.format("V2 clip should be at 50 (cross-track ripple), got %s", tostring(v2_start)))

local a1_start, _ = get_clip_position("a1_clip")
assert(a1_start == 50, string.format("A1 clip should be at 50 (cross-track ripple), got %s", tostring(a1_start)))

print("\n✅ AddClipsToSequence command tests passed")
