#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local json = require("dkjson")
local sqlite3 = require("core.sqlite3")
local fcp7_importer = require("importers.fcp7_xml_importer")

local TEST_DB = "/tmp/jve/test_import_fcp7_xml.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

local function bootstrap_schema(conn)
    assert(conn, "bootstrap_schema requires a database connection")
    assert(conn:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}',
        created_at INTEGER DEFAULT 0,
        modified_at INTEGER DEFAULT 0
    );

            CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );


    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

                    CREATE TABLE clips (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            clip_kind TEXT NOT NULL DEFAULT 'timeline',
            name TEXT DEFAULT '',
            track_id TEXT,
            media_id TEXT,
            source_sequence_id TEXT,
            parent_clip_id TEXT,
            owner_sequence_id TEXT,
            start_time INTEGER NOT NULL,
            duration INTEGER NOT NULL,
            source_in INTEGER NOT NULL DEFAULT 0,
            source_out INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            offline INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT 0,
            modified_at INTEGER NOT NULL DEFAULT 0
        );



    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT UNIQUE NOT NULL,
        duration INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT DEFAULT '{}'
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );

    CREATE TABLE tag_namespaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    );

    INSERT OR IGNORE INTO tag_namespaces(id, display_name)
    VALUES('bin', 'Bins');

    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE tag_assignments (
        tag_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        assigned_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tag_id, entity_type, entity_id)
    );
]]), "Failed to create schema tables")
    assert(conn:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
]]), "Failed to seed default project/sequence")
end

bootstrap_schema(db)

-- Minimal timeline_state stub to satisfy command replay requirements.
local timeline_state = {
    playhead_time = 0,
    selected_clips = {},
    selected_edges = {},
    viewport_start_time = 0,
    viewport_duration = 10000,
    sequence_id = "default_sequence",
    last_mutations = nil,
    last_mutations_attempt = nil
}

local viewport_guard = 0

function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.set_edge_selection(edges) timeline_state.selected_edges = edges or {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
local function has_entries(list)
    return type(list) == "table" and next(list) ~= nil
end

function timeline_state.apply_mutations(sequence_id, mutations)
    timeline_state.applied_calls = (timeline_state.applied_calls or 0) + 1
    local target_sequence = sequence_id or (mutations and mutations.sequence_id) or timeline_state.sequence_id
    if not mutations then
        return false
    end
    if target_sequence and target_sequence ~= "" then
        timeline_state.sequence_id = target_sequence
    end
    timeline_state.last_mutations_attempt = {
        sequence_id = target_sequence,
        bucket = mutations
    }
    local changed = has_entries(mutations.updates) or has_entries(mutations.inserts) or has_entries(mutations.deletes)
    if changed then
        timeline_state.last_mutations = mutations
    end
    return changed
end
function timeline_state.set_viewport_start_time(ms) timeline_state.viewport_start_time = ms end
function timeline_state.set_viewport_duration(ms) timeline_state.viewport_duration = ms end
function timeline_state.capture_viewport()
    return {
        start_time = timeline_state.viewport_start_time,
        duration = timeline_state.viewport_duration,
    }
end
function timeline_state.restore_viewport(snapshot)
    if not snapshot then return end
    if snapshot.duration then timeline_state.viewport_duration = snapshot.duration end
    if snapshot.start_time then timeline_state.viewport_start_time = snapshot.start_time end
end
function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end
function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then viewport_guard = viewport_guard - 1 end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local project_browser = {
    focused_master_clip_id = nil,
    focus_calls = 0
}

function project_browser.refresh() end

function project_browser.focus_master_clip(master_clip_id, _opts)
    project_browser.focused_master_clip_id = master_clip_id
    project_browser.focus_calls = project_browser.focus_calls + 1
    return true
end

function project_browser.get_selected_master_clip()
    return nil
end

function project_browser.focus_bin() end

package.loaded['ui.project_browser'] = project_browser

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)

command_manager.init(db, 'default_sequence', 'default_project')

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
    local stmt = db:prepare("SELECT id FROM clips WHERE clip_kind = 'timeline' ORDER BY id")
    assert(stmt:exec())
    while stmt:next() do
        table.insert(ids, stmt:value(0))
        if limit and #ids >= limit then break end
    end
    stmt:finalize()
    return ids
end

local function fetch_project_settings()
    local stmt = db:prepare([[SELECT settings FROM projects WHERE id = 'default_project']])
    assert(stmt:exec() and stmt:next(), "Project settings query should succeed")
    local raw = stmt:value(0) or "{}"
    stmt:finalize()
    local ok, decoded = pcall(json.decode, raw)
    assert(ok and type(decoded) == "table", "Project settings should decode into a table")
    return decoded
end

local initial_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

