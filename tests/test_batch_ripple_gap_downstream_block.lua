#!/usr/bin/env luajit

-- Regression: closing a gap via BatchRippleEdit should not be blocked by
-- downstream clips that are also moving as part of the ripple shift.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")

local DB_PATH = "/tmp/jve/test_batch_ripple_gap_downstream_block.db"
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
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'default_project', 'placeholder', '_placeholder', 2200, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'default_project', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'default_project', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 2200, 0, 2200, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('v1_anchor', 'default_project', 'V1 Anchor', 'track_v1', '_v13_placeholder_master', 'default_sequence', 1000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v1_middle', 'default_project', 'V1 Middle', 'track_v1', '_v13_placeholder_master', 'default_sequence', 7000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v1_downstream', 'default_project', 'V1 Downstream', 'track_v1', '_v13_placeholder_master', 'default_sequence', 11000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v2_left', 'default_project', 'V2 Left', 'track_v2', '_v13_placeholder_master', 'default_sequence', 1000, 2200, 0, 2200, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v2_right', 'default_project', 'V2 Right', 'track_v2', '_v13_placeholder_master', 'default_sequence', 7200, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now))
)

command_manager.init("default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "gap_track_v1_3000", edge_type = "in", track_id = "track_v1"},
    {clip_id = "gap_track_v2_3200", edge_type = "in", track_id = "track_v2"},
})
cmd:set_parameter("delta_frames", 5000) -- Drag gap in-edge RIGHT beyond available gap (expect clamp).
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should succeed")

local function fetch_start(id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

-- Expect the full 4s gap to close: middle clip lands at 3000, downstream clip shifts equally.
assert(fetch_start("v1_middle") == 3000,
    string.format("V1 middle clip should move left by full gap; expected 3000, got %d", fetch_start("v1_middle")))
assert(fetch_start("v1_downstream") == 7000,
    string.format("Downstream clip should shift by same delta; expected 7000, got %d", fetch_start("v1_downstream")))
assert(fetch_start("v2_right") == 3200,
    string.format("V2 clip should stay in sync with clamped delta; expected 3200, got %d", fetch_start("v2_right")))

os.remove(DB_PATH)
print("✅ Batch ripple ignores moving downstream clips when clamping shifts")
