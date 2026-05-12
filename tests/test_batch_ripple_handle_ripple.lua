#!/usr/bin/env luajit

-- Regression: dragging a clip handle with trim_type="ripple" should behave like a ripple,
-- even if the edge_type is "in" (upstream handle) rather than gap_before.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")

local function seed_db(db_path)
    os.remove(db_path)
    assert(database.init(db_path))
    local db = database.get_connection()
    assert(db:exec(import_schema))

    local function exec(sql)
        assert(db:exec(sql))
    end

    exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at) VALUES('proj','P','resample',0,0);]])
    exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
        VALUES('seq','proj','Seq','sequence',24,1,48000,1920,1080,0,2000,0,0,0);]])
    exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
        VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]])

local function insert_clip(id, start_frames, duration_frames, source_in_frame)
    source_in_frame = source_in_frame or 0
    local source_out_frame = source_in_frame + duration_frames
    exec(string.format([[-- V13 placeholder master sequence (was V8 NULL media_id)
INSERT OR IGNORE INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 1, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT OR IGNORE INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT OR IGNORE INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 1, 0, 1, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('%s', 'proj', '%s', 'v1', '_v13_placeholder_master', 'seq', %d, %d, %d, %d, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0)]],
        id, id, start_frames, duration_frames, source_in_frame, source_out_frame))
end

insert_clip("ripple_target", 200, 100, 120)
insert_clip("downstream", 500, 120)

    command_manager.init("seq", "proj")
    return db
end

local function fetch_start(db, id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. id)
    local start = tonumber(stmt:value(0))
    stmt:finalize()
    return start
end

local function run_case(db_path, delta_frames, expected_target_start, expected_downstream_start)
    local db = seed_db(db_path)
    local cmd = Command.create("BatchRippleEdit", "proj")
    cmd:set_parameter("sequence_id", "seq")
    cmd:set_parameter("edge_infos", {
        {clip_id = "ripple_target", edge_type = "in", track_id = "v1", trim_type = "ripple"}
    })
    cmd:set_parameter("delta_frames", delta_frames)
    
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "BatchRippleEdit handle ripple failed to execute")

    assert(fetch_start(db, "ripple_target") == expected_target_start,
        string.format("Expected ripple_target start=%d, got %d", expected_target_start, fetch_start(db, "ripple_target")))
    assert(fetch_start(db, "downstream") == expected_downstream_start,
        string.format("Expected downstream start=%d, got %d", expected_downstream_start, fetch_start(db, "downstream")))
end

-- Extending upstream handle left should shift clip earlier and push downstream clips.
local EXTEND_DB = "/tmp/jve/test_batch_ripple_handle_ripple_extend.db"
local SHRINK_DB = "/tmp/jve/test_batch_ripple_handle_ripple_shrink.db"

run_case(EXTEND_DB, -60, 200, 560)

-- Shrinking upstream handle right should keep start anchored and pull downstream clips upstream.
run_case(SHRINK_DB, 40, 200, 460)

os.remove(EXTEND_DB)
os.remove(SHRINK_DB)
print("✅ Ripple handle trims extend correctly and anchored shrinks no longer roll the clip")
