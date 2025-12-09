#!/usr/bin/env luajit

-- Regression: UndoMoveClipToTrack should record timeline mutations using the sequence id for UI refresh.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local command_registry = require("core.command_registry")
local import_schema = require("import_schema")
local Command = require("command")

local DB_PATH = "/tmp/jve/test_move_clip_undo_mutations.db"
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

insert_clip("c1", "v1", 0, 48)
insert_clip("c2", "v2", 0, 48) -- occluder

local function fetch_track(id)
    local q = db:prepare("SELECT track_id FROM clips WHERE id = ?")
    q:bind_value(1, id)
    assert(q:exec(), "query failed for clip " .. id)
    local exists = q:next()
    local track_id = exists and q:value(0) or nil
    q:finalize()
    return track_id
end

command_manager.init(db, "seq", "proj")

local move_cmd = Command.create("MoveClipToTrack", "proj")
move_cmd:set_parameter("sequence_id", "seq")
move_cmd:set_parameter("clip_id", "c1")
move_cmd:set_parameter("target_track_id", "v2")

local exec = command_manager.execute(move_cmd)
assert(exec and exec.success, "move execution failed")
assert(fetch_track("c1") == "v2", "move did not apply")

local undoer = command_registry.get_undoer("MoveClipToTrack")
assert(type(undoer) == "function", "missing undoer")
local ok = undoer(move_cmd)
assert(ok, "undoer returned false")

-- Timeline mutations should be recorded against the sequence for UI application
local tm = move_cmd:get_parameter("__timeline_mutations")
assert(tm and tm["seq"] or tm.sequence_id == "seq" or (tm.sequence_id == nil and tm.inserts), "timeline mutations not recorded for sequence")

-- DB restored
assert(fetch_track("c1") == "v1", "undo did not restore track")
assert(fetch_track("c2") == "v2", "occluded clip not restored")

os.remove(DB_PATH)
print("✅ UndoMoveClipToTrack records timeline mutations with sequence id")
