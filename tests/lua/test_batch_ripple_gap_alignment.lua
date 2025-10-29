#!/usr/bin/env luajit

-- Regression coverage for gap alignment scenarios using the real command manager

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

local function create_schema(db)
    local schema = [[
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, created_at INTEGER, modified_at INTEGER, settings TEXT);
        CREATE TABLE sequences (id TEXT PRIMARY KEY, project_id TEXT, name TEXT, frame_rate REAL, width INTEGER, height INTEGER, timecode_start INTEGER, playhead_time INTEGER, selected_clip_ids TEXT DEFAULT '[]', selected_edge_infos TEXT DEFAULT '[]', current_sequence_number INTEGER);
        CREATE TABLE tracks (id TEXT PRIMARY KEY, sequence_id TEXT, name TEXT, track_type TEXT, track_index INTEGER, enabled INTEGER);
        CREATE TABLE media (id TEXT PRIMARY KEY, project_id TEXT, name TEXT, file_path TEXT, duration INTEGER, frame_rate REAL, width INTEGER, height INTEGER, audio_channels INTEGER, codec TEXT, created_at INTEGER, modified_at INTEGER);
        CREATE TABLE clips (id TEXT PRIMARY KEY, track_id TEXT, media_id TEXT, start_time INTEGER, duration INTEGER, source_in INTEGER, source_out INTEGER, enabled INTEGER);
        CREATE TABLE commands (id TEXT PRIMARY KEY, parent_id TEXT, parent_sequence_number INTEGER, sequence_number INTEGER, command_type TEXT, command_args TEXT, pre_hash TEXT, post_hash TEXT, timestamp INTEGER, playhead_time INTEGER, selected_clip_ids TEXT, selected_edge_infos TEXT, selected_clip_ids_pre TEXT, selected_edge_infos_pre TEXT);
    ]]

    for stmt in schema:gmatch("[^;]+;") do
        local prepared = assert(db:prepare(stmt))
        assert(prepared:exec())
        prepared:finalize()
    end
end

local function seed_project(db, layout)
    local statements = {
        "INSERT INTO projects VALUES ('default_project','GapAlign',0,0,'{}')",
        "INSERT INTO sequences VALUES ('default_sequence','default_project','Seq','timeline',30,1920,1080,0,0,'[]','[]',NULL)"
    }

    for _, track in ipairs(layout.tracks) do
        table.insert(statements, string.format(
            "INSERT INTO tracks VALUES ('%s','default_sequence','%s','VIDEO',%d,1)",
            track.id, track.name or track.id, track.index
        ))
    end

    for _, media in ipairs(layout.media) do
        table.insert(statements, string.format(
            "INSERT INTO media VALUES ('%s','default_project','%s','/tmp/%s.mov',%d,30,1920,1080,2,'prores',0,0)",
            media.id, media.name or media.id, media.id, media.duration
        ))
    end

    for _, clip in ipairs(layout.clips) do
        table.insert(statements, string.format(
            "INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id, start_time, duration, source_in, source_out, enabled, offline) VALUES ('%s','default_project','timeline','', '%s','%s',NULL,NULL,'default_sequence',%d,%d,%d,%d,1,0)",
            clip.id, clip.track_id, clip.media_id, clip.start_time, clip.duration,
            clip.source_in or 0, clip.source_out or (clip.source_in or 0) + clip.duration
        ))
    end

    for _, sql in ipairs(statements) do
        local stmt = assert(db:prepare(sql))
        assert(stmt:exec())
        stmt:finalize()
    end
end

local function run_scenario(name, layout, edges, delta_ms, expectations)
    local path = os.tmpname() .. ".db"
    os.remove(path)
    assert(database.set_path(path))
    local db = database.get_connection()
    _G.db = db

    create_schema(db)
    seed_project(db, layout)

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

    local fetch = function(clip_id)
        local stmt = assert(db:prepare(string.format(
            "SELECT start_time, duration, source_in, source_out FROM clips WHERE id='%s'", clip_id)))
        assert(stmt:exec())
        assert(stmt:next(), "missing clip " .. clip_id)
        local clip = {
            start_time = stmt:value(0),
            duration = stmt:value(1),
            source_in = stmt:value(2),
            source_out = stmt:value(3)
        }
        stmt:finalize()
        return clip
    end

    for clip_id, expect in pairs(expectations) do
        local clip = fetch(clip_id)
        if expect.start_time ~= nil then
            assert_eq(name .. " start " .. clip_id, clip.start_time, expect.start_time)
        end
        if expect.duration ~= nil then
            assert_eq(name .. " duration " .. clip_id, clip.duration, expect.duration)
        end
        if expect.source_in ~= nil then
            assert_eq(name .. " source_in " .. clip_id, clip.source_in, expect.source_in)
        end
        if expect.source_out ~= nil then
            assert_eq(name .. " source_out " .. clip_id, clip.source_out, expect.source_out)
        end
    end

    os.remove(path)
