#!/usr/bin/env luajit

-- Integration regression: dragging a block right on the same track must resolve overlaps with unselected clips.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local import_schema = require("import_schema")
local Clip = require("models.clip")
local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local DB_PATH = "/tmp/jve/test_drag_block_right_overlap_integration.db"
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
insert_clip("c2", 150, 100)
insert_clip("c3", 320, 80) -- unselected; will be overlapped by block move if not resolved

command_manager.init(db, "seq", "proj")

_G.timeline = { get_dimensions = function() return 1000, 1000 end }

local function load_clips()
    return {
        Clip.load("c1", db),
        Clip.load("c2", db),
        Clip.load("c3", db),
    }
end

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function() return {{id = "v1", track_type = "VIDEO"}} end,
    get_clips = load_clips
}

local view = {
    state = state,
    widget = {},
    get_track_id_at_y = function(y, h) return "v1" end
}

local drag_state = {
    type = "clips",
    clips = {
        {id = "c1"},
        {id = "c2"},
    },
    anchor_clip_id = "c1",
    delta_ms = 5000, -- move right ~5 seconds (~120 frames) -> overlaps c3 without occlusion handling
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})

-- Ensure command was recorded (i.e., execution succeeded)
local qc = db:prepare("SELECT COUNT(*) FROM commands")
assert(qc:exec() and qc:next(), "failed to count commands")
local cmd_count = qc:value(0)
qc:finalize()
assert(cmd_count > 0, "drag did not execute successfully (no command recorded)")

-- Verify no overlaps on v1
local q = db:prepare("SELECT id, timeline_start_frame, duration_frames FROM clips WHERE track_id = 'v1' ORDER BY timeline_start_frame")
assert(q:exec(), "query failed")
local clips = {}
while q:next() do
    table.insert(clips, {id = q:value(0), start = q:value(1), dur = q:value(2)})
end
q:finalize()

for i = 2, #clips do
    local prev = clips[i-1]
    local cur = clips[i]
    assert(prev.start + prev.dur <= cur.start, string.format("overlap detected between %s and %s", prev.id, cur.id))
end

os.remove(DB_PATH)
print("✅ Integration: block drag right resolves overlaps on same track")