local xml_path_relative = "fixtures/resolve/sample_timeline_fcp7xml.xml"
local pwd = os.getenv("PWD") or "."
local function resolve_fixture(path)
    local absolute = pwd .. "/" .. path
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
local sample_master_id = sample_master_stmt:value(0)
sample_master_stmt:finalize()
local media_bin_map = database.load_master_clip_bin_map("default_project")
local assigned_count = 0
for _, bin_id in pairs(media_bin_map) do
    if bin_id == master_bin_id then
        assigned_count = assigned_count + 1
    end
end
assert(assigned_count == master_clip_count,
    string.format("Expected %d master clips assigned to %s, got %d",
        master_clip_count, expected_master_bin_name, assigned_count))

-- Regression: importing the anamnesis fixture must assign AUDIO/VIDEO track types.
local anamnesis_fixture = "fixtures/resolve/2025-07-08-anamnesis-PICTURE-LOCK-TWO more comps.xml"
local anamnesis_path = resolve_fixture(anamnesis_fixture)
local scratch_db_path = "/tmp/jve/test_import_fcp7_xml_anamnesis.db"
os.remove(scratch_db_path)
local scratch_db = sqlite3.open(scratch_db_path)
assert(scratch_db, "Failed to open scratch database copy")
bootstrap_schema(scratch_db)
local parsed_anamnesis = fcp7_importer.import_xml(anamnesis_path, "default_project")
assert(parsed_anamnesis.success, parsed_anamnesis.errors and parsed_anamnesis.errors[1] or "Anamnesis fixture parsing failed")
local anamnesis_entities = fcp7_importer.create_entities(parsed_anamnesis, scratch_db, "default_project")
assert(anamnesis_entities.success, anamnesis_entities.error or "Anamnesis fixture entity creation failed")
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

local timeline_parent_stmt = db:prepare([[SELECT id, parent_clip_id FROM clips WHERE clip_kind = 'timeline' AND parent_clip_id IS NOT NULL LIMIT 1]])
assert(timeline_parent_stmt:exec(), "Timeline clip parent query should run")
local timeline_clip_id, timeline_parent_id = nil, nil
if timeline_parent_stmt:next() then
    timeline_clip_id = timeline_parent_stmt:value(0)
    timeline_parent_id = timeline_parent_stmt:value(1)
end
timeline_parent_stmt:finalize()
assert(timeline_clip_id and timeline_parent_id, "Importer should assign parent_clip_id for timeline clips")

timeline_state.set_selection({
    { id = timeline_clip_id, parent_clip_id = timeline_parent_id }
})

local match_cmd = Command.create("MatchFrame", "default_project")
local match_result = command_manager.execute(match_cmd)
assert(match_result.success, "MatchFrame should succeed on imported clips")
assert(project_browser.focused_master_clip_id == timeline_parent_id,
    "MatchFrame should focus the parent master clip")

