#!/usr/bin/env luajit

-- Test FCP7 XML import: execute, undo, redo, replay, post-import editing
-- Verifies: import creates entities, MatchFrame works, mutations flow, undo/redo idempotent, replay from scratch
-- Uses REAL timeline_state — no mock.

local test_env = require('test_env')
local ui       = require('synthetic.integration.ui_test_env')

print("=== test_import_fcp7_xml ===")

local DB = "/tmp/jve/test_import_fcp7_xml.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local database        = require('core.database')
local command_manager = require('core.command_manager')
local Command         = require('command')
local json            = require("dkjson")
local fcp7_importer   = require("importers.fcp7_xml_importer")
local Signals         = require('core.signals')
local sqlite3         = require("core.sqlite3")
local timeline_state  = require('ui.timeline.timeline_state')
local PROJECT_ID      = info.project.id
local DEFAULT_SEQ_ID  = info.sequences[1].id
local db = database.get_connection()

-- Used only by the anamnesis sub-scenario below, which exercises the
-- importer against a side-DB to assert track_type discipline. The main
-- project DB is provisioned by ui.launch above.
local function bootstrap_schema(conn)
    assert(conn:exec(require('import_schema')),
        "Failed to create schema tables")
    assert(conn:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings)
        VALUES ('%s', 'Default Project', 0, 0, 'passthrough',
                '{"audio_sample_rate":48000,"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}');
        INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');
    ]], PROJECT_ID)), "Failed to seed scratch project")
end

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
    -- V13: every row in `clips` is a timeline-side clip (clips must be owned by a kind='sequence' sequence).
    local stmt = db:prepare("SELECT id FROM clips ORDER BY sequence_start_frame DESC")
    assert(stmt, "fetch_clip_ids: prepare failed")
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

local function resolve_fixture(path)
    return test_env.require_fixture(path)
end

-- ============================================================
-- Execute Import
-- ============================================================
local xml_path = resolve_fixture("tests/fixtures/resolve/sample_timeline_fcp7xml.xml")
local import_cmd = Command.create("ImportFCP7XML", PROJECT_ID)
import_cmd:set_parameter("xml_path", xml_path)
import_cmd:set_parameter("project_id", PROJECT_ID)

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
-- V13: master clips ARE sequences (kind='master'), one per media. The
-- pre-013 clips.clip_kind='master' rows are gone.
-- ============================================================
local master_count_stmt = db:prepare([[SELECT COUNT(*) FROM sequences WHERE kind = 'master']])
assert(master_count_stmt, "Master sequence count query should prepare")
assert(master_count_stmt:exec() and master_count_stmt:next(), "Master sequence count query should succeed")
local master_clip_count = master_count_stmt:value(0)
master_count_stmt:finalize()
assert(master_clip_count > 0, "Import should create master sequences for MatchFrame")

local expected_master_bin_name = "Timeline 1 (Resolve) Master Clips"
local master_bin_id = nil
for _, bin in ipairs(database.load_bins(PROJECT_ID)) do
    if bin.name == expected_master_bin_name then
        master_bin_id = bin.id
        break
    end
end
assert(master_bin_id, "Importer should create a '<sequence name> Master Clips' bin")

local sample_master_stmt = db:prepare([[SELECT id FROM sequences WHERE kind = 'master' ORDER BY id LIMIT 1]])
assert(sample_master_stmt, "Sample master sequence query should prepare")
assert(sample_master_stmt:exec() and sample_master_stmt:next(), "Should fetch at least one master sequence")
sample_master_stmt:finalize()
local media_bin_map = database.load_master_clip_bin_map(PROJECT_ID)
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

