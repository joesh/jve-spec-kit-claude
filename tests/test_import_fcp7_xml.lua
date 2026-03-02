#!/usr/bin/env luajit

-- Test FCP7 XML import: execute, undo, redo, replay, post-import editing
-- Verifies: import creates entities, MatchFrame works, mutations flow, undo/redo idempotent, replay from scratch
-- Uses REAL timeline_state — no mock.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

-- Mock project_browser to capture focus_master_clip calls (Qt boundary)
local focus_calls = {}
local project_browser = {
    focused_master_clip_id = nil,
    focus_calls_count = 0,
}

function project_browser.refresh() end

function project_browser.focus_master_clip(master_clip_id, _opts)
    project_browser.focused_master_clip_id = master_clip_id
    project_browser.focus_calls_count = project_browser.focus_calls_count + 1
    table.insert(focus_calls, {master_id = master_clip_id})
    return true
end

function project_browser.get_selected_master_clip()
    return nil
end

function project_browser.focus_bin() end

package.loaded['ui.project_browser'] = project_browser

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local json = require("dkjson")
local sqlite3 = require("core.sqlite3")
local fcp7_importer = require("importers.fcp7_xml_importer")
local timeline_state = require('ui.timeline.timeline_state')
local Signals = require('core.signals')

local TEST_DB = "/tmp/jve/test_import_fcp7_xml.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

local function bootstrap_schema(conn)
    assert(conn, "bootstrap_schema requires a database connection")
    assert(conn:exec(require('import_schema')), "Failed to create schema tables")
    assert(conn:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            mark_in_frame, mark_out_frame,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number,
            created_at, modified_at
        )
        VALUES (
            'default_sequence', 'default_project', 'Default Sequence', 'timeline',
            30, 1, 48000,
            1920, 1080,
            0, 240, 0,
            NULL, NULL,
            '[]', '[]', '[]',
            0,
            strftime('%s','now'), strftime('%s','now')
        );

        INSERT OR IGNORE INTO tag_namespaces(id, display_name)
        VALUES('bin', 'Bins');
    ]]), "Failed to seed default project/sequence")
end

database.init(TEST_DB)
local db = database.get_connection()
bootstrap_schema(db)

command_manager.init('default_sequence', 'default_project')
local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)

-- Signal-based mutation tracking (replaces mock instrumentation)
local mutation_log = {}
local mutation_conn = Signals.connect("timeline_mutations_applied", function(mutations, changed)
    table.insert(mutation_log, {mutations = mutations, changed = changed})
end)

local function reset_mutation_tracking()
    mutation_log = {}
end

local function last_mutations()
    if #mutation_log == 0 then return nil end
    return mutation_log[#mutation_log].mutations
end

local function count_rows(table_name)
    local stmt = db:prepare("SELECT COUNT(*) FROM " .. table_name)
    assert(stmt:exec() and stmt:next())
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

local function fetch_commands()
    local stmt = db:prepare([[SELECT sequence_number, parent_sequence_number, command_type FROM commands ORDER BY sequence_number]])
    assert(stmt:exec())
    local commands = {}
    while stmt:next() do
        table.insert(commands, {
            sequence_number = stmt:value(0),
            parent_sequence_number = stmt:value(1),
            command_type = stmt:value(2)
        })
    end
    stmt:finalize()
    return commands
end

local function fetch_clip_ids(limit)
    local ids = {}
    local stmt = db:prepare("SELECT id FROM clips WHERE clip_kind = 'timeline' ORDER BY timeline_start_frame DESC")
    assert(stmt:exec())
    while stmt:next() do
        table.insert(ids, stmt:value(0))
        if limit and #ids >= limit then break end
    end
    stmt:finalize()
    return ids
end

local initial_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

local xml_path_relative = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"
local function resolve_fixture(path)
    local absolute = test_env.resolve_repo_path(path)
    local handle = io.open(absolute, "r")
    if handle then
        handle:close()
        return absolute
    end
    local fallback = absolute .. ".real"
    handle = io.open(fallback, "r")
    if handle then
        handle:close()
        return fallback
    end
    error("Unable to locate fixture at " .. absolute .. " (or .real)")
end

-- ============================================================
-- Execute Import
-- ============================================================
local xml_path = resolve_fixture(xml_path_relative)
local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("xml_path", xml_path)
import_cmd:set_parameter("project_id", "default_project")

local execute_result = command_manager.execute(import_cmd)
assert(execute_result.success, "Import command should succeed")

local after_import_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_import_counts.sequences > initial_counts.sequences, "Import should add sequences")
assert(after_import_counts.tracks > initial_counts.tracks, "Import should add tracks")
assert(after_import_counts.clips > initial_counts.clips, "Import should add clips")
assert(after_import_counts.media >= initial_counts.media, "Import should add or reuse media")

