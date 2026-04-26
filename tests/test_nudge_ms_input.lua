#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local function setup_db()
    local db_path = "/tmp/jve/test_nudge_ms_input.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at,settings) VALUES('proj','Test','resample',0,0,'{}')]]))

    -- V13 placeholder master sequence (test references nested_sequence_id='mc_test' literally)
    db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('mc_test_media', 'proj', 'placeholder', '_placeholder', 10000, 30, 1, 1920, 1080, 0, 'raw', 0, 0)]]))
    db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('mc_test', 'proj', 'mc_test', 'master', 30, 1, 48000, 1920, 1080, 0, 0)]]))
    db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('mc_test_v1', 'mc_test', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)]]))
    db:exec(string.format([[UPDATE sequences SET default_video_layer_track_id = 'mc_test_v1' WHERE id = 'mc_test']]))
    db:exec(string.format([[INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mc_test_mr', 'proj', 'mc_test', 'mc_test_v1', 'mc_test_media', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0)]]))
    assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','nested',24,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0)
    ]]))
    return db, db_path
end

local function reload_state()
    timeline_state.reset()
    assert(timeline_state.init("seq"), "failed to init timeline state")
end

-- Regression: Nudge should accept ms input (from drag handlers) by converting to Rational.
local db = setup_db()
command_manager.init("seq", "proj")
reload_state()

-- Seed one clip
local clip = Clip.create({
        name = "Clip",
        project_id = "proj",
        track_id = "v1",
        owner_sequence_id = "seq",
        nested_sequence_id = "mc_test",
        timeline_start_frame = 0,
        duration_frames = 48,
        source_in_frame = 0,
        source_out_frame = 48,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
assert(clip ~= nil, "Failed to create clip")
local cmd = Command.create("Nudge", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("fps_numerator", 24)
cmd:set_parameter("fps_denominator", 1)
cmd:set_parameter("selected_clip_ids", {clip})
-- Nudge by 24 frames (1 second at 24fps)
local nudge_amount = 24
cmd:set_parameter("nudge_amount", nudge_amount)

local res = command_manager.execute(cmd)
assert(res.success, "Nudge with ms payload should succeed")

local updated = Clip.load(clip, db)
assert(updated.timeline_start == 24, "Clip should move forward by ~24 frames for 1000ms at 24fps")

-- Undo to keep DB tidy
local undo_cmd = Command.deserialize(res.result_data):create_undo()
local undo_res = command_manager.execute(undo_cmd)
assert(undo_res.success, "Undo Nudge should succeed")

print("✅ nudge accepts ms payload via conversion to Rational")