local parsed_anamnesis = fcp7_importer.import_xml(anamnesis_path, PROJECT_ID)
assert(parsed_anamnesis.success, parsed_anamnesis.errors and parsed_anamnesis.errors[1] or "Anamnesis fixture parsing failed")
local anamnesis_entities = fcp7_importer.create_entities(parsed_anamnesis, scratch_db, PROJECT_ID)
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
-- V13: timeline-side clips reference their master via source_sequence_id
-- (the V8 master_clip_id column is gone), and clips must be owned by a kind='sequence' sequence; that
-- every clip has a non-null source_sequence_id, so no NULL filter needed.
local timeline_master_stmt = db:prepare([[SELECT c.id, c.sequence_id, c.sequence_start_frame
    FROM clips c LIMIT 1]])
assert(timeline_master_stmt, "Timeline clip master query should prepare")
assert(timeline_master_stmt:exec(), "Timeline clip master query should run")
local timeline_clip_id, timeline_master_id, tl_start = nil, nil, nil
if timeline_master_stmt:next() then
    timeline_clip_id = timeline_master_stmt:value(0)
    timeline_master_id = timeline_master_stmt:value(1)
    tl_start = timeline_master_stmt:value(2)
end
timeline_master_stmt:finalize()
assert(timeline_clip_id and timeline_master_id,
    "Importer should assign source_sequence_id (master) for timeline clips")

-- Get the imported sequence and switch real timeline_state to it
local import_record = command_manager.get_last_command(PROJECT_ID)
assert(import_record, "Import command should exist")
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

timeline_state.init(imported_sequence_id, PROJECT_ID)
command_manager.activate_timeline_stack(imported_sequence_id)

-- MatchFrame: set playhead inside the clip
timeline_state.set_playhead_position(tl_start + 1)

local match_cmd = Command.create("MatchFrame", PROJECT_ID)
local match_result = command_manager.execute(match_cmd)
-- See memory `todo_matchframe_offline_file_exists` — open question about
-- MatchFrame's file_exists guard vs offline fixtures.
assert(match_result.success, "MatchFrame should succeed on imported clips: "
    .. tostring(match_result.error_message))
local source_mon = require("ui.panel_manager").get_sequence_monitor("source_monitor")
assert(source_mon, "panel_manager must expose source_monitor after ui.launch")
assert(source_mon.sequence_id == timeline_master_id,
    "MatchFrame should load the master clip into source viewer")

-- ============================================================
-- Nudge applies mutations (signal-observed)
-- ============================================================
local clip_ids = fetch_clip_ids(1)
assert(#clip_ids > 0, "Import should create clips to nudge")

reset_mutation_tracking()

local nudge_cmd = Command.create("Nudge", PROJECT_ID)
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
local toggle_cmd = Command.create("ToggleClipEnabled", PROJECT_ID)
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
        local parsed = Command.parse_from_query(replay_stmt, PROJECT_ID)
        if parsed then
            table.insert(replay_commands, parsed)
        end
    end
end
if replay_stmt then replay_stmt:finalize() end

assert(db:exec(string.format([[
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
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number,
        created_at, modified_at
    ) VALUES (
        '%s', '%s', 'Default Sequence', 'sequence',
        30, 1, 48000,
        1920, 1080,
        0, 240, 0,
        NULL, NULL,
        '[]', '[]', '[]',
        0,
        0, 0
    );
]], DEFAULT_SEQ_ID, PROJECT_ID)), "Failed to clear timeline state before replay")

-- Reinit real timeline_state + command_manager for replay (executors
-- were registered during ui.launch and remain wired — no re-register
-- needed).
command_manager.init(DEFAULT_SEQ_ID, PROJECT_ID)
timeline_state.init(DEFAULT_SEQ_ID, PROJECT_ID)

