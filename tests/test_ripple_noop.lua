#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Command = require('command')

-- Stub timeline_state so we can observe reload attempts.
local timeline_state = {
    sequence_id = "default_sequence",
    reload_calls = 0,
    applied_mutations = 0
}

function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.get_project_id() return "default_project" end
function timeline_state.get_playhead_time() return 0 end
function timeline_state.set_playhead_time(_) end
function timeline_state.set_selection(_) end
function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.persist_state_to_db() end
function timeline_state.capture_viewport() return {start_time = 0, duration = 10000} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 0 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.consume_mutation_failure() return nil end
function timeline_state.apply_mutations()
    timeline_state.applied_mutations = timeline_state.applied_mutations + 1
    return false
end
function timeline_state.reload_clips()
    timeline_state.reload_calls = timeline_state.reload_calls + 1
end

package.loaded["ui.timeline.timeline_state"] = timeline_state

local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local function setup_db(path)
    os.remove(path)
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec([[
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, settings TEXT DEFAULT '{}');
        CREATE TABLE sequences (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'timeline',
            frame_rate REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            timecode_start INTEGER NOT NULL DEFAULT 0,
            playhead_time INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            name TEXT,
            track_type TEXT NOT NULL,
            track_index INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1
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
            offline INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE media (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            file_path TEXT,
            name TEXT,
            duration INTEGER,
            frame_rate REAL,
            width INTEGER,
            height INTEGER,
            audio_channels INTEGER DEFAULT 0,
            codec TEXT DEFAULT '',
            created_at INTEGER DEFAULT 0,
            modified_at INTEGER DEFAULT 0,
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
    ]]))
    assert(conn:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Timeline', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
        INSERT INTO media (id, project_id, file_path, name, duration, frame_rate)
        VALUES ('media_a', 'default_project', '/tmp/jve/media_a.mov', 'Media A', 4000, 30.0);
        INSERT INTO media (id, project_id, file_path, name, duration, frame_rate)
        VALUES ('media_b', 'default_project', '/tmp/jve/media_b.mov', 'Media B', 4000, 30.0);
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_time, duration, source_in, source_out, media_id)
        VALUES ('clip_a', 'default_project', 'track_v1', 'default_sequence', 0, 4000, 0, 4000, 'media_a');
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_time, duration, source_in, source_out, media_id)
        VALUES ('clip_b', 'default_project', 'track_v1', 'default_sequence', 4000, 4000, 0, 4000, 'media_b');
    ]]))

    command_impl.register_commands({}, {}, conn)
    command_manager.init(conn, 'default_sequence', 'default_project')
end

local TEST_DB = "/tmp/jve/test_ripple_noop.db"
setup_db(TEST_DB)

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    edge_type = "gap_after",
    track_id = "track_v1"
})
ripple_cmd:set_parameter("delta_ms", 1000) -- No actual gap, so delta clamps to 0
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit no-op should succeed")
assert(timeline_state.reload_calls == 0, "No-op ripple should not trigger timeline reload fallback")
assert(not command_manager.can_undo(), "No-op ripple should not add undo history")

print("✅ RippleEdit no-op skips timeline reload and undo recording")
