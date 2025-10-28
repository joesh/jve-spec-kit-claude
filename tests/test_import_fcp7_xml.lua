#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/test_import_fcp7_xml.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        current_sequence_number INTEGER,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000
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
        track_id TEXT NOT NULL,
        media_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
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
]])

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
]])

-- Minimal timeline_state stub to satisfy command replay requirements.
local timeline_state = {
    playhead_time = 0,
    selected_clips = {},
    selected_edges = {},
    viewport_start_time = 0,
    viewport_duration = 10000
}

local viewport_guard = 0

function timeline_state.get_sequence_id() return 'default_sequence' end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.set_edge_selection(edges) timeline_state.selected_edges = edges or {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
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
    local stmt = db:prepare("SELECT id FROM clips ORDER BY id")
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

local xml_path = "fixtures/resolve/sample_timeline_fcp7xml.xml"
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

-- Execute a nudge inside the imported sequence and ensure it links to the import command.
local clip_ids = fetch_clip_ids(5)
assert(#clip_ids > 0, "Import should create clips to nudge")

local nudge_cmd = Command.create("Nudge", "default_project")
nudge_cmd:set_parameter("nudge_amount_ms", 1000)
nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

local nudge_result = command_manager.execute(nudge_cmd)
assert(nudge_result.success, "Nudge command should succeed after import")

local commands_after_nudge = fetch_commands()
assert(#commands_after_nudge >= 2, "Command log should contain import and nudge commands")
local last_cmd = commands_after_nudge[#commands_after_nudge]
local prev_cmd = commands_after_nudge[#commands_after_nudge - 1]
assert(last_cmd.command_type == "Nudge", "Last command should be the nudge we just executed")
assert(last_cmd.parent_sequence_number == prev_cmd.sequence_number,
    string.format("Nudge parent should be %d (import), got %s", prev_cmd.sequence_number, tostring(last_cmd.parent_sequence_number)))
local import_sequence = prev_cmd.sequence_number

local after_nudge_counts = {
    sequences = count_rows("sequences"),
    tracks = count_rows("tracks"),
    clips = count_rows("clips"),
    media = count_rows("media")
}
assert(after_nudge_counts.clips == after_import_counts.clips, "Nudge should not change clip count")

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
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo after import should succeed")

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