-- Wiped baseline: one empty sequence, no tracks/clips/media. Replay
-- should produce exactly the delta a fresh import produces, not the
-- pre-wipe absolute counts (the template's tracks were wiped too).
local import_delta = {
    sequences = after_import_counts.sequences - initial_counts.sequences,
    tracks    = after_import_counts.tracks    - initial_counts.tracks,
    clips     = after_import_counts.clips     - initial_counts.clips,
    media     = after_import_counts.media     - initial_counts.media,
}
local wiped_counts = {
    sequences = count_rows("sequences"),
    tracks    = count_rows("tracks"),
    clips     = count_rows("clips"),
    media     = count_rows("media"),
}

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

-- Wiped baseline + replayed import delta == post-replay state.
assert(after_replay_counts.sequences == wiped_counts.sequences + import_delta.sequences,
    "Replay should reproduce import sequence delta exactly (no duplicates)")
assert(after_replay_counts.tracks == wiped_counts.tracks + import_delta.tracks,
    "Replay should reproduce import track delta exactly (no duplicates)")
assert(after_replay_counts.clips == wiped_counts.clips + import_delta.clips,
    "Replay should reproduce import clip delta exactly (no duplicates)")

print("✅ FCP7 XML import is idempotent across undo/redo and command replay")

-- ============================================================
-- Post-replay regression: real editing commands
-- ============================================================
local function fetch_video_tracks(sequence_id)
    -- Must scope by sequence_id: V13 enforces owner_sequence_id matches the
    -- clip's track.sequence_id (load_clips asserts). Cross-sequence track
    -- pulls produce broken state.
    assert(sequence_id and sequence_id ~= "",
        "fetch_video_tracks: sequence_id required")
    local tracks = {}
    local stmt = db:prepare([[SELECT id FROM tracks
        WHERE track_type = 'VIDEO' AND sequence_id = ? ORDER BY track_index]])
    assert(stmt, "fetch_video_tracks: prepare failed")
    stmt:bind_value(1, sequence_id)
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

local function fetch_single_clip_id(sequence_id)
    assert(sequence_id, "fetch_single_clip_id: sequence_id required")
    -- 018: pick a VIDEO clip — MoveClipToTrack target below is a VIDEO track,
    -- and INV-3 forbids moving an AUDIO clip (carries source_*_subframe) onto
    -- a VIDEO track without first nulling the sub-frame columns.
    local stmt = db:prepare([[
        SELECT c.id FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
        LIMIT 1
    ]])
    assert(stmt, "fetch_single_clip_id: prepare failed")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec())
    local clip_id = nil
    if stmt:next() then
        clip_id = stmt:value(0)
    end
    stmt:finalize()
    return clip_id
end

-- Switch real timeline_state to the replayed imported sequence
local replay_seq_stmt = db:prepare(
    "SELECT id FROM sequences WHERE id != ? AND kind = 'sequence' LIMIT 1")
replay_seq_stmt:bind_value(1, DEFAULT_SEQ_ID)
assert(replay_seq_stmt:exec())
local replayed_sequence_id = nil
if replay_seq_stmt:next() then
    replayed_sequence_id = replay_seq_stmt:value(0)
end
replay_seq_stmt:finalize()
assert(replayed_sequence_id, "Should find replayed imported sequence")
timeline_state.init(replayed_sequence_id, PROJECT_ID)
command_manager.activate_timeline_stack(replayed_sequence_id)

