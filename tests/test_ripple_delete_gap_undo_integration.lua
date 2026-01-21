#!/usr/bin/env luajit

-- Integration regression: RippleDelete undo should restore original clip positions without overlaps.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Command = require("command")
local Rational = require("core.rational")

local DB_PATH = "/tmp/jve/test_ripple_delete_gap_undo_integration.db"
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

-- c1 at 0-99, gap 100-199, c2 at 200-299, c3 at 320-399
insert_clip("c1", 0, 100)
insert_clip("c2", 200, 100)
insert_clip("c3", 320, 80)

command_manager.init("seq", "proj")

local function fetch_starts()
    local q = db:prepare("SELECT id, timeline_start_frame FROM clips WHERE track_id = 'v1'")
    assert(q:exec(), "query failed")
    local s = {}
    while q:next() do s[q:value(0)] = q:value(1) end
    q:finalize()
    return s
end

local original = fetch_starts()

local cmd = Command.create("RippleDelete", "proj")
cmd:set_parameter("track_id", "v1")
cmd:set_parameter("gap_start", Rational.new(100, 24, 1))
cmd:set_parameter("gap_duration", Rational.new(100, 24, 1))
cmd:set_parameter("sequence_id", "seq")

local res = command_manager.execute(cmd)
assert(res.success, "ripple delete failed: " .. tostring(res.error_message))

-- Now undo
local undo_res = command_manager.undo()
assert(undo_res and undo_res.success, "undo ripple delete failed: " .. tostring(undo_res.error_message))

local restored = fetch_starts()
assert(restored["c1"] == original["c1"], "c1 start not restored")
assert(restored["c2"] == original["c2"], "c2 start not restored")
assert(restored["c3"] == original["c3"], "c3 start not restored")

os.remove(DB_PATH)
print("✅ Integration: RippleDelete undo restores clip positions without overlaps")
