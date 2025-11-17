#!/usr/bin/env luajit

-- Regression: inserting into a non-default sequence must undo cleanly.
-- The pre-fix bug routed undo/redo through the default sequence, so the
-- inserted clip persisted after undo.

package.path = package.path .. ";./tests/?.lua;./tests/?/init.lua;./src/lua/?.lua;./src/lua/?/init.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_insert_undo_imported_sequence.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
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

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
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
    VALUES
        ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080),
        ('imported_sequence', 'default_project', 'Imported Sequence', 30.0, 1920, 1080);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES
        ('video1', 'default_sequence', 'V1', 'VIDEO', 1),
        ('imported_v1', 'imported_sequence', 'Imported V1', 'VIDEO', 1);

    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height)
    VALUES
        ('media_existing', 'default_project', 'Existing Clip', 'synthetic://existing', 5000, 30.0, 1920, 1080),
        ('media_insert', 'default_project', 'Insert Clip', 'synthetic://insert', 4500000, 30.0, 1920, 1080);

    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out)
    VALUES ('clip_existing', 'imported_v1', 'media_existing', 0, 5000, 0, 5000);
]])

local timeline_state = {
    playhead_time = 111400,
    sequence_id = 'imported_sequence',
    project_id = 'default_project',
    selected_clips = {},
    selected_edges = {},
    viewport_start_time = 0,
    viewport_duration = 10000
}

function timeline_state.get_project_id() return timeline_state.project_id end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.set_sequence_id(new_id) timeline_state.sequence_id = new_id end
function timeline_state.get_default_video_track_id() return 'imported_v1' end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.set_edge_selection(edges) timeline_state.selected_edges = edges or {} end
function timeline_state.normalize_edge_selection() return false end
function timeline_state.reload_clips(sequence_id)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
    end
end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
    end
    return mutations ~= nil
end
function timeline_state.consume_mutation_failure()
    return nil
end
function timeline_state.capture_viewport()
    return {
        start_time = timeline_state.viewport_start_time,
        duration = timeline_state.viewport_duration
    }
end
function timeline_state.restore_viewport(snapshot)
    if not snapshot then return end
    if snapshot.start_time then timeline_state.viewport_start_time = snapshot.start_time end
    if snapshot.duration then timeline_state.viewport_duration = snapshot.duration end
end
local viewport_guard = 0
function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end
function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then viewport_guard = viewport_guard - 1 end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init(db, 'default_sequence', 'default_project')

local function clip_count(sequence_id)
    local stmt = db:prepare([[
        SELECT COUNT(*)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]])
    assert(stmt, "Failed to prepare clip count query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), "Failed to execute clip count query")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local baseline = clip_count('imported_sequence')
assert(baseline == 1, string.format("Expected baseline clip count 1, got %d", baseline))

local insert_cmd = Command.create("Insert", 'default_project')
insert_cmd:set_parameter("media_id", "media_insert")
insert_cmd:set_parameter("sequence_id", "imported_sequence")
insert_cmd:set_parameter("track_id", "imported_v1")
insert_cmd:set_parameter("insert_time", 111400)
insert_cmd:set_parameter("duration", 4543560)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4543560)
insert_cmd:set_parameter("advance_playhead", true)

local execute_result = command_manager.execute(insert_cmd)
assert(execute_result.success, "Insert command should succeed")

local after_insert = clip_count('imported_sequence')
assert(after_insert == baseline + 1,
    string.format("Insert should add a clip (expected %d, got %d)", baseline + 1, after_insert))

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed")

local after_undo = clip_count('imported_sequence')
assert(after_undo == baseline,
    string.format("Undo should restore clip count to baseline (expected %d, got %d)", baseline, after_undo))

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")

local after_redo = clip_count('imported_sequence')
assert(after_redo == baseline + 1,
    string.format("Redo should reapply insert (expected %d, got %d)", baseline + 1, after_redo))

print("✅ Insert undo/redo respects active imported sequence")
