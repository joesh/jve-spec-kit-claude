#!/usr/bin/env luajit

-- Regression test: Undo mutations must include fps info when source bounds are present
--
-- Bug: When Overwrite trimmed a clip and undo tried to restore it, the UI cache
-- update failed with "clip_state: missing clip rate" because the update mutation
-- had source_in_value/source_out_value but no fps_numerator/fps_denominator.
--
-- Fix: Update mutations now include fps info, and clip_state.apply_mutations
-- applies fps to the clip before using it for source bounds.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local Rational = require("core.rational")
local command_helper = require("core.command_helper")

local SCHEMA_SQL = require("import_schema")

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('seq1', 'default_project', 'Sequence', 'timeline',
            30, 1, 48000, 1920, 1080, 0, 300, 0, '[]', '[]', '[]', 0,
            strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('media1', 'default_project', '/tmp/test.mov', 'Test Media', 3000, 30, 1, strftime('%s','now'), strftime('%s','now'));

    -- Clip that will be trimmed by Overwrite
    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id,
        owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled,
        created_at, modified_at
    ) VALUES
        ('clip1', 'default_project', 'timeline', 'Clip 1', 'v1', 'media1', 'seq1',
         0, 200, 0, 200, 30, 1, 1, strftime('%s','now'), strftime('%s','now'));
]]

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))
    command_manager.init("seq1", "default_project")
    return db
end

local db = setup_database("/tmp/jve/test_undo_mutations_fps.db")

-- Helper: execute command with proper event wrapping
local function execute_command(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
    command_manager.end_command_event()
    return result
end

local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

print("=== Undo Mutations FPS Regression Test ===")
print("This test ensures undo mutations include fps info for source bounds\n")

-- Intercept mutations
local captured_undo_mutations = nil
local original_revert_mutations = command_helper.revert_mutations

command_helper.revert_mutations = function(db, mutations, command, sequence_id)
    local ok, err = original_revert_mutations(db, mutations, command, sequence_id)
    if ok and command then
        captured_undo_mutations = command:get_parameter("__timeline_mutations")
    end
    return ok, err
end

-- Execute overwrite that will trim clip1 (overlap at position 100)
-- This creates an UPDATE mutation for clip1's new bounds
local overwrite_cmd = Command.create("Overwrite", "default_project")
overwrite_cmd:set_parameter("sequence_id", "seq1")
overwrite_cmd:set_parameter("track_id", "v1")
overwrite_cmd:set_parameter("media_id", "media1")
overwrite_cmd:set_parameter("overwrite_time", Rational.new(100, 30, 1))  -- Start at frame 100
overwrite_cmd:set_parameter("duration", Rational.new(50, 30, 1))         -- 50 frames
overwrite_cmd:set_parameter("source_in", Rational.new(500, 30, 1))       -- Different source range
overwrite_cmd:set_parameter("source_out", Rational.new(550, 30, 1))

print("Step 1: Execute overwrite that trims existing clip...")
local result = execute_command(overwrite_cmd)
assert(result.success, result.error_message or "Overwrite failed")

-- Verify clip1 was trimmed (duration reduced from 200 to 100)
local stmt = db:prepare("SELECT duration_frames FROM clips WHERE id = 'clip1'")
assert(stmt and stmt:exec() and stmt:next())
local trimmed_duration = stmt:value(0)
stmt:finalize()
assert(trimmed_duration == 100, string.format(
    "Expected clip1 to be trimmed to 100 frames, got %d", trimmed_duration))
print(string.format("  Clip1 trimmed to %d frames", trimmed_duration))

-- Now undo
print("\nStep 2: Undo the overwrite operation...")
result = undo()
assert(result.success, result.error_message or "Undo failed")

-- Restore original function
command_helper.revert_mutations = original_revert_mutations

-- Verify undo mutations include fps info
assert(captured_undo_mutations, "Should have captured undo mutations")

print("\nStep 3: Verify undo mutations include fps info for source bounds...")
local found_update_with_fps = false

for seq_id, bucket in pairs(captured_undo_mutations) do
    if bucket.updates then
        for i, mut in ipairs(bucket.updates) do
            if mut.source_in_value or mut.source_out_value then
                -- THIS IS THE KEY TEST: fps info must be present when source bounds are present
                assert(mut.fps_numerator, string.format(
                    "Undo update mutation %d: has source_in_value but missing fps_numerator. " ..
                    "This will cause 'clip_state: missing clip rate' error!",
                    i))
                assert(mut.fps_denominator, string.format(
                    "Undo update mutation %d: has source_in_value but missing fps_denominator",
                    i))

                print(string.format("  Mutation for clip %s:", mut.clip_id))
                print(string.format("    source_in_value=%s, source_out_value=%s",
                    tostring(mut.source_in_value), tostring(mut.source_out_value)))
                print(string.format("    fps_numerator=%s, fps_denominator=%s",
                    tostring(mut.fps_numerator), tostring(mut.fps_denominator)))

                found_update_with_fps = true
            end
        end
    end
end

assert(found_update_with_fps, "Should have at least one update mutation with source bounds and fps")

-- Verify clip1 was restored to original state
stmt = db:prepare("SELECT duration_frames, source_in_frame, source_out_frame FROM clips WHERE id = 'clip1'")
assert(stmt and stmt:exec() and stmt:next())
local restored_duration = stmt:value(0)
local restored_source_in = stmt:value(1)
local restored_source_out = stmt:value(2)
stmt:finalize()

assert(restored_duration == 200, string.format(
    "Expected clip1 restored to 200 frames, got %d", restored_duration))
assert(restored_source_in == 0, string.format(
    "Expected source_in restored to 0, got %d", restored_source_in))
assert(restored_source_out == 200, string.format(
    "Expected source_out restored to 200, got %d", restored_source_out))

print(string.format("\nStep 4: Verified clip1 restored: duration=%d, source_in=%d, source_out=%d",
    restored_duration, restored_source_in, restored_source_out))

print("\n" .. string.rep("=", 80))
print("REGRESSION TEST PASSED")
print(string.rep("=", 80))
print("Bug prevention: Undo mutations now include fps_numerator/fps_denominator")
print("when source_in_value/source_out_value are present.")
print("This prevents 'clip_state: missing clip rate' errors during UI cache updates.")
print(string.rep("=", 80))
