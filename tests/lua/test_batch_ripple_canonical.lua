#!/usr/bin/env luajit

-- Regression tests for BatchRippleEdit using the real command manager.
-- Scenarios reproduce canonical edge combinations that previously clamped to zero.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

if not _G.qt_json_encode then
    local function encode_value(v)
        local t = type(v)
        if t == "string" then
            return string.format("\"%s\"", v:gsub("\\", "\\\\"):gsub("\"", "\\\""))
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "table" then
            local is_array = true
            local count = 0
            for k, _ in pairs(v) do
                count = count + 1
                if type(k) ~= "number" then
                    is_array = false
                end
            end
            if is_array then
                local parts = {}
                for i = 1, count do
                    parts[i] = encode_value(v[i])
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                local parts = {}
                for k, val in pairs(v) do
                    table.insert(parts, string.format("\"%s\":%s", tostring(k), encode_value(val)))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        elseif t == "nil" then
            return "null"
        else
            error("Unsupported type for json encode: " .. t)
        end
    end

    function _G.qt_json_encode(value)
        return encode_value(value)
    end
end

if not _G.qt_create_single_shot_timer then
    function _G.qt_create_single_shot_timer(_, callback)
        callback()
        return {}
    end
end

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function setup_database(layout)
    local tmp_path = os.tmpname() .. ".db"
    os.remove(tmp_path)

    assert(database.set_path(tmp_path), "failed to open sqlite database")
    local db = database.get_connection()
    _G.db = db

    local create_statements = {
        [[CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER,
            modified_at INTEGER,
            settings TEXT
        )]],
        [[CREATE TABLE IF NOT EXISTS sequences (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'timeline',
            frame_rate REAL NOT NULL,
            audio_sample_rate INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            timecode_start_frame INTEGER DEFAULT 0,
            playhead_frame INTEGER DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            viewport_start_frame INTEGER NOT NULL DEFAULT 0,
            viewport_duration_value_frames INTEGER NOT NULL DEFAULT 240,
            mark_in_frame INTEGER,
            mark_out_frame INTEGER,
            current_sequence_number INTEGER
        )]],
        [[CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            name TEXT NOT NULL,
            track_type TEXT NOT NULL,
            timebase_type TEXT NOT NULL,
            timebase_rate REAL NOT NULL,
            track_index INTEGER NOT NULL,
            enabled INTEGER DEFAULT 1,
            locked INTEGER DEFAULT 0,
            muted INTEGER DEFAULT 0,
            soloed INTEGER DEFAULT 0,
            volume REAL DEFAULT 1.0,
            pan REAL DEFAULT 0.0
        )]],
        [[CREATE TABLE IF NOT EXISTS media (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            file_path TEXT NOT NULL,
            duration_value INTEGER,
            timebase_type TEXT NOT NULL,
            timebase_rate REAL NOT NULL,
            frame_rate REAL,
            width INTEGER,
            height INTEGER,
            audio_channels INTEGER,
            codec TEXT,
            created_at INTEGER,
            modified_at INTEGER
        )]],
        [[CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            media_id TEXT,
            start_value INTEGER NOT NULL,
            duration_value INTEGER NOT NULL,
            source_in_value_value INTEGER NOT NULL,
            source_out_value_value INTEGER NOT NULL,
            timebase_type TEXT NOT NULL,
            timebase_rate REAL NOT NULL,
            enabled INTEGER DEFAULT 1
        )]],
        [[CREATE TABLE IF NOT EXISTS commands (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            parent_sequence_number INTEGER,
            sequence_number INTEGER UNIQUE,
            command_type TEXT NOT NULL,
            command_args TEXT,
            pre_hash TEXT,
            post_hash TEXT,
            timestamp INTEGER,
            playhead_value INTEGER DEFAULT 0,
            playhead_rate REAL DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            selected_clip_ids_pre TEXT DEFAULT '[]',
            selected_edge_infos_pre TEXT DEFAULT '[]'
        )]]
    }

    for _, stmt_sql in ipairs(create_statements) do
        local stmt, err = db:prepare(stmt_sql)
        assert(stmt, "failed to prepare schema statement: " .. tostring(err))
        assert(stmt:exec(), "failed to exec schema statement: " .. tostring(stmt:last_error()))
        stmt:finalize()
    end

    local media = layout.media or {
        {id = "media_v1", duration_value = 48000},
        {id = "media_v2", duration_value = 48000},
    }

    local tracks = layout.tracks or {
        {id = "video1", name = "V1", track_type = "VIDEO", track_index = 1},
        {id = "video2", name = "V2", track_type = "VIDEO", track_index = 2},
    }

    local inserts = {
        "INSERT INTO projects (id, name, created_at, modified_at, settings) VALUES ('default_project', 'Test Project', 0, 0, '{}')",
        "INSERT INTO sequences (id, project_id, name, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_frame, selected_clip_ids, selected_edge_infos) VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 48000, 1920, 1080, 0, 0, '[]', '[]')"
    }

    for _, track in ipairs(tracks) do
        table.insert(inserts, string.format(
            "INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('%s', 'default_sequence', '%s', '%s', '%s', %.3f, %d, 1, 0, 0, 0, 1.0, 0.0)",
            track.id, track.name or track.id, track.track_type, track.timebase_type or "video_frames", track.timebase_rate or 30.0, track.track_index
        ))
    end

    for _, m in ipairs(media) do
        table.insert(inserts, string.format(
            "INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at) VALUES ('%s', 'default_project', '%s', '/tmp/%s.mov', %d, '%s', %.3f, 30.0, 1920, 1080, 2, 'prores', 0, 0)",
            m.id, m.name or m.id, m.id, m.duration_value, m.timebase_type or \"video_frames\", m.timebase_rate or 30.0
        ))
    end

    for _, clip in ipairs(layout.clips) do
        table.insert(inserts, string.format(
            "INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value_value, source_out_value_value, timebase_type, timebase_rate, enabled) VALUES ('%s', '%s', '%s', %d, %d, %d, %d, '%s', %.3f, 1)",
            clip.id, clip.track_id, clip.media_id, clip.start_value, clip.duration_value, clip.source_in_value or 0, clip.source_out_value or (clip.source_in_value or 0) + clip.duration_value, clip.timebase_type or "video_frames", clip.timebase_rate or 30.0
        ))
    end

    for _, sql in ipairs(inserts) do
        local stmt, err = db:prepare(sql)
        assert(stmt, "failed to prepare seed statement: " .. tostring(err))
        assert(stmt:exec(), "failed to exec seed statement: " .. tostring(stmt:last_error()))
        stmt:finalize()
    end

    command_manager.init(db)
    return tmp_path, db
