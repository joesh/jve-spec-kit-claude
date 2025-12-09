#!/usr/bin/env luajit

-- Regression: dragging a clip right (Nudge + occlusion delete) then undo must restore downstream clips.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Rational = require("core.rational")
local import_schema = require("import_schema")

local DB_PATH = "/tmp/jve/test_nudge_undo_occlusion.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
db:exec(import_schema)

-- Minimal project/sequence/track
assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at) VALUES('proj','P',strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','timeline',24,1,48000,1920,1080,0,1000,0,strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0);]]))

local function insert_clip(id, start_frames, duration_frames)
    local stmt = db:prepare([[INSERT INTO clips(
        id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, created_at, modified_at
    ) VALUES(?,?,?,?,?,?,?,?,?,?,24,1,1,strftime('%s','now'),strftime('%s','now'))]])
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

insert_clip("c1", 0,   100)
insert_clip("c2", 100, 100)
insert_clip("c3", 200, 100)

local function fetch_clip_start(id)
    local q = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    q:bind_value(1, id)
    assert(q:exec(), "query failed for clip " .. id)
    local exists = q:next()
    local start_val = exists and q:value(0) or nil
    local dur_val = exists and q:value(1) or nil
    q:finalize()
    return start_val, dur_val
end

command_manager.init(db, "seq", "proj")

-- Move middle clip right by its full duration, overlapping c3 (forces occlusion delete).
local Command = require("command")
local cmd = Command.create("Nudge", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("fps_numerator", 24)
cmd:set_parameter("fps_denominator", 1)
cmd:set_parameter("nudge_amount_rat", Rational.new(100, 24, 1))
cmd:set_parameter("selected_clip_ids", {"c2"})

local exec = command_manager.execute(cmd)
assert(exec and exec.success, "nudge execution failed")

-- Undo should restore all three clips to their original positions.
local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "undo failed")

local s1, d1 = fetch_clip_start("c1")
local s2, d2 = fetch_clip_start("c2")
local s3, d3 = fetch_clip_start("c3")

assert(s1 == 0 and d1 == 100, "c1 start/duration not restored")
assert(s2 == 100 and d2 == 100, "c2 start/duration not restored")
assert(s3 == 200 and d3 == 100, "c3 start/duration not restored (missing or shifted)")

os.remove(DB_PATH)
print("✅ Nudge undo restores occluded downstream clip")
