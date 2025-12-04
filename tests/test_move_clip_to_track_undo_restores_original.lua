#!/usr/bin/env luajit

-- Regression: MoveClipToTrack must undo back to original track/position (including occlusion restoration).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Rational = require("core.rational")
local import_schema = require("import_schema")
local Command = require("command")

local DB_PATH = "/tmp/jve/test_move_clip_undo.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Minimal project/sequence/track setup
assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at) VALUES('proj','P',strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','timeline',24,1,48000,1920,1080,0,10000,0,strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
                        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0);]]))

local function insert_clip(id, track, start_frames, duration_frames)
    local stmt = db:prepare([[INSERT INTO clips(
        id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, created_at, modified_at
    ) VALUES(?,?,?,?,?,?,?,?,?,?,24,1,1,strftime('%s','now'),strftime('%s','now'))]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, "proj")
    stmt:bind_value(3, "timeline")
    stmt:bind_value(4, id)
    stmt:bind_value(5, track)
    stmt:bind_value(6, nil)
    stmt:bind_value(7, start_frames)
    stmt:bind_value(8, duration_frames)
    stmt:bind_value(9, 0)
    stmt:bind_value(10, duration_frames)
    assert(stmt:exec(), "failed to insert clip " .. id)
    stmt:finalize()
end

-- c1 on v1, c2 on v2 overlapping so move will trigger occlusion handling on v2
insert_clip("c1", "v1", 0,   48)
insert_clip("c2", "v2", 0,   48)

local function fetch_clip(id)
    local q = db:prepare("SELECT track_id, timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    q:bind_value(1, id)
    assert(q:exec(), "query failed for clip " .. id)
    local exists = q:next()
    local track_id = exists and q:value(0) or nil
    local start_val = exists and q:value(1) or nil
    local dur_val = exists and q:value(2) or nil
    q:finalize()
    return track_id, start_val, dur_val
end

command_manager.init(db, "seq", "proj")

-- Execute move to v2 (same start). Should trim/remove c2 via occlusion planner.
local cmd = Command.create("MoveClipToTrack", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("project_id", "proj")
cmd:set_parameter("clip_id", "c1")
cmd:set_parameter("target_track_id", "v2")

local exec = command_manager.execute(cmd)
assert(exec and exec.success, "move execution failed")

local track_after, start_after, dur_after = fetch_clip("c1")
assert(track_after == "v2", "clip not moved to v2")

-- Undo should restore c1 to v1 and reinstate any occluded clips.
local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "undo failed")

local track_final, start_final, dur_final = fetch_clip("c1")
assert(track_final == "v1", "clip track not restored after undo")
assert(start_final == 0 and dur_final == 48, "clip timing not restored after undo")

-- c2 must still exist and remain at original position/duration
local track_c2, start_c2, dur_c2 = fetch_clip("c2")
assert(track_c2 == "v2" and start_c2 == 0 and dur_c2 == 48, "occluded clip not restored after undo")

os.remove(DB_PATH)
print("✅ MoveClipToTrack undo restores original track and occluded clips")