-- ============================================================
-- Master clips + bins
-- ============================================================
local master_count_stmt = db:prepare([[SELECT COUNT(*) FROM clips WHERE clip_kind = 'master']])
assert(master_count_stmt:exec() and master_count_stmt:next(), "Master clip count query should succeed")
local master_clip_count = master_count_stmt:value(0)
master_count_stmt:finalize()
assert(master_clip_count > 0, "Import should create master clips for MatchFrame")

local expected_master_bin_name = "Timeline 1 (Resolve) Master Clips"
local master_bin_id = nil
for _, bin in ipairs(database.load_bins("default_project")) do
    if bin.name == expected_master_bin_name then
        master_bin_id = bin.id
        break
    end
end
assert(master_bin_id, "Importer should create a '<sequence name> Master Clips' bin")

local sample_master_stmt = db:prepare([[SELECT id FROM clips WHERE clip_kind = 'master' ORDER BY id LIMIT 1]])
assert(sample_master_stmt:exec() and sample_master_stmt:next(), "Should fetch at least one master clip")
sample_master_stmt:finalize()
local media_bin_map = database.load_master_clip_bin_map("default_project")
local assigned_count = 0
for _, bin_ids in pairs(media_bin_map) do
    for _, bid in ipairs(bin_ids) do
        if bid == master_bin_id then
            assigned_count = assigned_count + 1
            break
        end
    end
end
assert(assigned_count == master_clip_count,
    string.format("Expected %d master clips assigned to %s, got %d",
        master_clip_count, expected_master_bin_name, assigned_count))

-- ============================================================
-- Anamnesis fixture: track types (scratch DB, isolated)
-- ============================================================
local anamnesis_fixture = "tests/fixtures/resolve/2025-07-08-anamnesis-PICTURE-LOCK-TWO more comps.xml"
local anamnesis_path = resolve_fixture(anamnesis_fixture)
local scratch_db_path = "/tmp/jve/test_import_fcp7_xml_anamnesis.db"
os.remove(scratch_db_path)
local scratch_db = sqlite3.open(scratch_db_path)
assert(scratch_db, "Failed to open scratch database copy")
bootstrap_schema(scratch_db)

-- Temporarily swap the global connection to the scratch database
local original_connection = database.get_connection()
database.set_connection(scratch_db)

local parsed_anamnesis = fcp7_importer.import_xml(anamnesis_path, "default_project")
assert(parsed_anamnesis.success, parsed_anamnesis.errors and parsed_anamnesis.errors[1] or "Anamnesis fixture parsing failed")
local anamnesis_entities = fcp7_importer.create_entities(parsed_anamnesis, scratch_db, "default_project")
assert(anamnesis_entities.success, anamnesis_entities.error or "Anamnesis fixture entity creation failed")

-- Restore the original connection before cleanup
database.set_connection(original_connection)