end

local function teardown_database(db_path)
    local db = database.get_connection()
    if db and db.close then
        db:close()
    end
    os.remove(db_path)
end

local function fetch_clip(db, clip_id)
    local stmt = assert(db:prepare(string.format(
        "SELECT start_value, duration_value, source_in_value, source_out_value FROM clips WHERE id = '%s'", clip_id)))
    assert(stmt:exec() and stmt:next(), "failed to fetch clip " .. clip_id)
    local clip = {
        start_value = stmt:value(0),
        duration_value = stmt:value(1),
        source_in_value = stmt:value(2),
        source_out_value = stmt:value(3)
    }
    stmt:finalize()
    return clip
end

local function run_scenario(scenario)
    local path, db = setup_database(scenario.layout)

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", scenario.edges)
    cmd:set_parameter("delta_ms", scenario.delta_ms)
    cmd:set_parameter("sequence_id", "default_sequence")

    -- Debug ranges for first scenario before execution
    if scenario.debug_ranges then
        local constraints = require('core.timeline_constraints')
        local ClipModel = require('models.clip')
        local clips = database.load_clips("default_sequence")
        for _, debug_clip in ipairs(scenario.debug_ranges) do
            local clip_obj = ClipModel.load(debug_clip.clip_id, db)
            local range = constraints.calculate_trim_range(clip_obj, debug_clip.edge_type, clips, false, true)
            io.stderr:write(string.format("%s: %s edge range min=%d max=%d\n", scenario.name, debug_clip.clip_id, range.min_delta, range.max_delta))
        end
    end

    local result = command_manager.execute(cmd)
    if not result.success then
        teardown_database(path)
        error(string.format("Scenario '%s' failed: %s", scenario.name, tostring(result.error_message)))
    end

    for clip_id, expected in pairs(scenario.expect) do
        local clip = fetch_clip(db, clip_id)
        if expected.start_value ~= nil then
            assert_eq(string.format("%s: start_value", scenario.name), clip.start_value, expected.start_value)
        end
        if expected.duration_value ~= nil then
            assert_eq(string.format("%s: duration_value", scenario.name), clip.duration_value, expected.duration_value)
        end
        if expected.source_in_value ~= nil then
            assert_eq(string.format("%s: source_in_value", scenario.name), clip.source_in_value, expected.source_in_value)
        end
        if expected.source_out_value ~= nil then
            assert_eq(string.format("%s: source_out_value", scenario.name), clip.source_out_value, expected.source_out_value)
        end
    end

    teardown_database(path)
