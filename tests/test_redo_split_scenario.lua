#!/usr/bin/env luajit

-- Test redo bug: insert that splits a clip, then undo/redo/undo
-- Reproduces user-reported issue

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Redo Split Scenario Bug Test ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_redo_split.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
})
media:save(db)

-- Helper functions
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

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

local function get_all_clips()
    local stmt = db:prepare("SELECT id, timeline_start_frame, duration_frames FROM clips WHERE track_id = 'track_v1' ORDER BY timeline_start_frame")
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

local function print_timeline(label)
    local clips = get_all_clips()
    print(string.format("  [%s] %d clips:", label, #clips))
    for _, c in ipairs(clips) do
        print(string.format("    - %s: start=%d dur=%d end=%d", c.id, c.start, c.duration, c.start + c.duration))
    end
end

-- =============================================================================
-- STEP 1: Insert first clip (100 frames at position 0)
-- =============================================================================
print("STEP 1: Insert first clip [0, 100)")
local result = execute_command("AddClipsToSequence", {
    groups = {
        {
            clips = {
                {
                    role = "video",
                    media_id = "media_1",
                    project_id = "project",
                    name = "Original",
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
    },
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
assert(result.success, "Step 1 failed: " .. tostring(result.error_message))
print_timeline("after step 1")

local clips_after_step1 = get_all_clips()
assert(#clips_after_step1 == 1, "Should have 1 clip after step 1")
local original_clip_id = clips_after_step1[1].id

-- =============================================================================
-- STEP 2: Insert second clip at frame 50 (splits original)
-- =============================================================================
print("\nSTEP 2: Insert at frame 50 (splits original into [0,50) and [100,150))")
result = execute_command("AddClipsToSequence", {
    groups = {
        {
            clips = {
                {
                    role = "video",
                    media_id = "media_1",
                    project_id = "project",
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
    },
    position = 50,  -- Middle of original clip
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
assert(result.success, "Step 2 failed: " .. tostring(result.error_message))
print_timeline("after step 2")

local clips_after_step2 = get_all_clips()
assert(#clips_after_step2 == 3, string.format("Should have 3 clips after split, got %d", #clips_after_step2))

-- Expected: [0,50) original left, [50,100) inserted, [100,150) original right
assert(clips_after_step2[1].start == 0 and clips_after_step2[1].duration == 50,
    string.format("First clip should be [0,50), got [%d,%d)",
        clips_after_step2[1].start, clips_after_step2[1].start + clips_after_step2[1].duration))
assert(clips_after_step2[2].start == 50 and clips_after_step2[2].duration == 50,
    string.format("Second clip should be [50,100), got [%d,%d)",
        clips_after_step2[2].start, clips_after_step2[2].start + clips_after_step2[2].duration))
assert(clips_after_step2[3].start == 100 and clips_after_step2[3].duration == 50,
    string.format("Third clip should be [100,150), got [%d,%d)",
        clips_after_step2[3].start, clips_after_step2[3].start + clips_after_step2[3].duration))

-- =============================================================================
-- STEP 3: Undo step 2
-- =============================================================================
print("\nSTEP 3: Undo (should restore original [0,100))")
local undo_result = undo()
assert(undo_result.success, "Undo 1 failed: " .. tostring(undo_result.error_message))
print_timeline("after undo 1")

local clips_after_undo1 = get_all_clips()
assert(#clips_after_undo1 == 1, string.format("Should have 1 clip after undo, got %d", #clips_after_undo1))
assert(clips_after_undo1[1].start == 0 and clips_after_undo1[1].duration == 100,
    string.format("Clip should be [0,100) after undo, got [%d,%d)",
        clips_after_undo1[1].start, clips_after_undo1[1].start + clips_after_undo1[1].duration))

-- =============================================================================
-- STEP 4: Redo step 2
-- =============================================================================
print("\nSTEP 4: Redo (should re-split into 3 clips)")
local redo_result = redo()
assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))
print_timeline("after redo")

local clips_after_redo = get_all_clips()
assert(#clips_after_redo == 3, string.format("Should have 3 clips after redo, got %d", #clips_after_redo))

-- Verify same positions as after step 2
assert(clips_after_redo[1].start == 0 and clips_after_redo[1].duration == 50,
    string.format("First clip after redo should be [0,50), got [%d,%d)",
        clips_after_redo[1].start, clips_after_redo[1].start + clips_after_redo[1].duration))
assert(clips_after_redo[2].start == 50 and clips_after_redo[2].duration == 50,
    string.format("Second clip after redo should be [50,100), got [%d,%d)",
        clips_after_redo[2].start, clips_after_redo[2].start + clips_after_redo[2].duration))
assert(clips_after_redo[3].start == 100 and clips_after_redo[3].duration == 50,
    string.format("Third clip after redo should be [100,150), got [%d,%d)",
        clips_after_redo[3].start, clips_after_redo[3].start + clips_after_redo[3].duration))

-- =============================================================================
-- STEP 5: Undo again
-- =============================================================================
print("\nSTEP 5: Undo again (should restore original [0,100))")
undo_result = undo()
assert(undo_result.success, "Undo 2 failed: " .. tostring(undo_result.error_message))
print_timeline("after undo 2")

local clips_after_undo2 = get_all_clips()
assert(#clips_after_undo2 == 1, string.format("Should have 1 clip after second undo, got %d", #clips_after_undo2))
assert(clips_after_undo2[1].start == 0 and clips_after_undo2[1].duration == 100,
    string.format("Clip should be [0,100) after second undo, got [%d,%d)",
        clips_after_undo2[1].start, clips_after_undo2[1].start + clips_after_undo2[1].duration))

print("\n✅ test_redo_split_scenario.lua passed")
