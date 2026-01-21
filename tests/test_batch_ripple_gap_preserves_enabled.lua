#!/usr/bin/env luajit

-- Regression: closing a gap while the adjacent clip edge is selected must not
-- toggle that clip's enabled flag.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")

local DB_PATH = "/tmp/jve/test_batch_ripple_gap_preserves_enabled.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences(
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES('default_sequence', 'default_project', 'Timeline', 'timeline',
           1000, 1, 48000, 1920, 1080, 0, 20000, 0, %d, %d);

    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                      timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                      fps_numerator, fps_denominator, enabled, created_at, modified_at)
    VALUES
        ('left',  'default_project', 'timeline', 'Left',  'track_v1', NULL, 'default_sequence', 0,    2000, 0, 2000, 1000, 1, 1, %d, %d),
        ('right', 'default_project', 'timeline', 'Right', 'track_v1', NULL, 'default_sequence', 5000, 2000, 0, 2000, 1000, 1, 1, %d, %d);
]], now, now, now, now, now, now, now, now))
)

command_manager.init("default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "right", edge_type = "gap_before", track_id = "track_v1"},
})
cmd:set_parameter("delta_frames", -3000) -- Drag ] left to close the 3s gap.
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should succeed")

local function fetch_fields(id)
    local stmt = db:prepare("SELECT timeline_start_frame, enabled FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(id))
    local start_frame = tonumber(stmt:value(0))
    local enabled = tonumber(stmt:value(1))
    stmt:finalize()
    return start_frame, enabled
end

local start_frame, enabled = fetch_fields("right")
assert(start_frame < 5000,
    string.format("Right clip should move left to reduce the gap; expected < 5000, got %d", start_frame))
assert(enabled == 1,
    string.format("Right clip should remain enabled after gap ripple; got enabled=%d", enabled))

os.remove(DB_PATH)
print("✅ Gap ripple keeps adjacent clips enabled even when their edge is selected")
