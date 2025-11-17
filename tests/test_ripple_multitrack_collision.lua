#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local function setup()
    local db_path = "/tmp/jve/test_ripple_multitrack_collision.db"
    os.remove(db_path)
    assert(database.init(db_path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))

    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);

        INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height, viewport_duration)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 1920, 1080, 20000);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1);

        INSERT INTO media (id, project_id, name, duration, frame_rate, width, height)
        VALUES ('media1', 'default_project', 'Media', 10000, 30.0, 1920, 1080);

        -- Track 1: single clip with gap before
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           start_time, duration, source_in, source_out, enabled, offline,
                           created_at, modified_at)
        VALUES ('clip_v1_right', 'default_project', 'timeline', 'V1 Right', 'track_v1', 'media1', 'default_sequence',
                5000, 2000, 0, 2000, 1, 0, %d, %d);

        -- Track 2: upstream and downstream clips
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           start_time, duration, source_in, source_out, enabled, offline,
                           created_at, modified_at)
        VALUES ('clip_v2_left', 'default_project', 'timeline', 'V2 Left', 'track_v2', 'media1', 'default_sequence',
                0, 2000, 0, 2000, 1, 0, %d, %d),
               ('clip_v2_right', 'default_project', 'timeline', 'V2 Right', 'track_v2', 'media1', 'default_sequence',
                5000, 2000, 2000, 4000, 1, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now)))

    command_manager.init(db, "default_sequence", "default_project")
    return db
end

local function fetch_start(db, id)
    local stmt = db:prepare("SELECT start_time FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

local db = setup()

-- Attempt to close a 3000ms gap (actual gap is 5000ms→0ms before clip_v1_right),
-- but ripple shift must not drag V2 Right into V2 Left.
local cmd = Command.create("RippleEdit", "default_project")
cmd:set_parameter("edge_info", {clip_id = "clip_v1_right", edge_type = "gap_before", track_id = "track_v1"})
cmd:set_parameter("delta_ms", -3000)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "RippleEdit failed")

-- Track 2 downstream clip should clamp to butt against upstream (0ms gap) not overlap
local start_v2_right = fetch_start(db, "clip_v2_right")
assert(start_v2_right == 2000, string.format("multitrack ripple should clamp to avoid overlapping V2 Left (got %d)", start_v2_right))

print("✅ Multitrack ripple clamp prevents overlap onto upstream clip on another track")
