#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local timeline_view_drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local function remove_best_effort(path)
    if not path or path == "" then
        return
    end
    os.remove(path)
end

local function cleanup_db_artifacts(db_path)
    remove_best_effort(db_path)
    remove_best_effort(db_path .. "-wal")
    remove_best_effort(db_path .. "-shm")
    os.execute(string.format("rm -rf %q", db_path .. ".events"))
end

-- Setup DB and state
local db_path = "/tmp/jve/test_timeline_drag_copy.db"
cleanup_db_artifacts(db_path)
database.set_path(db_path)
local db = database.get_connection()
db:exec(import_schema)

db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at,settings) VALUES('proj','Test','resample',0,0,'{}')]])

    -- V13 placeholder master sequence (test references nested_sequence_id='mc_test' literally)
    db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('mc_test_media', 'proj', 'placeholder', '_placeholder', 10000, 30, 1, 1920, 1080, 0, 'raw', 0, 0)]]))
    db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('mc_test', 'proj', 'mc_test', 'master', 30, 1, 48000, 1920, 1080, 0, 0)]]))
    db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('mc_test_v1', 'mc_test', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)]]))
    db:exec(string.format([[UPDATE sequences SET default_video_layer_track_id = 'mc_test_v1' WHERE id = 'mc_test']]))
    db:exec(string.format([[INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mc_test_mr', 'proj', 'mc_test', 'mc_test_v1', 'mc_test_media', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0)]]))
db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','nested',30,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]])
db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('a1','seq','A1','AUDIO',1,1,0,0,0,1.0,0.0),
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0)
    ]])
db:exec([[INSERT INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,created_at,modified_at)
          VALUES('media1','proj','Media1','/tmp/test.mov',1000,30,1,0,0)]])

command_manager.init('seq', 'proj')
timeline_state.init('seq')

-- Create initial clip on V1
local clip1 = Clip.create({
        name = "Clip1",
        project_id = "proj",
        track_id = "v1",
        owner_sequence_id = "seq",
        nested_sequence_id = "mc_test",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
assert(clip1 ~= nil, "Failed to create clip1")
timeline_state.reload_clips("seq")

-- Mock View Object
local mock_view = {
    state = timeline_state,
    widget = {}, -- dummy
    get_track_id_at_y = function() return 'v2' end -- Simulate drop on V2
}

-- timeline_view_drag_handler expects global `timeline.get_dimensions`.
_G.timeline = {
    get_dimensions = function() return 1920, 1080 end
}

-- Define drag state
local drag_state = {
    type = "clips",
    start_y = 0,
    current_y = 100,
    delta_ms = 1000, -- Shift by 1 second (30 frames at 30fps)
    delta_frames = 30,
    clips = {{id = clip1}},
    anchor_clip_id = clip1,
    alt_copy = true
}

timeline_view_drag_handler.handle_release(mock_view, drag_state)

-- Original clip should still exist on V1 at 0
local loaded_clip1 = Clip.load(clip1, db)
assert(loaded_clip1, "Original clip should exist")
assert(loaded_clip1.track_id == 'v1', "Original clip should stay on V1")
assert(loaded_clip1.timeline_start == 0, "Original clip should stay at 0")

-- New clip should exist on V2 at 30 frames
local all_clips = database.load_clips("seq")
local new_clip = nil
for _, c in ipairs(all_clips) do
    if c.id ~= clip1 then
        new_clip = c
        break
    end
end

assert(new_clip, "A new clip should have been created (Copy)")
assert(new_clip.track_id == 'v2', "New clip should be on V2")
assert(new_clip.timeline_start == 30, "New clip should be at 30 frames (got " .. tostring(new_clip.timeline_start) .. ")")
-- V13: clips reference master sequences (not media directly). Equivalent
-- "same source" check is on nested_sequence_id.
assert(new_clip.nested_sequence_id ~= nil and new_clip.nested_sequence_id ~= "",
    "New clip should reference a master sequence (V13 nested_sequence_id)")

cleanup_db_artifacts(db_path)
print("✅ Test passed: Alt-drag copied clip instead of moving it")

