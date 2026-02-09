#!/usr/bin/env luajit

-- Integration: RippleDelete undo should restore gap selection (no stray clip selection).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")
local Rational = require("core.rational")
local selection_state = require("ui.timeline.state.selection_state")

local DB_PATH = "/tmp/jve/test_ripple_delete_gap_selection_restore.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at) VALUES('proj','P',strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','timeline',24,1,48000,1920,1080,0,5000,0,strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]]))

local function insert_clip(id, start_frames, duration_frames)
    local stmt = db:prepare([[
        INSERT INTO clips(
            id, project_id, clip_kind, name, track_id, media_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, created_at, modified_at
        )
        VALUES(?,?,?,?,?,?,?,?,?,?,24,1,1,strftime('%s','now'),strftime('%s','now'))
    ]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, "proj")
    stmt:bind_value(3, "timeline")
    stmt:bind_value(4, id)
    stmt:bind_value(5, "v1")
    stmt:bind_value(6, nil)
    stmt:bind_value(7, start_frames)
    stmt:bind_value(8, duration_frames)
    stmt:bind_value(9, 0)
    stmt:bind_value(10, duration_frames)
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

local cmd = Command.create("RippleDelete", "proj")
cmd:set_parameter("track_id", "v1")
cmd:set_parameter("gap_start", 100)
cmd:set_parameter("gap_duration", 100)
cmd:set_parameter("sequence_id", "seq")

local res = command_manager.execute(cmd)
assert(res.success, "ripple delete failed")

-- Undo
local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "undo ripple delete failed: " .. tostring(undo_res.error_message))

-- Selection should be the original gap, with no clip selection
local gaps = selection_state.get_selected_gaps()
assert(#gaps == 1, "expected one selected gap after undo")
assert(gaps[0] == nil) -- ensure array-like
local g = gaps[1]
assert(g.track_id == "v1", "gap track mismatch")
assert(g.start_value == 100 and g.duration == 100, "gap values not restored")
local clips = selection_state.get_selected_clips()
assert(#clips == 0, "clip selection should be empty after restoring gap selection")

os.remove(DB_PATH)
print("✅ RippleDelete undo restores gap selection (no stray clip selection)")
