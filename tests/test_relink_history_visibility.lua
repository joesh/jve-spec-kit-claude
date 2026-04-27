#!/usr/bin/env luajit
--- RelinkClips history visibility under auto-promotion.
--
-- Production trigger is `ShowRelinkDialog` (spec.undoable = false), which
-- calls `command_manager.execute("RelinkClips", ...)` from inside its
-- executor. The command_manager's nested-dispatch logic is supposed to
-- promote that call to a top-level recorded command so it appears in the
-- history panel and on the undo stack.
--
-- `test_relink_clips_undo.lua` dispatches RelinkClips directly at depth=1,
-- which bypasses the promotion path entirely. This test exercises the
-- promotion path by invoking RelinkClips from inside a non-recording
-- wrapper command, and asserts the command is visible in the history.
require("test_env")

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_history_visibility.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")

local TEST_DB = "/tmp/jve/test_relink_history_visibility.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-visibility"
local seq_id = uuid.generate()
local track_id = uuid.generate()
local media_id = "media-orig"
local clip_id_1 = uuid.generate()
local clip_id_2 = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Relink Visibility Project', 'resample', %d, %d, '{}');

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Seq', 'nested', 25, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('%s', '%s', 'A026_C007.mov', '/offline/A026_C007.mov', 1000, 25, 1,
        1920, 1080, 0, 'prores', %d, %d, '{"start_tc_value":89750,"start_tc_rate":25}');
]], project_id, now, now,
    seq_id, project_id, now, now,
    track_id, seq_id,
    media_id, project_id, now, now))

local _Sequence = require("models.sequence")
local master_seq_id = _Sequence.ensure_master(media_id, project_id)

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume)
    VALUES ('%s', '%s', 'Clip1', '%s', '%s', '%s', 0, 100, 100, 200, 1, 0, %d, %d, NULL, NULL, 'resample', 1.0);
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume)
    VALUES ('%s', '%s', 'Clip2', '%s', '%s', '%s', 100, 50, 300, 350, 1, 0, %d, %d, NULL, NULL, 'resample', 1.0);
]], clip_id_1, project_id, track_id, master_seq_id, seq_id, now, now,
    clip_id_2, project_id, track_id, master_seq_id, seq_id, now, now))

command_manager.init(seq_id, project_id)

local Clip = require("models.clip")
local Media = require("models.media")

---------------------------------------------------------------------------------
-- Register a throwaway non-recording wrapper that invokes RelinkClips from
-- within its executor. Mirrors the ShowRelinkDialog → RelinkClips shape
-- without needing a real Qt dialog.
---------------------------------------------------------------------------------
local wrapper_plan  -- supplied per test invocation

local WRAPPER_SPEC = {
    args = { project_id = { required = true } },
    undoable = false,
}

command_manager.register_executor("TestRelinkWrapper", function(_command)
    assert(wrapper_plan, "TestRelinkWrapper: wrapper_plan not set")
    local nested = command_manager.execute("RelinkClips", wrapper_plan)
    assert(nested.success, "nested RelinkClips failed: " .. tostring(nested.error_message))
    return { success = true }
end, nil, WRAPPER_SPEC)

