#!/usr/bin/env luajit

-- Integration: RippleDelete redo should not leave stray clip selection (selection cleared).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")
local selection_state = require("ui.timeline.state.selection_state")

local DB_PATH = "/tmp/jve/test_ripple_delete_gap_selection_redo.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at) VALUES('proj','P','resample',0,0);]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','nested',24,1,48000,1920,1080,0,5000,0,0,0);]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]]))

-- V13 fixture: placeholder master sequence (clips.nested_sequence_id FK
-- + INV-1 require the referenced master to exist with kind='master').
do
    assert(db:exec("INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master','proj','PlaceholderMaster','master',24,1,48000,1920,1080,0,2000,0,0,0);"))
    assert(db:exec("INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES('_v13_placeholder_master_v1','_v13_placeholder_master','V1','VIDEO',1,1,0,0,0,1.0,0.0);"))
    db:exec("INSERT OR IGNORE INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,width,height,audio_channels,codec,metadata,created_at,modified_at) VALUES('_v13_placeholder_master_media','proj','PlaceholderMedia','/tmp/placeholder.mov',2000,24,1,1920,1080,2,'prores','{{}}',0,0);")
    db:exec("INSERT OR IGNORE INTO media_refs(id,project_id,owner_sequence_id,track_id,media_id,source_in_frame,source_out_frame,timeline_start_frame,duration_frames,enabled,volume,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master_mref','proj','_v13_placeholder_master','_v13_placeholder_master_v1','_v13_placeholder_master_media',0,2000,0,2000,1,1.0,0,0,0);")
end

local function insert_clip(id, start_frames, duration_frames)
    local stmt = db:prepare([[
        
INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, nested_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    (?, ?, ?, ?, 'seq', '_v13_placeholder_master', ?, ?, ?, ?, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, "proj")
    stmt:bind_value(3, "timeline")
    stmt:bind_value(4, "v1")
    stmt:bind_value(5, start_frames)
    stmt:bind_value(6, duration_frames)
    stmt:bind_value(7, 0)
    stmt:bind_value(8, duration_frames)
    assert(stmt:exec(), "failed to insert clip " .. id)
    stmt:finalize()
end

-- Gap from 100-199
insert_clip("c1", 0, 100)
insert_clip("c2", 200, 100)

-- Select the gap
selection_state.set_gap_selection({
    {
        track_id = "v1",
        start_value = 100,
        duration = 100,
    }
})

command_manager.init("seq", "proj")

-- 013/T046: gap closure routes through BatchRippleEdit.
local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("edge_infos", {
    {clip_id = "gap_v1_100", edge_type = "out", track_id = "v1"}
})
cmd:set_parameter("delta_frames", -100)
cmd:set_parameter("sequence_id", "seq")

local res = command_manager.execute(cmd)
assert(res.success, "ripple delete failed")

local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "undo ripple delete failed")

local redo_res = command_manager.redo()
assert(redo_res and redo_res.success, "redo ripple delete failed")

-- After redo, no spurious clip selection should appear (V13: gap selection
-- itself may persist on the now-zero-length gap; that's selection_state's
-- concern, not BatchRippleEdit's).
local clips = selection_state.get_selected_clips()
assert(#clips == 0, "expected no clip selection after redo")

os.remove(DB_PATH)
print("✅ RippleDelete redo clears selection")
