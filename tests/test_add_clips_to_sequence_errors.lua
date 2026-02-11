#!/usr/bin/env luajit
-- Error path tests for AddClipsToSequence command
-- NSF: Every assert in production code needs a test proving it fires

require("test_env")

local database = require('core.database')
local command_manager = require('core.command_manager')
local Media = require('models.media')

print("=== AddClipsToSequence Error Path Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_add_clips_errors.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence
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
]])

command_manager.init('sequence', 'project')

-- Create media and masterclip
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
})
media:save(db)

local test_env = require("test_env")
local master_1 = test_env.create_test_masterclip_sequence("project", "Master 1", 24, 1, 100, "media_1")

--------------------------------------------------------------------------------
-- Test: Missing groups parameter (caught by schema validation)
--------------------------------------------------------------------------------
print("Test: AddClipsToSequence with nil groups asserts")
local ok, err = pcall(function()
    command_manager.begin_command_event("test")
    command_manager.execute("AddClipsToSequence", {
        groups = nil,
        position = 0,
        sequence_id = "sequence",
        project_id = "project",
        edit_type = "insert",
    })
    command_manager.end_command_event()
end)
assert(not ok, "Should throw on nil groups")
assert(err:match("groups"), "Error should mention groups, got: " .. tostring(err))
print("  ✓ Asserts on nil groups")

--------------------------------------------------------------------------------
-- Test: Empty groups array
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with empty groups asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with empty groups")
assert(result.error_message:match("groups must not be empty"),
    "Error should mention groups empty, got: " .. tostring(result.error_message))
print("  ✓ Asserts on empty groups")

--------------------------------------------------------------------------------
-- Test: Missing sequence_id (caught by schema validation)
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with nil sequence_id asserts")
local ok2, err2 = pcall(function()
    command_manager.begin_command_event("test")
    command_manager.execute("AddClipsToSequence", {
        groups = {{duration = 50, clips = {{
            role = "video", media_id = "media_1", master_clip_id = master_1,
            project_id = "project", name = "Clip", source_in = 0, source_out = 50,
            duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
        }}}},
        position = 0,
        sequence_id = nil,
        project_id = "project",
        edit_type = "insert",
    })
    command_manager.end_command_event()
end)
assert(not ok2, "Should throw on nil sequence_id")
assert(err2:match("sequence_id"), "Error should mention sequence_id, got: " .. tostring(err2))
print("  ✓ Asserts on nil sequence_id")

--------------------------------------------------------------------------------
-- Test: Missing edit_type (caught by schema validation)
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with nil edit_type asserts")
local ok3, err3 = pcall(function()
    command_manager.begin_command_event("test")
    command_manager.execute("AddClipsToSequence", {
        groups = {{duration = 50, clips = {{
            role = "video", media_id = "media_1", master_clip_id = master_1,
            project_id = "project", name = "Clip", source_in = 0, source_out = 50,
            duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
        }}}},
        position = 0,
        sequence_id = "sequence",
        project_id = "project",
        edit_type = nil,
    })
    command_manager.end_command_event()
end)
assert(not ok3, "Should throw on nil edit_type")
assert(err3:match("edit_type"), "Error should mention edit_type, got: " .. tostring(err3))
print("  ✓ Asserts on nil edit_type")

--------------------------------------------------------------------------------
-- Test: Invalid edit_type
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with invalid edit_type asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = 50, clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = 0, source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
    }}}},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "invalid",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with invalid edit_type")
assert(result.error_message:match("edit_type must be insert or overwrite"),
    "Error should mention valid edit_types, got: " .. tostring(result.error_message))
print("  ✓ Asserts on invalid edit_type")

--------------------------------------------------------------------------------
-- Test: Invalid arrangement
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with invalid arrangement asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = 50, clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = 0, source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
    }}}},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
    arrangement = "invalid",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with invalid arrangement")
assert(result.error_message:match("arrangement must be serial or stacked"),
    "Error should mention valid arrangements, got: " .. tostring(result.error_message))
print("  ✓ Asserts on invalid arrangement")

--------------------------------------------------------------------------------
-- Test: Non-integer position
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with non-integer position asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = 50, clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = 0, source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
    }}}},
    position = "not_a_number",
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with non-integer position")
assert(result.error_message:match("position must be integer"),
    "Error should mention position type, got: " .. tostring(result.error_message))
print("  ✓ Asserts on non-integer position")

--------------------------------------------------------------------------------
-- Test: Clip missing target_track_id
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with clip missing target_track_id asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = 50, clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = 0, source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1,
        -- target_track_id = nil (missing)
    }}}},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with missing target_track_id")
assert(result.error_message:match("target_track_id"),
    "Error should mention target_track_id, got: " .. tostring(result.error_message))
print("  ✓ Asserts on missing target_track_id")

--------------------------------------------------------------------------------
-- Test: Non-integer group.duration
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with non-integer group.duration asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = "fifty", clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = 0, source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
    }}}},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with non-integer group.duration")
assert(result.error_message:match("group.duration must be integer"),
    "Error should mention group.duration type, got: " .. tostring(result.error_message))
print("  ✓ Asserts on non-integer group.duration")

--------------------------------------------------------------------------------
-- Test: Non-integer clip.source_in
--------------------------------------------------------------------------------
print("\nTest: AddClipsToSequence with non-integer clip.source_in asserts")
command_manager.begin_command_event("test")
result = command_manager.execute("AddClipsToSequence", {
    groups = {{duration = 50, clips = {{
        role = "video", media_id = "media_1", master_clip_id = master_1,
        project_id = "project", name = "Clip", source_in = "zero", source_out = 50,
        duration = 50, fps_numerator = 24, fps_denominator = 1, target_track_id = "track_v1"
    }}}},
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
command_manager.end_command_event()
assert(not result.success, "Should fail with non-integer source_in")
assert(result.error_message:match("source_in must be integer"),
    "Error should mention source_in type, got: " .. tostring(result.error_message))
print("  ✓ Asserts on non-integer source_in")

print("\n✅ test_add_clips_to_sequence_errors.lua passed")
