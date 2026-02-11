#!/usr/bin/env luajit

-- Test multi-clip add to timeline (Insert/Overwrite with multiple selected clips)
-- Regression test for multi-select insert functionality

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Media = require('models.media')
local Track = require('models.track')
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Multi-Clip Add to Timeline Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_multi_clip_add.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (24fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a2', 'sequence', 'A2', 'AUDIO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create 3 media items (different durations)
local media1 = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
})
media1:save(db)

local media2 = Media.create({
    id = "media_2",
    project_id = "project",
    file_path = "/tmp/jve/video2.mov",
    name = "Video 2",
    duration_frames = 50,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
})
media2:save(db)

local media3 = Media.create({
    id = "media_3",
    project_id = "project",
    file_path = "/tmp/jve/video3.mov",
    name = "Video 3",
    duration_frames = 75,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
})
media3:save(db)

-- Create masterclip sequences (IS-a refactor: masterclip IS a sequence)
local test_env = require("test_env")
local master_1 = test_env.create_test_masterclip_sequence("project", "Video 1", 24, 1, 100, "media_1")
local master_2 = test_env.create_test_masterclip_sequence("project", "Video 2", 24, 1, 50, "media_2")
local master_3 = test_env.create_test_masterclip_sequence("project", "Video 3", 24, 1, 75, "media_3")

-- Helper: count clips on track
local function count_clips(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ? AND clip_kind != 'master'")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Helper: get clip positions on a track
local function get_clip_positions(track_id)
    local stmt = db:prepare("SELECT id, timeline_start_frame, duration_frames FROM clips WHERE track_id = ? AND clip_kind != 'master' ORDER BY timeline_start_frame")
    stmt:bind_value(1, track_id)
    stmt:exec()
    local clips = {}
    while stmt:next() do
        table.insert(clips, {
            id = stmt:value(0),
            start = stmt:value(1),
            duration = stmt:value(2),
        })
    end
    stmt:finalize()
    return clips
end

-- =============================================================================
-- TEST: Multi-clip insert via AddClipsToSequence (serial arrangement)
-- =============================================================================
print("Test: Multi-clip insert (3 clips, serial arrangement)")

-- Build groups for 3 clips
local groups = {
    {
        master_clip_id = master_1,
        clips = {
            {
                role = "video",
                media_id = "media_1",
                master_clip_id = master_1,
                project_id = "project",
                name = "Video 1",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 24,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 100,
    },
    {
        master_clip_id = master_2,
        clips = {
            {
                role = "video",
                media_id = "media_2",
                master_clip_id = master_2,
                project_id = "project",
                name = "Video 2",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 24,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    },
    {
        master_clip_id = master_3,
        clips = {
            {
                role = "video",
                media_id = "media_3",
                master_clip_id = master_3,
                project_id = "project",
                name = "Video 3",
                source_in = 0,
                source_out = 75,
                duration = 75,
                fps_numerator = 24,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 75,
    },
}

command_manager.begin_command_event("script")
local result = command_manager.execute("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
    arrangement = "serial",
})
command_manager.end_command_event()

assert(result.success, "Multi-clip insert should succeed: " .. tostring(result.error_message))

-- Verify 3 clips on V1
local clip_count = count_clips("track_v1")
assert(clip_count == 3, string.format("Should have 3 clips on V1, got %d", clip_count))

-- Verify positions: [0,100), [100,150), [150,225)
local positions = get_clip_positions("track_v1")
assert(#positions == 3, "Should have 3 position entries")

print(string.format("  Clip 1: start=%d, dur=%d, end=%d", positions[1].start, positions[1].duration, positions[1].start + positions[1].duration))
print(string.format("  Clip 2: start=%d, dur=%d, end=%d", positions[2].start, positions[2].duration, positions[2].start + positions[2].duration))
print(string.format("  Clip 3: start=%d, dur=%d, end=%d", positions[3].start, positions[3].duration, positions[3].start + positions[3].duration))

assert(positions[1].start == 0 and positions[1].duration == 100,
    string.format("Clip 1 should be [0,100), got [%d,%d)", positions[1].start, positions[1].start + positions[1].duration))
assert(positions[2].start == 100 and positions[2].duration == 50,
    string.format("Clip 2 should be [100,150), got [%d,%d)", positions[2].start, positions[2].start + positions[2].duration))
assert(positions[3].start == 150 and positions[3].duration == 75,
    string.format("Clip 3 should be [150,225), got [%d,%d)", positions[3].start, positions[3].start + positions[3].duration))

-- =============================================================================
-- TEST: Undo multi-clip insert
-- =============================================================================
print("\nTest: Undo multi-clip insert")

command_manager.begin_command_event("script")
local undo_result = command_manager.undo()
command_manager.end_command_event()

assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

clip_count = count_clips("track_v1")
assert(clip_count == 0, string.format("Should have 0 clips after undo, got %d", clip_count))

-- =============================================================================
-- TEST: Redo multi-clip insert
-- =============================================================================
print("\nTest: Redo multi-clip insert")

command_manager.begin_command_event("script")
local redo_result = command_manager.redo()
command_manager.end_command_event()

assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

clip_count = count_clips("track_v1")
assert(clip_count == 3, string.format("Should have 3 clips after redo, got %d", clip_count))

-- Verify positions again
positions = get_clip_positions("track_v1")
assert(positions[1].start == 0 and positions[1].duration == 100, "Clip 1 position wrong after redo")
assert(positions[2].start == 100 and positions[2].duration == 50, "Clip 2 position wrong after redo")
assert(positions[3].start == 150 and positions[3].duration == 75, "Clip 3 position wrong after redo")

print("\n✅ test_multi_clip_add_to_timeline.lua passed")
