#!/usr/bin/env luajit

-- Regression: undoing an FCP7 XML import while focused on the imported sequence
-- should not strand the redo stack. Redo must recreate the sequence, tracks,
-- and clips even though the timeline stack points at a deleted sequence ID.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/core/?.lua"
    .. ";../src/lua/models/?.lua"
    .. ";../tests/?.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local SCHEMA_SQL = [[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
    );

    CREATE TABLE sequences (
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

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
    );

    CREATE TABLE master_clips (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        media_id TEXT,
        name TEXT NOT NULL,
        clip_kind TEXT NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        created_at INTEGER,
        modified_at INTEGER
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
        created_at INTEGER,
        modified_at INTEGER
    );

    CREATE TABLE properties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT
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
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
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
]]

local function install_timeline_stub()
    local timeline_state = {
        playhead_time = 0,
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},
        viewport_start_time = 0,
        viewport_duration = 10000,
        sequence_id = 'default_sequence'
    }
    local guard_depth = 0

    function timeline_state.get_sequence_id()
        return timeline_state.sequence_id
    end

    function timeline_state.reload_clips(sequence_id)
        if sequence_id and sequence_id ~= "" then
            timeline_state.sequence_id = sequence_id
        end
    end

    function timeline_state.capture_viewport()
        return {
            start_time = timeline_state.viewport_start_time,
            duration = timeline_state.viewport_duration
        }
    end

    function timeline_state.push_viewport_guard()
        guard_depth = guard_depth + 1
        return guard_depth
    end

    function timeline_state.pop_viewport_guard()
        guard_depth = math.max(guard_depth - 1, 0)
        return guard_depth
    end

    function timeline_state.restore_viewport(snapshot)
        if not snapshot then
            return
        end
        if snapshot.start_time then
            timeline_state.viewport_start_time = snapshot.start_time
        end
        if snapshot.duration then
            timeline_state.viewport_duration = snapshot.duration
        end
    end

    function timeline_state.set_playhead_time(ms)
        timeline_state.playhead_time = ms
    end

    function timeline_state.get_playhead_time()
        return timeline_state.playhead_time
    end

    function timeline_state.set_selection(clips)
        timeline_state.selected_clips = clips or {}
    end

    function timeline_state.get_selected_clips()
        return timeline_state.selected_clips
    end

    function timeline_state.get_selected_edges()
        return timeline_state.selected_edges
    end

    function timeline_state.set_edge_selection(edges)
        timeline_state.selected_edges = edges or {}
    end

    function timeline_state.set_gap_selection(gaps)
        timeline_state.selected_gaps = gaps or {}
    end

    function timeline_state.clear_edge_selection() end
    function timeline_state.clear_gap_selection() end
    function timeline_state.normalize_edge_selection() end
    function timeline_state.persist_state_to_db() end
    function timeline_state.apply_mutations()
        return true
    end
    function timeline_state.consume_mutation_failure()
        return nil
    end

    package.loaded['ui.timeline.timeline_state'] = timeline_state
end

local function init_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
    ]]))
    return db
end

local function count_rows(db, table_name)
    local stmt = db:prepare("SELECT COUNT(*) FROM " .. table_name)
    assert(stmt, "Failed to prepare count for " .. tostring(table_name))
    assert(stmt:exec() and stmt:next(), "Failed to execute count for " .. tostring(table_name))
    local value = stmt:value(0) or 0
    stmt:finalize()
    return value
end

install_timeline_stub()

local tmp_db = "/tmp/test_import_redo_restores_sequence.db"
local db = init_database(tmp_db)

command_manager.init(db, 'default_sequence', 'default_project')
command_manager.activate_timeline_stack('default_sequence')

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", "fixtures/resolve/sample_timeline_fcp7xml.xml")

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, exec_result.error_message or "ImportFCP7XML execution failed")

local import_record = command_manager.get_last_command('default_project')
assert(import_record, "Import command not recorded in log")

local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence IDs")
local imported_sequence_id = created_sequence_ids[1]

local baseline_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}

command_manager.activate_timeline_stack(imported_sequence_id)

local clip_stmt = db:prepare("SELECT id FROM clips WHERE owner_sequence_id = ? LIMIT 1")
clip_stmt:bind_value(1, imported_sequence_id)
assert(clip_stmt:exec() and clip_stmt:next(), "Failed to fetch clip from imported sequence")
local imported_clip_id = clip_stmt:value(0)
clip_stmt:finalize()

local toggle_cmd = Command.create("ToggleClipEnabled", "default_project")
toggle_cmd:set_parameter("sequence_id", imported_sequence_id)
toggle_cmd:set_parameter("clip_ids", { imported_clip_id })
local toggle_result = command_manager.execute(toggle_cmd)
assert(toggle_result.success, "ToggleClipEnabled should succeed on imported clip")

assert(command_manager.undo().success, "Undo ToggleClipEnabled should succeed")
assert(command_manager.undo().success, "Undo ImportFCP7XML should succeed even from deleted stack")

local after_undo_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}
assert(after_undo_counts.sequences == 1, "Undo should remove imported sequence")
assert(after_undo_counts.tracks == 0, "Undo should remove imported tracks")
assert(after_undo_counts.clips == 0, "Undo should remove imported clips")

-- UI would still be focused on the (now deleted) imported timeline stack.
command_manager.activate_timeline_stack(imported_sequence_id)

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo import should succeed")

local after_redo_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}

assert(after_redo_counts.sequences == baseline_counts.sequences,
    string.format("Redo should restore sequence count (%d vs %d)", after_redo_counts.sequences, baseline_counts.sequences))
assert(after_redo_counts.tracks == baseline_counts.tracks,
    string.format("Redo should restore track count (%d vs %d)", after_redo_counts.tracks, baseline_counts.tracks))
assert(after_redo_counts.clips == baseline_counts.clips,
    string.format("Redo should restore clip count (%d vs %d)", after_redo_counts.clips, baseline_counts.clips))

os.remove(tmp_db)
print("✅ Redo after ImportFCP7XML restores deleted sequence state")