local invalid_track_stmt = scratch_db:prepare([[
    SELECT COUNT(*) FROM tracks
    WHERE track_type IS NULL OR track_type NOT IN ('AUDIO', 'VIDEO')
]])
assert(invalid_track_stmt:exec() and invalid_track_stmt:next(), "Track type validation query should succeed")
local invalid_track_count = invalid_track_stmt:value(0)
invalid_track_stmt:finalize()
assert(invalid_track_count == 0, "All imported tracks must have explicit AUDIO/VIDEO track_type values")
scratch_db:close()
os.remove(scratch_db_path)

-- ============================================================
-- MatchFrame on imported clips (real timeline_state)
-- ============================================================
-- Find an imported timeline clip with a master_clip_id
local timeline_master_stmt = db:prepare([[SELECT c.id, c.master_clip_id, c.timeline_start_frame
    FROM clips c WHERE c.clip_kind = 'timeline' AND c.master_clip_id IS NOT NULL LIMIT 1]])
assert(timeline_master_stmt:exec(), "Timeline clip master query should run")
local timeline_clip_id, timeline_master_id, tl_start = nil, nil, nil
if timeline_master_stmt:next() then
    timeline_clip_id = timeline_master_stmt:value(0)
    timeline_master_id = timeline_master_stmt:value(1)
    tl_start = timeline_master_stmt:value(2)
end
timeline_master_stmt:finalize()
assert(timeline_clip_id and timeline_master_id, "Importer should assign master_clip_id for timeline clips")

-- Get the imported sequence and switch real timeline_state to it
local import_record = command_manager.get_last_command('default_project')
assert(import_record, "Import command should exist")
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

timeline_state.init(imported_sequence_id, "default_project")
command_manager.activate_timeline_stack(imported_sequence_id)

-- MatchFrame: set playhead inside the clip
timeline_state.set_playhead_position(tl_start + 1)

local match_cmd = Command.create("MatchFrame", "default_project")
local match_result = command_manager.execute(match_cmd)
assert(match_result.success, "MatchFrame should succeed on imported clips: " .. tostring(match_result.error_message))
assert(project_browser.focused_master_clip_id == timeline_master_id,
    "MatchFrame should focus the master clip")

