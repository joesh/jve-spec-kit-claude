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
local Rational = require("core.rational")

local function setup_db()
    local db_path = "/tmp/jve/test_nudge_ms_input.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',strftime('%s','now'),strftime('%s','now'),'{}')]]))
    assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
        view_start_frame,view_duration_frames,playhead_frame,
        selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','timeline',24,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,strftime('%s','now'),strftime('%s','now'))
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
command_manager.init(db, "seq", "proj")
reload_state()

-- Seed one clip
local clip = Clip.create("Clip", nil, {
    project_id = "proj",
    track_id = "v1",
    owner_sequence_id = "seq",
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(48, 24, 1),
    source_in = Rational.new(0, 24, 1),
    source_out = Rational.new(48, 24, 1),
    fps_numerator = 24, fps_denominator = 1
})
clip:save(db)

local cmd = Command.create("Nudge", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("fps_numerator", 24)
cmd:set_parameter("fps_denominator", 1)
cmd:set_parameter("selected_clip_ids", {clip.id})
-- Simulate leaf conversion from ms to Rational before calling command
local nudge_amount_rat = Rational.from_seconds(1000 / 1000.0, 24, 1)
cmd:set_parameter("nudge_amount_rat", nudge_amount_rat)

local res = command_manager.execute(cmd)
assert(res.success, "Nudge with ms payload should succeed")

local updated = Clip.load(clip.id, db)
assert(updated.timeline_start.frames == 24, "Clip should move forward by ~24 frames for 1000ms at 24fps")

-- Undo to keep DB tidy
local undo_cmd = Command.deserialize(res.result_data):create_undo()
local undo_res = command_manager.execute(undo_cmd)
assert(undo_res.success, "Undo Nudge should succeed")

print("✅ nudge accepts ms payload via conversion to Rational")
