#!/usr/bin/env luajit

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

    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id,
        owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled,
        created_at, modified_at
    ) VALUES
        ('clip1', 'default_project', 'timeline', 'Clip 1', 'v1', 'media1', 'seq1',
         0, 100, 0, 100, 30, 1, 1, strftime('%s','now'), strftime('%s','now'));
]]

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))
    command_manager.init(db, "seq1", "default_project")
    return db
end

local db = setup_database("/tmp/jve/test_undo_mutations_regression.db")

print("=== Undo Mutations Regression Test ===")
print("This test ensures undo mutations include full clip state for UI cache updates\n")

-- Intercept the mutations by wrapping the revert_mutations function
local captured_undo_mutations = nil
local original_revert_mutations = command_helper.revert_mutations

command_helper.revert_mutations = function(db, mutations, command, sequence_id)
    -- Call the original function
    local ok, err = original_revert_mutations(db, mutations, command, sequence_id)

    -- Capture the mutations that were added to the command
    if ok and command then
        captured_undo_mutations = command:get_parameter("__timeline_mutations")
    end

    return ok, err
end

-- Execute an overwrite operation (has mutation population code)
local overwrite_cmd = Command.create("Overwrite", "default_project")
overwrite_cmd:set_parameter("sequence_id", "seq1")
overwrite_cmd:set_parameter("track_id", "v1")
overwrite_cmd:set_parameter("media_id", "media1")
overwrite_cmd:set_parameter("overwrite_time", Rational.new(50, 30, 1))
overwrite_cmd:set_parameter("duration", Rational.new(100, 30, 1))
overwrite_cmd:set_parameter("source_in", Rational.new(0, 30, 1))
overwrite_cmd:set_parameter("source_out", Rational.new(100, 30, 1))

print("Step 1: Execute overwrite operation...")
local result = command_manager.execute(overwrite_cmd)
assert(result.success, result.error_message or "Overwrite failed")

-- Get the mutations from execute
local execute_mutations = overwrite_cmd:get_parameter("__timeline_mutations")
assert(execute_mutations, "Execute should produce timeline mutations")

-- Now undo the operation
print("\nStep 2: Undo the overwrite operation...")
result = command_manager.undo()
assert(result.success, result.error_message or "Undo failed")

-- Restore the original function
command_helper.revert_mutations = original_revert_mutations

-- Verify we captured undo mutations
assert(captured_undo_mutations, "Should have captured undo mutations")
print("✓ Successfully captured undo mutations during revert_mutations call")

-- Verify undo mutations include full state (THIS IS THE KEY TEST)
print("\nStep 3: Verify undo mutations include full clip state (THE REGRESSION TEST)...")
local mutation_count = 0

for seq_id, bucket in pairs(captured_undo_mutations) do
    print(string.format("Checking mutations for sequence: %s", seq_id))

    if bucket.updates then
        for i, mut in ipairs(bucket.updates) do
            mutation_count = mutation_count + 1
            assert(mut.clip_id, string.format("Undo update mutation %d: missing clip_id", i))

            -- THIS IS THE BUG WE'RE CATCHING: undo used to only have {clip_id = "..."}
            -- Now it must include full state for UI cache updates
            assert(mut.start_value, string.format(
                "Undo update mutation %d: missing start_value for clip %s. " ..
                "Undo mutations MUST include full clip state for UI cache updates!",
                i, mut.clip_id))
            assert(mut.duration_value, string.format(
                "Undo update mutation %d: missing duration_value for clip %s",
                i, mut.clip_id))
            assert(mut.track_id, string.format(
                "Undo update mutation %d: missing track_id for clip %s",
                i, mut.clip_id))

            print(string.format("  ✓ Undo update %d: clip_id=%s, start=%s, dur=%s, track=%s",
                i, mut.clip_id, mut.start_value, mut.duration_value, mut.track_id))
        end
    end

    if bucket.inserts then
        for i, mut in ipairs(bucket.inserts) do
            mutation_count = mutation_count + 1
            assert(mut.id, string.format("Undo insert mutation %d: missing id", i))

            -- Undo delete (which becomes insert) must also include full state
            assert(mut.start_value, string.format(
                "Undo insert mutation %d: missing start_value for clip %s. " ..
                "Undo delete mutations MUST include full clip state for UI cache inserts!",
                i, mut.id))
            assert(mut.duration_value, string.format(
                "Undo insert mutation %d: missing duration_value for clip %s",
                i, mut.id))
            assert(mut.track_id, string.format(
                "Undo insert mutation %d: missing track_id for clip %s",
                i, mut.id))

            print(string.format("  ✓ Undo insert %d: id=%s, start=%s, dur=%s, track=%s",
                i, mut.id, mut.start_value, mut.duration_value, mut.track_id))
        end
    end

    if bucket.deletes then
        for i, clip_id in ipairs(bucket.deletes) do
            mutation_count = mutation_count + 1
            print(string.format("  ✓ Undo delete %d: clip_id=%s", i, clip_id))
        end
    end
end

assert(mutation_count > 0, "Undo should have produced at least one mutation")

print("\n" .. string.rep("=", 80))
print("✅ REGRESSION TEST PASSED")
print(string.rep("=", 80))
print(string.format("Verified %d undo mutations all include full clip state", mutation_count))
print("Bug prevention: Undo mutations now include start_value, duration_value, track_id")
print("This ensures UI cache updates correctly without requiring timeline reload")
print(string.rep("=", 80))
