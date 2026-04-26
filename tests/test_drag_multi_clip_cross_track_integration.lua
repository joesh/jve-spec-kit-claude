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

assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at) VALUES('proj','P','resample',0,0);]]))
assert(db:exec([[INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at)
                 VALUES('seq','proj','Seq','nested',24,1,48000,1920,1080,0,5000,0,0,0);]]))
assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan)
                 VALUES('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
                        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0);]]))

-- V13 fixture: placeholder master sequence (clips.nested_sequence_id FK
-- + INV-1 require the referenced master to exist with kind='master').
do
    assert(db:exec("INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,view_start_frame,view_duration_frames,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master','proj','PlaceholderMaster','master',24,1,48000,1920,1080,0,2000,0,0,0);"))
    assert(db:exec("INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES('_v13_placeholder_master_v1','_v13_placeholder_master','V1','VIDEO',1,1,0,0,0,1.0,0.0);"))
    db:exec("INSERT OR IGNORE INTO media(id,project_id,name,file_path,duration_frames,fps_numerator,fps_denominator,width,height,audio_channels,codec,metadata,created_at,modified_at) VALUES('_v13_placeholder_master_media','proj','PlaceholderMedia','/tmp/placeholder.mov',2000,24,1,1920,1080,2,'prores','{{}}',0,0);")
    db:exec("INSERT OR IGNORE INTO media_refs(id,project_id,owner_sequence_id,track_id,media_id,source_in_frame,source_out_frame,timeline_start_frame,duration_frames,enabled,volume,playhead_frame,created_at,modified_at) VALUES('_v13_placeholder_master_mref','proj','_v13_placeholder_master','_v13_placeholder_master_v1','_v13_placeholder_master_media',0,2000,0,2000,1,1.0,0,0,0);")
end

local function insert_clip(id, track, start_frames, duration_frames)
    local stmt = db:prepare([[
INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, nested_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    (?, ?, ?, ?, 'seq', '_v13_placeholder_master', ?, ?, ?, ?, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);]])
    stmt:bind_value(1, id)

    stmt:bind_value(2, "proj")

    stmt:bind_value(3, "timeline")

    stmt:bind_value(4, track)

    stmt:bind_value(5, start_frames)

    stmt:bind_value(6, duration_frames)

    stmt:bind_value(7, 0)

    stmt:bind_value(8, duration_frames)
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
