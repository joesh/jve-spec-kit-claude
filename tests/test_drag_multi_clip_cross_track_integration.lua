#!/usr/bin/env luajit

-- Integration regression: multi-clip selection dragged to another track should move both clips in the DB (no stubs).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Clip = require("models.clip")
local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local DB_PATH = "/tmp/jve/test_drag_multi_clip_cross_track_integration.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at) VALUES('proj','P',strftime('%s','now'),strftime('%s','now'));]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','timeline',24,1,48000,1920,1080,0,5000,0,strftime('%s','now'),strftime('%s','now'));]]))
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

insert_clip("c1", "v1", 0,  100)
insert_clip("c2", "v1", 200, 80)

command_manager.init("seq", "proj")

local _G = _G
_G.timeline = { get_dimensions = function() return 1000, 1000 end }

-- State uses real clips loaded from DB
local function load_clips()
    return {
        Clip.load("c1", db),
        Clip.load("c2", db),
    }
end

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function()
        return {
            {id = "v1", track_type = "VIDEO"},
            {id = "v2", track_type = "VIDEO"},
        }
    end,
    get_clips = load_clips
}

local view = {
    state = state,
    widget = {},
    get_track_id_at_y = function(y, h) return "v2" end
}

local drag_state = {
    type = "clips",
    clips = {
        {id = "c1"},
        {id = "c2"},
    },
    anchor_clip_id = "c1",
    delta_ms = 0,
    delta_frames = 0,
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})
-- Execute was invoked synchronously inside handle_release; verify DB.
local q = db:prepare("SELECT id, track_id FROM clips WHERE id IN ('c1','c2') ORDER BY id")
assert(q:exec(), "query failed")
local tracks = {}
while q:next() do
    tracks[q:value(0)] = q:value(1)
end
q:finalize()

assert(tracks["c1"] == "v2" and tracks["c2"] == "v2", "clips were not moved to v2 via drag")

os.remove(DB_PATH)
print("✅ Integration: multi-clip cross-track drag moves clips in DB")