---------------------------------------------------------------------------------
-- Test 1: Wrapper (non-recording) → RelinkClips should land in history.
---------------------------------------------------------------------------------
print("\n--- Test 1: RelinkClips appears in history when invoked via non-recording wrapper ---")
do
    wrapper_plan = {
        project_id = project_id,
        clip_relink_map = {
            [clip_id_1] = { new_source_in = 75, new_source_out = 175 },
            [clip_id_2] = { new_source_in = 275, new_source_out = 325 },
        },
        media_path_changes = { [media_id] = "/new/A026_C007.mov" },
    }

    local wrapper_cmd = Command.create("TestRelinkWrapper", project_id)
    wrapper_cmd:set_parameter("project_id", project_id)
    local result = command_manager.execute(wrapper_cmd)
    assert(result.success, "wrapper should succeed: " .. tostring(result.error_message))

    -- Confirm the relink actually applied (rules out a no-op).
    local c1 = Clip.load(clip_id_1)
    assert(c1.source_in == 75 and c1.source_out == 175,
        string.format("expected relinked source range 75..175, got %d..%d", c1.source_in, c1.source_out))

    -- History visibility: RelinkClips must appear as a user-undoable entry.
    local entries = command_manager:list_history_entries()
    local relink_entry
    for _, entry in ipairs(entries) do
        if entry.command_type == "RelinkClips" then
            relink_entry = entry
            break
        end
    end
    assert(relink_entry,
        string.format("RelinkClips entry missing from history panel (got %d entries: %s)",
            #entries, (function()
                local types = {}
                for _, e in ipairs(entries) do types[#types + 1] = tostring(e.command_type) end
                return table.concat(types, ", ")
            end)()))
    assert(relink_entry.sequence_number and relink_entry.sequence_number > 0,
        string.format("RelinkClips entry has invalid sequence_number: %s",
            tostring(relink_entry.sequence_number)))
    assert(relink_entry.label and relink_entry.label ~= "",
        "RelinkClips entry has empty label")

    -- Wrapper itself is non-recording — it must NOT appear.
    for _, entry in ipairs(entries) do
        assert(entry.command_type ~= "TestRelinkWrapper",
            "non-recording wrapper should not appear in history")
    end

    print("  ✓ RelinkClips visible in history with valid sequence_number + label")
    print("  ✓ non-recording wrapper itself is not in history")
end

---------------------------------------------------------------------------------
-- Test 2: undo() walks the wrapper-promoted RelinkClips.
---------------------------------------------------------------------------------
print("\n--- Test 2: undo() unwinds wrapper-promoted RelinkClips ---")
do
    local undo_result = command_manager.undo()
    assert(undo_result.success,
        "undo should succeed after wrapper-invoked RelinkClips: " .. tostring(undo_result.error_message))

    local c1 = Clip.load(clip_id_1)
    assert(c1.source_in == 100 and c1.source_out == 200,
        string.format("undo should restore source range to 100..200, got %d..%d", c1.source_in, c1.source_out))
    local m = Media.load(media_id)
    assert(m:get_file_path() == "/offline/A026_C007.mov",
        "undo should restore media path, got: " .. m:get_file_path())

    print("  ✓ undo restored clip source ranges and media path")
end

---------------------------------------------------------------------------------
-- Test 3: A second wrapper→RelinkClips also records (no silent dedupe).
---------------------------------------------------------------------------------
print("\n--- Test 3: Second wrapper-invoked RelinkClips also appears in history ---")
do
    -- First, redo the one we just undid, so we build on top of it.
    local redo_result = command_manager.redo()
    assert(redo_result.success, "redo should succeed: " .. tostring(redo_result.error_message))

    wrapper_plan = {
        project_id = project_id,
        clip_relink_map = {
            [clip_id_1] = { new_source_in = 60, new_source_out = 160 },
        },
        media_path_changes = {},
    }
    local wrapper_cmd = Command.create("TestRelinkWrapper", project_id)
    wrapper_cmd:set_parameter("project_id", project_id)
    local result = command_manager.execute(wrapper_cmd)
    assert(result.success, "second wrapper should succeed: " .. tostring(result.error_message))

    local entries = command_manager:list_history_entries()
    local relink_count = 0
    for _, entry in ipairs(entries) do
        if entry.command_type == "RelinkClips" then
            relink_count = relink_count + 1
        end
    end
    assert(relink_count == 2,
        string.format("expected 2 RelinkClips entries in history, got %d", relink_count))

    print("  ✓ two wrapper-invoked RelinkClips both visible in history")
end

print("\n✅ test_relink_history_visibility.lua passed")