end

local scenarios = {
    {
        name = "gap_bracket_trim_left",
        layout = {
            clips = {
                {id = "clip_v1_first", track_id = "video1", media_id = "media_v1", start_value = 0, duration_value = 2000, source_in_value = 0, source_out_value = 2000},
                {id = "clip_v1_second", track_id = "video1", media_id = "media_v1", start_value = 3000, duration_value = 2000, source_in_value = 2000, source_out_value = 4000},
                {id = "clip_v2_mid", track_id = "video2", media_id = "media_v2", start_value = 1000, duration_value = 2000, source_in_value = 1000, source_out_value = 3000}
            }
        },
        edges = {
            {clip_id = "clip_v1_second", edge_type = "gap_before", track_id = "video1"},
            {clip_id = "clip_v2_mid", edge_type = "in", track_id = "video2"}
        },
        delta_ms = 1000,
        expect = {
            clip_v1_second = {start_value = 2000, duration_value = 2000},
            clip_v2_mid = {duration_value = 1000, source_in_value = 2000}
        }
    },
    {
        name = "gap_bracket_out_trim_left",
        layout = {
            clips = {
                {id = "clip_v1_first", track_id = "video1", media_id = "media_v1", start_value = 0, duration_value = 2000, source_in_value = 0, source_out_value = 2000},
                {id = "clip_v1_second", track_id = "video1", media_id = "media_v1", start_value = 3000, duration_value = 2000, source_in_value = 2000, source_out_value = 4000},
                {id = "clip_v2_mid", track_id = "video2", media_id = "media_v2", start_value = 1000, duration_value = 3000, source_in_value = 0, source_out_value = 3000}
            }
        },
        edges = {
            {clip_id = "clip_v1_second", edge_type = "gap_before", track_id = "video1"},
            {clip_id = "clip_v2_mid", edge_type = "out", track_id = "video2"}
        },
        delta_ms = -1000,
        expect = {
            clip_v1_second = {start_value = 2000, duration_value = 2000},
            clip_v2_mid = {duration_value = 2000, source_out_value = 2000}
        }
    },
    {
        name = "single_track_out_trim_left",
        layout = {
            clips = {
                {id = "clip_one", track_id = "video1", media_id = "media_v1", start_value = 0, duration_value = 1000, source_in_value = 0, source_out_value = 1000},
                {id = "clip_two", track_id = "video1", media_id = "media_v1", start_value = 1100, duration_value = 1000, source_in_value = 1000, source_out_value = 2000}
            }
        },
        edges = {
            {clip_id = "clip_one", edge_type = "out", track_id = "video1"}
        },
        delta_ms = -500,
        expect = {
            clip_one = {start_value = 0, duration_value = 500, source_out_value = 500},
            clip_two = {start_value = 600}
        }
    },
    {
        name = "dual_out_trim_left",
        layout = {
            clips = {
                {id = "clip_one", track_id = "video1", media_id = "media_v1", start_value = 0, duration_value = 1000, source_in_value = 0, source_out_value = 1000},
                {id = "clip_two", track_id = "video1", media_id = "media_v1", start_value = 1100, duration_value = 1000, source_in_value = 1000, source_out_value = 2000}
            }
        },
        edges = {
            {clip_id = "clip_one", edge_type = "out", track_id = "video1"},
            {clip_id = "clip_two", edge_type = "out", track_id = "video1"}
        },
        delta_ms = -500,
        expect = {
            clip_one = {start_value = 0, duration_value = 500, source_out_value = 500},
            clip_two = {start_value = 600, duration_value = 500, source_out_value = 1500}
        }
    }
}

for _, scenario in ipairs(scenarios) do
    run_scenario(scenario)
end

print("✅ BatchRippleEdit canonical scenarios passed")
