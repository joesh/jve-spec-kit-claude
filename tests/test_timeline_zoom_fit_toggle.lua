require("test_env")

local import_schema = require("import_schema")
local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local keyboard_shortcuts = require("core.keyboard_shortcuts")

local function with_db(fn)
    local db_path = "/tmp/jve/test_zoom_fit_toggle.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',strftime('%s','now'),strftime('%s','now'),'{}')]]))
    assert(db:exec([[
        INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
            view_start_frame,view_duration_frames,playhead_frame,selected_clip_ids,selected_edge_infos,selected_gap_infos,
            current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','timeline',24,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,strftime('%s','now'),strftime('%s','now'))
    ]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0)
    ]]))
    fn(db, db_path)
end

local function reload_state()
    timeline_state.reset()
    assert(timeline_state.init("seq"), "failed to init timeline state")
    keyboard_shortcuts.init(timeline_state)
end

local function to_frames(value)
    if type(value) == "table" and value.frames then
        return value.frames
    end
    return value
end

local function capture_view()
    local snap = timeline_state.capture_viewport()
    return {
        start_frames = to_frames(snap.start_time or snap.start_value),
        duration_frames = to_frames(snap.duration or snap.duration_value),
    }
end

with_db(function(db)
    -- Two clips spanning 0..6000ms
    assert(db:exec([[INSERT INTO clips(id,project_id,clip_kind,track_id,media_id,owner_sequence_id,timeline_start_frame,duration_frames,source_in_frame,source_out_frame,fps_numerator,fps_denominator,enabled,offline,created_at,modified_at) VALUES
        ('c1','proj','timeline','v1',NULL,'seq',0,2000,0,2000,24,1,1,0,strftime('%s','now'),strftime('%s','now')),
        ('c2','proj','timeline','v1',NULL,'seq',5000,1000,0,1000,24,1,1,0,strftime('%s','now'),strftime('%s','now'))
    ]]))

    reload_state()

    -- Start from a non-zero viewport so toggle has something to restore
    -- All coords are integer frames
    timeline_state.set_viewport_start_time(1000)
    timeline_state.set_viewport_duration(4000)
    local initial = capture_view()

    local ok1 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok1 ~= false, "first zoom fit should succeed")
    local after_fit = capture_view()
    assert(after_fit.start_frames == 0, "zoom fit should start at 0")
    assert(after_fit.duration_frames >= 6000, "zoom fit should cover the full span")
    assert(after_fit.duration_frames ~= initial.duration_frames, "zoom fit should change viewport")

    local ok2 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok2 ~= false, "second zoom fit should restore previous view")
    local restored = capture_view()
    assert(restored.start_frames == initial.start_frames, string.format("expected start %d got %d", initial.start_frames, restored.start_frames))
    assert(restored.duration_frames == initial.duration_frames, string.format("expected duration %d got %d", initial.duration_frames, restored.duration_frames))
end)

print("✅ timeline zoom fit toggle regression passed")