end

local tracks = {
    {id = "track_v1", index = 1},
    {id = "track_v2", index = 2}
}

local media = {
    {id = "media1", duration = 100000},
    {id = "media2", duration = 100000}
}

run_scenario(
    "clip_out_gap_before",
    {
        tracks = tracks,
        media = media,
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 5000, duration = 4000, source_out = 7000},
            {id = "clip_v2_a", track_id = "track_v2", media_id = "media2", start_time = 2000, duration = 3000, source_out = 3000}
        }
    },
    {
        {clip_id = "clip_v2_a", edge_type = "out", track_id = "track_v2"},
        {clip_id = "clip_v1_b", edge_type = "gap_before", track_id = "track_v1"}
    },
    -600,
    {
        clip_v1_b = {start_time = 4400},
        clip_v2_a = {duration = 2400, source_out = 2400}
    }
)

run_scenario(
    "gap_before_clip_out",
    {
        tracks = tracks,
        media = media,
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 5000, duration = 4000, source_out = 7000},
            {id = "clip_v2_a", track_id = "track_v2", media_id = "media2", start_time = 2000, duration = 3000, source_out = 3000}
        }
    },
    {
        {clip_id = "clip_v1_b", edge_type = "gap_before", track_id = "track_v1"},
        {clip_id = "clip_v2_a", edge_type = "out", track_id = "track_v2"}
    },
    -600,
    {
        clip_v1_b = {start_time = 4400},
        clip_v2_a = {duration = 2400, source_out = 2400}
    }
)

run_scenario(
    "clip_out_gap_after",
    {
        tracks = tracks,
        media = media,
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 5000, duration = 4000, source_out = 7000},
            {id = "clip_v2_a", track_id = "track_v2", media_id = "media2", start_time = 2000, duration = 3000, source_out = 3000}
        }
    },
    {
        {clip_id = "clip_v2_a", edge_type = "out", track_id = "track_v2"},
        {clip_id = "clip_v1_a", edge_type = "gap_after", track_id = "track_v1"}
    },
    -600,
    {
        clip_v1_b = {start_time = 4400},
        clip_v2_a = {duration = 2400, source_out = 2400}
    }
)

run_scenario(
    "gap_after_clip_out",
    {
        tracks = tracks,
        media = media,
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 5000, duration = 4000, source_out = 7000},
            {id = "clip_v2_a", track_id = "track_v2", media_id = "media2", start_time = 2000, duration = 3000, source_out = 3000}
        }
    },
    {
        {clip_id = "clip_v1_a", edge_type = "gap_after", track_id = "track_v1"},
        {clip_id = "clip_v2_a", edge_type = "out", track_id = "track_v2"}
    },
    -600,
    {
        clip_v1_b = {start_time = 4400},
        clip_v2_a = {duration = 2400, source_out = 2400}
    }
)

run_scenario(
    "gap_only_drag",
    {
        tracks = {{id = "track_v1", index = 1}},
        media = {{id = "media1", duration = 100000}},
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 5000, duration = 4000, source_out = 7000}
        }
    },
    {
        {clip_id = "clip_v1_b", edge_type = "gap_before", track_id = "track_v1"}
    },
    -400,
    {
        clip_v1_b = {start_time = 4600}
    }
)

run_scenario(
    "gap_before_downstream_clip",
    {
        tracks = tracks,
        media = media,
        clips = {
            {id = "clip_v1_a", track_id = "track_v1", media_id = "media1", start_time = 0, duration = 3000, source_out = 3000},
            {id = "clip_v1_b", track_id = "track_v1", media_id = "media1", start_time = 4500, duration = 4000, source_out = 6500},
            {id = "clip_v2_a", track_id = "track_v2", media_id = "media2", start_time = 7000, duration = 2000, source_out = 2000}
        }
    },
    {
        {clip_id = "clip_v2_a", edge_type = "out", track_id = "track_v2"},
        {clip_id = "clip_v1_b", edge_type = "gap_before", track_id = "track_v1"}
    },
    -500,
    {
        clip_v1_b = {start_time = 4000},
        clip_v2_a = {duration = 1500, source_out = 1500}
    }
)

print("✅ BatchRipple gap alignment tests passed")