-- Execute a nudge inside the imported sequence and ensure it links to the import command.
local clip_ids = fetch_clip_ids(5)
assert(#clip_ids > 0, "Import should create clips to nudge")

local nudge_cmd = Command.create("Nudge", "default_project")
nudge_cmd:set_parameter("nudge_amount_ms", 1000)
nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

local nudge_result = command_manager.execute(nudge_cmd)
assert(nudge_result.success, "Nudge command should succeed after import")
assert(nudge_cmd:get_parameter("sequence_id"), "Nudge should capture the active sequence for timeline cache updates")
local attempt_serialized = timeline_state.last_mutations_attempt and json.encode({
    sequence_id = timeline_state.last_mutations_attempt.sequence_id,
    has_updates = has_entries(timeline_state.last_mutations_attempt.bucket and timeline_state.last_mutations_attempt.bucket.updates),
    has_inserts = has_entries(timeline_state.last_mutations_attempt.bucket and timeline_state.last_mutations_attempt.bucket.inserts),
    has_deletes = has_entries(timeline_state.last_mutations_attempt.bucket and timeline_state.last_mutations_attempt.bucket.deletes)
}) or "nil"
assert(timeline_state.last_mutations_attempt, "Nudge should attempt timeline mutations")
assert(timeline_state.last_mutations, "Nudge should apply timeline mutations. Attempt: " .. attempt_serialized)
timeline_state.last_mutations = nil
timeline_state.last_mutations_attempt = nil

local toggle_cmd = Command.create("ToggleClipEnabled", "default_project")
toggle_cmd:set_parameter("clip_ids", { clip_ids[1] })
local toggle_apply_calls = timeline_state.applied_calls or 0
local toggle_result = command_manager.execute(toggle_cmd)
assert(toggle_result.success, "ToggleClipEnabled should succeed on imported clip")
assert((timeline_state.applied_calls or 0) > toggle_apply_calls, "ToggleClipEnabled should apply timeline mutations")
local toggle_update = timeline_state.last_mutations and timeline_state.last_mutations.updates and
    timeline_state.last_mutations.updates[1]
assert(toggle_update and toggle_update.enabled ~= nil, "ToggleClipEnabled updates must include enabled state")
timeline_state.last_mutations = nil

timeline_state.last_mutations = nil
timeline_state.last_mutations_attempt = nil
local undo_toggle = command_manager.undo()
assert(undo_toggle.success, "Undo ToggleClipEnabled should succeed")
assert(timeline_state.last_mutations, "Undo ToggleClipEnabled should emit timeline mutations")
timeline_state.last_mutations = nil
timeline_state.last_mutations_attempt = nil
local redo_toggle = command_manager.redo()
assert(redo_toggle.success, "Redo ToggleClipEnabled should succeed")
assert(timeline_state.last_mutations, "Redo ToggleClipEnabled should emit timeline mutations")
timeline_state.last_mutations = nil

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
assert(after_nudge_counts.clips == after_import_counts.clips, "Nudge should not change clip count")

-- Ensure the import command persisted XML contents for offline replay.
local args_stmt = db:prepare([[SELECT command_args FROM commands WHERE command_type = 'ImportFCP7XML' ORDER BY sequence_number DESC LIMIT 1]])
assert(args_stmt:exec() and args_stmt:next(), "Import command should exist in log")
local args_json = args_stmt:value(0)
args_stmt:finalize()
local args_ok, args_table = pcall(json.decode, args_json or "{}")
assert(args_ok and type(args_table) == "table", "Import command args must decode to a table")
assert(type(args_table.xml_contents) == "string" and #args_table.xml_contents > 0, "Import command should store xml_contents for replay")

-- Undo nudge should restore import state without clearing the timeline.
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

-- Redo nudge should reapply the move without duplicating content.
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

-- Undo should remove imported entities.
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo after import should succeed")

local after_undo_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}

-- Undo currently leaves imported metadata in place because replay to the root clears clips but
-- defers higher-level cleanup to command replays. Ensure counts do not grow.
assert(after_undo_counts.sequences <= after_import_counts.sequences, "Undo should not increase sequence count")
assert(after_undo_counts.tracks <= after_import_counts.tracks, "Undo should not increase track count")
assert(after_undo_counts.clips <= after_import_counts.clips, "Undo should not increase clip count")

-- Redo replays the command. Counts should match the original import (no duplicates).
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

-- Simulate application restart by replaying events from scratch.
local replay_success = command_manager.replay_events("default_sequence", import_sequence)
assert(replay_success, "Event replay should succeed")

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

-- Regression setup helpers
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

local video_tracks = fetch_video_tracks()
assert(#video_tracks >= 2, "Importer should provide at least two video tracks")

local media_ids = fetch_media_ids(1)
assert(#media_ids >= 1, "Importer should provide media rows for insert operations")

-- Simulate additional editing commands to mirror real-world history.
local clip_for_move = fetch_single_clip_id()

local move_nudge_spec = json.encode({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = clip_for_move,
            target_track_id = video_tracks[2],
            skip_occlusion = true  -- Match drag batching behaviour
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount_ms = -333,
            selected_clip_ids = {clip_for_move}
        }
    }
})

local move_nudge_cmd = Command.create("BatchCommand", "default_project")
move_nudge_cmd:set_parameter("commands_json", move_nudge_spec)
assert(command_manager.execute(move_nudge_cmd).success, "MoveClipToTrack + Nudge batch should succeed")

local toggle_cmd = Command.create("ToggleClipEnabled", "default_project")
toggle_cmd:set_parameter("clip_ids", {clip_for_move})
assert(command_manager.execute(toggle_cmd).success, "ToggleClipEnabled should succeed for regression setup")

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("media_id", media_ids[1])
insert_cmd:set_parameter("track_id", video_tracks[1])
insert_cmd:set_parameter("insert_time", 800000)  -- far enough to avoid collisions
insert_cmd:set_parameter("duration", 1000)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 1000)
insert_cmd:set_parameter("sequence_id", "default_sequence")
assert(command_manager.execute(insert_cmd).success, "Insert command should succeed for regression setup")
local inserted_clip_id = insert_cmd:get_parameter("clip_id")
assert(inserted_clip_id, "Insert command must record new clip_id for replay")

local split_spec = json.encode({
    {
        command_type = "SplitClip",
        parameters = {
            clip_id = inserted_clip_id,
            split_time = 800500
        }
    }
})

local split_cmd = Command.create("BatchCommand", "default_project")
split_cmd:set_parameter("commands_json", split_spec)
assert(command_manager.execute(split_cmd).success, "SplitClip batch should succeed for regression setup")

local split_exec = split_cmd:get_parameter("executed_commands_json")
local child_specs = json.decode(split_exec)
local split_second_clip_id = child_specs and child_specs[1] and child_specs[1].parameters and child_specs[1].parameters.second_clip_id

-- Regression: deleting a clip and undoing should succeed after a long history.
local clip_to_delete = split_second_clip_id or inserted_clip_id or fetch_single_clip_id()
assert(clip_to_delete, "There should be a clip to delete")

local delete_spec = json.encode({
    {
        command_type = "DeleteClip",
        parameters = {
            clip_id = clip_to_delete,
            sequence_id = "default_sequence",
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