-- ============================================================
-- Nudge applies mutations (signal-observed)
-- ============================================================
local clip_ids = fetch_clip_ids(1)
assert(#clip_ids > 0, "Import should create clips to nudge")

reset_mutation_tracking()

local nudge_cmd = Command.create("Nudge", "default_project")
nudge_cmd:set_parameter("nudge_amount", 30)
nudge_cmd:set_parameter("selected_clip_ids", { clip_ids[1] })

local nudge_result = command_manager.execute(nudge_cmd)
assert(nudge_result.success, "Nudge command should succeed after import")
assert(nudge_cmd:get_parameter("sequence_id"), "Nudge should capture the active sequence for timeline cache updates")
assert(#mutation_log >= 1, "Nudge should emit timeline mutations")
assert(last_mutations(), "Nudge should apply timeline mutations with real changes")
reset_mutation_tracking()

-- ============================================================
-- ToggleClipEnabled applies mutations + undo/redo
-- ============================================================
local toggle_cmd = Command.create("ToggleClipEnabled", "default_project")
toggle_cmd:set_parameter("clip_ids", { clip_ids[1] })
local pre_toggle_count = #mutation_log
local toggle_result = command_manager.execute(toggle_cmd)
assert(toggle_result.success, "ToggleClipEnabled should succeed on imported clip")
assert(#mutation_log > pre_toggle_count, "ToggleClipEnabled should apply timeline mutations")
local toggle_update = last_mutations() and last_mutations().updates and last_mutations().updates[1]
assert(toggle_update and toggle_update.enabled ~= nil, "ToggleClipEnabled updates must include enabled state")
reset_mutation_tracking()

local undo_toggle = command_manager.undo()
assert(undo_toggle.success, "Undo ToggleClipEnabled should succeed")
assert(#mutation_log >= 1, "Undo ToggleClipEnabled should emit timeline mutations")
reset_mutation_tracking()
local redo_toggle = command_manager.redo()
assert(redo_toggle.success, "Redo ToggleClipEnabled should succeed")
assert(#mutation_log >= 1, "Redo ToggleClipEnabled should emit timeline mutations")
reset_mutation_tracking()

-- ============================================================
-- Command log structure
-- ============================================================
local commands_after_toggle = fetch_commands()
assert(#commands_after_toggle >= 3, "Command log should contain import, nudge, and toggle commands")
local toggle_entry = commands_after_toggle[#commands_after_toggle]
local nudge_entry = commands_after_toggle[#commands_after_toggle - 1]
local import_entry = commands_after_toggle[#commands_after_toggle - 2]
assert(toggle_entry.command_type == "ToggleClipEnabled", "Toggle command should be last in the log")
assert(nudge_entry.command_type == "Nudge", "Nudge command should precede the toggle")
assert(nudge_entry.parent_sequence_number == import_entry.sequence_number,
    string.format("Nudge parent should be %d (import), got %s", import_entry.sequence_number, tostring(nudge_entry.parent_sequence_number)))
local import_sequence = import_entry.sequence_number

local after_nudge_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}
assert(after_nudge_counts.clips == after_import_counts.clips,
    string.format("Nudge should not change clip count (was %d, now %d)",
        after_import_counts.clips, after_nudge_counts.clips))

-- ============================================================
-- Import persists XML contents for offline replay
-- ============================================================
local args_stmt = db:prepare([[SELECT command_args FROM commands WHERE command_type = 'ImportFCP7XML' ORDER BY sequence_number DESC LIMIT 1]])
assert(args_stmt:exec() and args_stmt:next(), "Import command should exist in log")
local args_json = args_stmt:value(0)
args_stmt:finalize()
local args_ok, args_table = pcall(json.decode, args_json or "{}")
assert(args_ok and type(args_table) == "table", "Import command args must decode to a table")
assert(type(args_table.xml_contents) == "string" and #args_table.xml_contents > 0, "Import command should store xml_contents for replay")

-- ============================================================
-- Undo/redo nudge: counts stable
-- ============================================================
local undo_nudge_result = command_manager.undo()
assert(undo_nudge_result.success, "Undoing nudge should succeed")

local after_undo_nudge_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_undo_nudge_counts.sequences == after_import_counts.sequences, "Undo nudge should leave sequences unchanged")
assert(after_undo_nudge_counts.tracks == after_import_counts.tracks, "Undo nudge should leave tracks unchanged")
assert(after_undo_nudge_counts.clips == after_import_counts.clips, "Undo nudge should leave clips unchanged")

local redo_nudge_result = command_manager.redo()
assert(redo_nudge_result.success, "Redoing nudge should succeed")

local after_redo_nudge_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_redo_nudge_counts.sequences == after_nudge_counts.sequences, "Redo nudge should match nudge state (sequences)")
assert(after_redo_nudge_counts.tracks == after_nudge_counts.tracks, "Redo nudge should match nudge state (tracks)")
assert(after_redo_nudge_counts.clips == after_nudge_counts.clips, "Redo nudge should match nudge state (clips)")

-- Return to import-only state for subsequent checks.
assert(command_manager.undo().success, "Undoing nudge again should succeed")

-- ============================================================
-- Undo import: removes imported entities
-- ============================================================
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo after import should succeed")

local after_undo_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_undo_counts.sequences <= after_import_counts.sequences, "Undo should not increase sequence count")
assert(after_undo_counts.tracks <= after_import_counts.tracks, "Undo should not increase track count")
assert(after_undo_counts.clips <= after_import_counts.clips, "Undo should not increase clip count")

-- ============================================================
-- Redo import: offline replay from xml_contents
-- ============================================================
local backup_path = xml_path .. ".bak"
local renamed = os.rename(xml_path, backup_path)
assert(renamed, "Should be able to rename XML fixture for offline replay test")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo after import should succeed")
local restore_ok, restore_err = os.rename(backup_path, xml_path)
assert(restore_ok, "Failed to restore XML fixture: " .. tostring(restore_err))

local after_redo_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_redo_counts.sequences == after_import_counts.sequences, "Redo should reproduce sequence count exactly")
assert(after_redo_counts.tracks == after_import_counts.tracks, "Redo should reproduce track count exactly")
assert(after_redo_counts.clips == after_import_counts.clips, "Redo should reproduce clip count exactly")

-- ============================================================
-- Event replay from scratch (simulates app restart)
-- ============================================================
local replay_commands = {}
local replay_stmt = db:prepare("SELECT * FROM commands WHERE sequence_number = ?")
replay_stmt:bind_value(1, import_sequence)
if replay_stmt and replay_stmt:exec() then
    while replay_stmt:next() do
        local parsed = Command.parse_from_query(replay_stmt, 'default_project')
        if parsed then
            table.insert(replay_commands, parsed)
        end
    end
end
if replay_stmt then replay_stmt:finalize() end

assert(db:exec([[
    PRAGMA foreign_keys = OFF;
    DELETE FROM tag_assignments;
    DELETE FROM tags;
    DELETE FROM tag_namespaces;
    DELETE FROM clips;
    DELETE FROM tracks;
    DELETE FROM sequences;
    DELETE FROM media;
    DELETE FROM commands;
    PRAGMA foreign_keys = ON;
    INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');
    INSERT OR REPLACE INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number,
        created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000,
        1920, 1080,
        0, 240, 0,
        NULL, NULL,
        '[]', '[]', '[]',
        0,
        strftime('%s','now'), strftime('%s','now')
    );
]]), "Failed to clear timeline state before replay")

-- Reinit real timeline_state + command_manager for replay
command_manager.init('default_sequence', 'default_project')
timeline_state.init('default_sequence', 'default_project')
executors = {}
undoers = {}
command_impl.register_commands(executors, undoers, db)

for _, cmd in ipairs(replay_commands) do
    local exec_result = command_manager.execute(cmd)
    assert(exec_result and exec_result.success,
        string.format("Event replay should succeed for %s: %s", tostring(cmd.type),
            exec_result and exec_result.error_message or "unknown error"))
end

local after_replay_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

assert(after_replay_counts.sequences == after_import_counts.sequences, "Replay should not duplicate sequences")
assert(after_replay_counts.tracks == after_import_counts.tracks, "Replay should not duplicate tracks")
assert(after_replay_counts.clips == after_import_counts.clips, "Replay should not duplicate clips")

print("✅ FCP7 XML import is idempotent across undo/redo and command replay")

-- ============================================================
-- Post-replay regression: real editing commands
-- ============================================================
local function fetch_video_tracks()
    local tracks = {}
    local stmt = db:prepare([[SELECT id FROM tracks WHERE track_type = 'VIDEO' ORDER BY track_index]])
    assert(stmt:exec())
    while stmt:next() do
        tracks[#tracks + 1] = stmt:value(0)
    end
    stmt:finalize()
    return tracks
end

local function fetch_media_ids(limit)
    local ids = {}
    local stmt = db:prepare("SELECT id FROM media ORDER BY id")
    assert(stmt:exec())
    while stmt:next() do
        ids[#ids + 1] = stmt:value(0)
        if limit and #ids >= limit then break end
    end
    stmt:finalize()
    return ids
end

local function fetch_single_clip_id()
    local stmt = db:prepare("SELECT id FROM clips LIMIT 1")
    assert(stmt:exec())
    local clip_id = nil
    if stmt:next() then
        clip_id = stmt:value(0)
    end
    stmt:finalize()
    return clip_id
end

-- Switch real timeline_state to the replayed imported sequence
local replay_seq_stmt = db:prepare([[SELECT id FROM sequences WHERE id != 'default_sequence' AND kind = 'timeline' LIMIT 1]])
assert(replay_seq_stmt:exec())
local replayed_sequence_id = nil
if replay_seq_stmt:next() then
    replayed_sequence_id = replay_seq_stmt:value(0)
end
replay_seq_stmt:finalize()
assert(replayed_sequence_id, "Should find replayed imported sequence")
timeline_state.init(replayed_sequence_id, "default_project")
command_manager.activate_timeline_stack(replayed_sequence_id)

local video_tracks = fetch_video_tracks()
assert(#video_tracks >= 2, "Importer should provide at least two video tracks")

local media_ids = fetch_media_ids(1)
assert(#media_ids >= 1, "Importer should provide media rows for insert operations")

-- Create masterclip sequence for the media (required for Insert after IS-a refactor)
local insert_master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Test Insert Master', 30, 1, 10000, media_ids[1])

local clip_for_move = fetch_single_clip_id()

local move_nudge_spec = json.encode({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = clip_for_move,
            target_track_id = video_tracks[2],
            skip_occlusion = true
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount = -10,
            selected_clip_ids = {clip_for_move}
        }
    }
})

local move_nudge_cmd = Command.create("BatchCommand", "default_project")
move_nudge_cmd:set_parameter("commands_json", move_nudge_spec)
assert(command_manager.execute(move_nudge_cmd).success, "MoveClipToTrack + Nudge batch should succeed")

local toggle_cmd2 = Command.create("ToggleClipEnabled", "default_project")
toggle_cmd2:set_parameter("clip_ids", {clip_for_move})
assert(command_manager.execute(toggle_cmd2).success, "ToggleClipEnabled should succeed for regression setup")

local insert_cmd2 = Command.create("Insert", "default_project")
insert_cmd2:set_parameter("master_clip_id", insert_master_clip_id)
insert_cmd2:set_parameter("track_id", video_tracks[1])
insert_cmd2:set_parameter("insert_time", 800000)
insert_cmd2:set_parameter("duration", 1000)
insert_cmd2:set_parameter("source_in", 0)
insert_cmd2:set_parameter("source_out", 1000)
insert_cmd2:set_parameter("sequence_id", replayed_sequence_id)
assert(command_manager.execute(insert_cmd2).success, "Insert command should succeed for regression setup")
local inserted_clip_id = insert_cmd2:get_parameter("clip_id")
assert(inserted_clip_id, "Insert command must record new clip_id for replay")

local split_spec = json.encode({
    {
        command_type = "SplitClip",
        parameters = {
            clip_id = inserted_clip_id,
            split_value = 800500
        }
    }
})

local split_cmd = Command.create("BatchCommand", "default_project")
split_cmd:set_parameter("commands_json", split_spec)
assert(command_manager.execute(split_cmd).success, "SplitClip batch should succeed for regression setup")

local split_exec = split_cmd:get_parameter("executed_commands_json")
local child_specs = json.decode(split_exec)
local split_second_clip_id = child_specs and child_specs[1] and child_specs[1].parameters and child_specs[1].parameters.second_clip_id

local clip_to_delete = split_second_clip_id or inserted_clip_id or fetch_single_clip_id()
assert(clip_to_delete, "There should be a clip to delete")

local delete_spec = json.encode({
    {
        command_type = "DeleteClip",
        parameters = {
            clip_id = clip_to_delete,
            sequence_id = replayed_sequence_id,
            project_id = "default_project"
        }
    }
})

local delete_cmd = Command.create("BatchCommand", "default_project")
delete_cmd:set_parameter("commands_json", delete_spec)

local delete_result = command_manager.execute(delete_cmd)
assert(delete_result.success, "Deleting a clip via BatchCommand should succeed")

local undo_delete_result = command_manager.undo()
assert(undo_delete_result.success, "Undo after deleting a clip should succeed")

print("✅ Delete clip undo regression covered")

-- Cleanup
Signals.disconnect(mutation_conn)
os.remove(TEST_DB)