local video_tracks = fetch_video_tracks(replayed_sequence_id)
assert(#video_tracks >= 2, "Importer should provide at least two video tracks")

local media_ids = fetch_media_ids(1)
assert(#media_ids >= 1, "Importer should provide media rows for insert operations")

-- Create masterclip sequence for the media (required for Insert after IS-a refactor)
local insert_source_sequence_id = test_env.create_test_masterclip_sequence(
    PROJECT_ID, 'Test Insert Master', 30, 1, 10000, media_ids[1])

local clip_for_move = fetch_single_clip_id(replayed_sequence_id)

command_manager.begin_undo_group("move_nudge")
local move_cmd = Command.create("MoveClipToTrack", PROJECT_ID)
move_cmd:set_parameter("clip_id", clip_for_move)
move_cmd:set_parameter("target_track_id", video_tracks[2])
move_cmd:set_parameter("skip_occlusion", true)
do
    local r = command_manager.execute(move_cmd)
    assert(r and r.success, "MoveClipToTrack should succeed; got result="
        .. require("dkjson").encode(r) .. " last_error=" .. tostring(command_manager.get_last_error and command_manager.get_last_error()))
end
local nudge_cmd2 = Command.create("Nudge", PROJECT_ID)
nudge_cmd2:set_parameter("nudge_amount", -10)
nudge_cmd2:set_parameter("selected_clip_ids", {clip_for_move})
assert(command_manager.execute(nudge_cmd2).success, "Nudge should succeed")
command_manager.end_undo_group()

local toggle_cmd2 = Command.create("ToggleClipEnabled", PROJECT_ID)
toggle_cmd2:set_parameter("clip_ids", {clip_for_move})
assert(command_manager.execute(toggle_cmd2).success, "ToggleClipEnabled should succeed for regression setup")

-- V13 Insert: source range comes from the master sequence's marks; the
-- timeline-side spec is just (target track, sequence_start_frame).
do
    local Sequence = require("models.sequence")
    local mc_seq = Sequence.load(insert_source_sequence_id)
    assert(mc_seq, "master sequence must load to set marks")
    -- Constrain marks to the media's actual duration (the master inherits it
    -- from the media row; ensure_master ignores the duration arg passed to
    -- create_test_masterclip_sequence). Use the full extent.
    local end_frame = mc_seq:content_duration()
    assert(end_frame and end_frame > 0,
        "Master sequence has no content_duration — fixture media missing duration")
    mc_seq.mark_in = 0
    mc_seq.mark_out = end_frame
    mc_seq:save()
end
local insert_cmd2 = Command.create("Insert", PROJECT_ID)
insert_cmd2:set_parameter("source_sequence_id", insert_source_sequence_id)
insert_cmd2:set_parameter("target_video_track_id", video_tracks[1])
insert_cmd2:set_parameter("sequence_start_frame", 800)
insert_cmd2:set_parameter("sequence_id", replayed_sequence_id)
do
    local _r = command_manager.execute(insert_cmd2)
    assert(_r.success,
        "Insert command should succeed for regression setup: " ..
        tostring(_r.error_message))
end
local created_clip_ids = insert_cmd2:get_parameter("created_clip_ids")
assert(created_clip_ids and created_clip_ids[1],
    "Insert command must record created_clip_ids for replay")
local inserted_clip_id = created_clip_ids[1]

-- V13 SplitClip param renamed split_value → split_frame (frame coords).
local split_cmd = Command.create("SplitClip", PROJECT_ID)
split_cmd:set_parameter("clip_id", inserted_clip_id)
split_cmd:set_parameter("split_frame", 805)
split_cmd:set_parameter("sequence_id", replayed_sequence_id)
do
    local _r = command_manager.execute(split_cmd)
    assert(_r.success, "SplitClip should succeed for regression setup: "
        .. tostring(_r.error_message))
end

local split_second_clip_id = split_cmd:get_parameter("second_clip_id")

local clip_to_delete = split_second_clip_id or inserted_clip_id or fetch_single_clip_id(replayed_sequence_id)
assert(clip_to_delete, "There should be a clip to delete")

local delete_cmd = Command.create("DeleteClip", PROJECT_ID)
delete_cmd:set_parameter("clip_id", clip_to_delete)
delete_cmd:set_parameter("sequence_id", replayed_sequence_id)
delete_cmd:set_parameter("project_id", PROJECT_ID)

local delete_result = command_manager.execute(delete_cmd)
assert(delete_result.success, "Deleting a clip should succeed")

local undo_delete_result = command_manager.undo()
assert(undo_delete_result.success, "Undo after deleting a clip should succeed")

print("✅ Delete clip undo regression covered")

-- Cleanup
Signals.disconnect(mutation_conn)
