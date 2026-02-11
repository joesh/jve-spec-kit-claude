#!/usr/bin/env luajit

-- Regression: BatchCommand of MoveClipToTrack must undo all moves and restore occluded clips.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")
local json = require("dkjson")

local DB_PATH = "/tmp/jve/test_batch_move_clip_undo.db"
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

-- Original layout: two clips on v1, one occupying the destination start on v2 (to trigger occlusion)
insert_clip("c1", "v1", 0,   48)
insert_clip("c2", "v1", 96,  48)
insert_clip("c_dest", "v2", 0, 48)

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

command_manager.init("seq", "proj")

-- Build batch payload similar to drag handler
local command_specs = {
    {command_type = "MoveClipToTrack", parameters = {clip_id = "c1", target_track_id = "v2"}},
    {command_type = "MoveClipToTrack", parameters = {clip_id = "c2", target_track_id = "v2"}},
}

local batch = Command.create("BatchCommand", "proj")
batch:set_parameter("commands_json", json.encode(command_specs))
batch:set_parameter("sequence_id", "seq")

local exec = command_manager.execute(batch)
assert(exec and exec.success, "batch move execution failed")

local t1 = fetch_clip("c1")
local t2 = fetch_clip("c2")
assert(t1 == "v2" and t2 == "v2", "clips not moved to v2")

-- Undo batch
local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "batch undo failed")

local tf1, sf1, df1 = fetch_clip("c1")
local tf2, sf2, df2 = fetch_clip("c2")
local td, sd, dd = fetch_clip("c_dest")

assert(tf1 == "v1" and sf1 == 0 and df1 == 48, "c1 not restored after batch undo")
assert(tf2 == "v1" and sf2 == 96 and df2 == 48, "c2 not restored after batch undo")
assert(td == "v2" and sd == 0 and dd == 48, "destination clip not restored after batch undo")

os.remove(DB_PATH)
print("✅ Batch MoveClipToTrack undo restores originals")
