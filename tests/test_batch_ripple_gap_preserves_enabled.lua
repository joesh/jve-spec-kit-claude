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
    INSERT INTO projects(id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences(
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES('default_sequence', 'default_project', 'Timeline', 'nested',
           1000, 1, 48000, 1920, 1080, 0, 20000, 0, %d, %d);

    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'default_project', 'placeholder', '_placeholder', 2000, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'default_project', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'default_project', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('left', 'default_project', 'Left', 'track_v1', '_v13_placeholder_master', 'default_sequence', 0, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('right', 'default_project', 'Right', 'track_v1', '_v13_placeholder_master', 'default_sequence', 5000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))
)

command_manager.init("default_sequence", "default_project")

-- left ends at 2000, gap is 2000..5000 → gap_id = gap_track_v1_2000
local gap_id = string.format("gap_%s_%d", "track_v1", 2000)

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "out", track_id = "track_v1"},
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
