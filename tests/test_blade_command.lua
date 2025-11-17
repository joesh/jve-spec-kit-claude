#!/usr/bin/env luajit

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local function setup_db(path)
    os.remove(path)
    database.init(path)
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
            offline INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT 0,
            modified_at INTEGER NOT NULL DEFAULT 0
        );


        CREATE TABLE media (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            file_path TEXT NOT NULL,
            duration INTEGER NOT NULL,
            frame_rate REAL NOT NULL,
            width INTEGER DEFAULT 0,
            height INTEGER DEFAULT 0,
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
    ]])

    db:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1);
    ]])

    return db
end

local function create_clip(id, track_id, start_time, duration)
    local conn = database.get_connection()
    local media_id = id .. "_media"

    local media_stmt = conn:prepare([[
        INSERT OR REPLACE INTO media (
            id,
            project_id,
            name,
            file_path,
            duration,
            frame_rate,
            created_at,
            modified_at,
            metadata
        )
        VALUES (?, ?, ?, ?, ?, ?, 0, 0, '{}')
    ]])
    assert(media_stmt, "failed to prepare media insert")
    assert(media_stmt:bind_value(1, media_id))
    assert(media_stmt:bind_value(2, "default_project"))
    assert(media_stmt:bind_value(3, id .. ".mov"))
    assert(media_stmt:bind_value(4, "/tmp/jve/" .. id .. ".mov"))
    assert(media_stmt:bind_value(5, duration))
    assert(media_stmt:bind_value(6, 30.0))
    assert(media_stmt:exec())
    media_stmt:finalize()

    local clip_stmt = conn:prepare([[
        INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
        VALUES (?, ?, ?, ?, ?, 0, ?, 1)
    ]])
    assert(clip_stmt, "failed to prepare clip insert")
    assert(clip_stmt:bind_value(1, id))
    assert(clip_stmt:bind_value(2, track_id))
    assert(clip_stmt:bind_value(3, media_id))
    assert(clip_stmt:bind_value(4, start_time))
    assert(clip_stmt:bind_value(5, duration))
    assert(clip_stmt:bind_value(6, duration))
    assert(clip_stmt:exec())
    clip_stmt:finalize()
end

local function fetch_clip(id)
    local stmt = database.get_connection():prepare([[SELECT start_time, duration FROM clips WHERE id = ?]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local start_time = stmt:value(0)
    local duration = stmt:value(1)
    stmt:finalize()
    return start_time, duration
end

local function clip_count()
    local stmt = database.get_connection():prepare([[SELECT COUNT(*) FROM clips]])
    assert(stmt:exec() and stmt:next())
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local function clip_exists_at(track_id, start_time)
    local stmt = database.get_connection():prepare([[
        SELECT 1 FROM clips WHERE track_id = ? AND start_time = ? LIMIT 1
    ]])
    assert(stmt, "failed to prepare clip lookup")
    assert(stmt:bind_value(1, track_id))
    assert(stmt:bind_value(2, start_time))
    local exists = stmt:exec() and stmt:next()
    stmt:finalize()
    return exists
end

local TEST_DB = "/tmp/jve/test_blade_command.db"
local db = setup_db(TEST_DB)

database.init(TEST_DB) -- ensure database module uses this db
db = database.get_connection()
command_impl.register_commands({}, {}, db)
command_manager.init(db, 'default_sequence', 'default_project')

local timeline_state = require('ui.timeline.timeline_state')

local function reset_clips()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM media")
    create_clip('clip_a', 'track_v1', 0, 1500)
    create_clip('clip_b', 'track_v1', 3000, 1500)
    create_clip('clip_c', 'track_v2', 500, 1200)
    create_clip('clip_d', 'track_v2', 5000, 1500)
    timeline_state.reload_clips()
end

local function execute_batch_split(split_time, clip_ids)
    local json = dkjson
    local specs = {}
    for _, clip in ipairs(clip_ids) do
        table.insert(specs, {
            command_type = "SplitClip",
            parameters = {
                clip_id = clip.id or clip,
                split_time = split_time
            }
        })
    end

    local batch_cmd = Command.create("BatchCommand", "default_project")
    batch_cmd:set_parameter("commands_json", json.encode(specs))
    local ok = command_manager.execute(batch_cmd)
    assert(ok.success, ok.error_message or "Batch split failed")
end

print("=== Blade Command Tests ===\n")

-- Scenario 1: No selection - split all clips under playhead
reset_clips()
timeline_state.set_selection({})
timeline_state.set_playhead_time(1000)
local targets = timeline_state.get_clips_at_time(1000)
assert(#targets == 2, "Expected two clips under playhead")
local before_count = clip_count()
execute_batch_split(1000, targets)
local after_count = clip_count()
assert(after_count == before_count + #targets, "Each split should add one clip")
local start_a, dur_a = fetch_clip('clip_a')
assert(start_a == 0 and dur_a == 1000, "clip_a should be trimmed to first segment")
assert(clip_exists_at('track_v1', 1000), "Second segment of clip_a should exist")
assert(clip_exists_at('track_v2', 1000), "Second segment of clip_c should exist")

-- Scenario 2: Selection limits split targets
reset_clips()
timeline_state.set_selection({{id = 'clip_a'}})
timeline_state.set_playhead_time(1000)
local selected_targets = timeline_state.get_clips_at_time(1000, {'clip_a'})
assert(#selected_targets == 1, "Only selected clip should be targeted")
before_count = clip_count()
execute_batch_split(1000, selected_targets)
after_count = clip_count()
assert(after_count == before_count + #selected_targets, "Split should only add one clip")
local _, dur_c = fetch_clip('clip_c')
assert(dur_c == 1200, "Unselected clip should remain unchanged")

print("✅ Blade splits apply to clips under playhead with selection rules")
