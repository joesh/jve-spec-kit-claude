#!/usr/bin/env luajit

-- Basic BatchRippleEdit tests using real command manager.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

function qt_json_encode(_) return "{}" end
function qt_create_single_shot_timer(_, cb) cb(); return {} end

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function run_test(name, layout, edges, delta_ms, expectations)
    local path = os.tmpname() .. ".jvp"
    os.remove(path)
    assert(database.set_path(path))
    local db = database.get_connection()
    _G.db = db

    local schema = [[
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, created_at INTEGER, modified_at INTEGER, settings TEXT);
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

        CREATE TABLE tracks (id TEXT PRIMARY KEY, sequence_id TEXT, name TEXT, track_type TEXT, track_index INTEGER, enabled INTEGER, locked INTEGER, muted INTEGER, soloed INTEGER, volume REAL, pan REAL);
        CREATE TABLE media (id TEXT PRIMARY KEY, project_id TEXT, name TEXT, file_path TEXT, duration INTEGER, frame_rate REAL, width INTEGER, height INTEGER, audio_channels INTEGER, codec TEXT, created_at INTEGER, modified_at INTEGER);
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


        CREATE TABLE commands (id TEXT PRIMARY KEY, parent_id TEXT, parent_sequence_number INTEGER, sequence_number INTEGER, command_type TEXT, command_args TEXT, pre_hash TEXT, post_hash TEXT, timestamp INTEGER, playhead_time INTEGER, selected_clip_ids TEXT, selected_edge_infos TEXT, selected_clip_ids_pre TEXT, selected_edge_infos_pre TEXT);
    ]]

    for stmt in schema:gmatch("[^;]+;") do
        local s = db:prepare(stmt)
        assert(s)
        assert(s:exec())
        s:finalize()
    end

    local inserts = {
        "INSERT INTO projects VALUES ('default_project','Test',0,0,'{}')",
        "INSERT INTO sequences VALUES ('default_sequence','default_project','Seq','timeline',30,1920,1080,0,0,'[]','[]',NULL)"
    }

    for _, track in ipairs(layout.tracks) do
        table.insert(inserts, string.format(
            "INSERT INTO tracks VALUES ('%s', 'default_sequence', 'Track', '%s', 'VIDEO', %d, 1)",
            track.id, track.name or track.id, track.index
        ))
    end

    for _, media in ipairs(layout.media) do
        table.insert(inserts, string.format(
            "INSERT INTO media VALUES ('%s','default_project','%s','/tmp/%s.mov',%d,30,1920,1080,2,'prores',0,0)",
            media.id, media.name or media.id, media.id, media.duration
        ))
    end

    for _, clip in ipairs(layout.clips) do
        table.insert(inserts, string.format(
            "INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id, start_time, duration, source_in, source_out, enabled, offline) VALUES ('%s','default_project','timeline','', '%s','%s',NULL,NULL,'default_sequence',%d,%d,%d,%d,1,0)",
            clip.id, clip.track_id, clip.media_id, clip.start_time, clip.duration,
            clip.source_in or 0, clip.source_out or (clip.source_in or 0) + clip.duration
        ))
    end

    for _, sql in ipairs(inserts) do
        local s = db:prepare(sql)
        assert(s)
        assert(s:exec(), sql)
        s:finalize()
    end

    command_manager.init(db)

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", edges)
    cmd:set_parameter("delta_ms", delta_ms)
    cmd:set_parameter("sequence_id", "default_sequence")

    local result = command_manager.execute(cmd)
    if not result.success then
        os.remove(path)
        error(string.format("%s failed: %s", name, tostring(result.error_message)))
    end

    local load = require("core.database").load_clips
    local clips = load("default_sequence")
    for clip_id, expected in pairs(expectations) do
        for _, clip in ipairs(clips) do
            if clip.id == clip_id then
                if expected.start_time ~= nil then
                    assert_eq(name .. " start_time", clip.start_time, expected.start_time)
                end
                if expected.duration ~= nil then
                    assert_eq(name .. " duration", clip.duration, expected.duration)
                end
                if expected.source_out ~= nil then
                    assert_eq(name .. " source_out", clip.source_out, expected.source_out)
                end
            end
        end
    end

    os.remove(path)
end

-- Basic single-track scenario
run_test(
    "single_track_out_trim_left",
    {
        tracks = {
            {id = "video1", index = 1}
        },
        media = {
            {id = "media_v1", duration = 480000}
        },
        clips = {
            {id = "clip_one", track_id = "video1", media_id = "media_v1", start_time = 0, duration = 1000, source_in = 0, source_out = 1000},
            {id = "clip_two", track_id = "video1", media_id = "media_v1", start_time = 1100, duration = 1000, source_in = 1000, source_out = 2000}
        }
    },
    {
        {clip_id = "clip_one", edge_type = "out", track_id = "video1"}
    },
    -500,
    {
        clip_one = {start_time = 0, duration = 500, source_out = 500},
        clip_two = {start_time = 600}
    }
)

print("✅ basic BatchRippleEdit tests passed")
