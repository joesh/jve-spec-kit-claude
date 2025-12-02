local import_schema = require("import_schema")
local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local keyboard_shortcuts = require("core.keyboard_shortcuts")

local function with_db(fn)
    local db_path = "/tmp/jve/test_zoom_fit.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',strftime('%s','now'),strftime('%s','now'),'{}')]]))
    assert(db:exec([[
        INSERT INTO sequences(
            id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
            view_start_frame,view_duration_frames,playhead_frame,
            selected_clip_ids,selected_edge_infos,selected_gap_infos,current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','timeline',24,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,strftime('%s','now'),strftime('%s','now'))
    ]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0),
        ('v2','seq','V2','VIDEO',2,1,0,0,0,1.0,0.0)
    ]]))
    fn(db, db_path)
end

local function reload_state()
    timeline_state.reset()
    assert(timeline_state.init("seq"), "failed to init timeline state")
    keyboard_shortcuts.init(timeline_state)
end

local function current_view()
    return {
        start_value = timeline_state.get_viewport_start_time(),
        duration = timeline_state.get_viewport_duration()
    }
end

local function assert_view(expected_start, expected_duration)
    local view = current_view()
    local start_frames = (type(view.start_value) == "table" and view.start_value.frames) or view.start_value
    local duration_frames = (type(view.duration) == "table" and view.duration.frames) or view.duration
    assert(start_frames == expected_start, string.format("start_value expected %d got %s", expected_start, tostring(start_frames)))
    assert(duration_frames == expected_duration, string.format("duration expected %d got %s", expected_duration, tostring(duration_frames)))
end

-- Regression: ZoomFit updates viewport to cover all clips and toggles back.
with_db(function(db)
    -- Seed two clips with gap
    assert(db:exec([[INSERT INTO clips(id,project_id,clip_kind,track_id,media_id,owner_sequence_id,timeline_start_frame,duration_frames,source_in_frame,source_out_frame,fps_numerator,fps_denominator,enabled,offline,created_at,modified_at) VALUES
        ('c1','proj','timeline','v1',NULL,'seq',0,2000,0,2000,24,1,1,0,strftime('%s','now'),strftime('%s','now')),
        ('c2','proj','timeline','v1',NULL,'seq',5000,1000,0,1000,24,1,1,0,strftime('%s','now'),strftime('%s','now'))
    ]]))

    reload_state()
    local initial_duration = (function()
        local v = timeline_state.get_viewport_duration()
        return (type(v) == "table" and v.frames) or v
    end)()

    -- Prime snapshot for toggle
    assert_view(0, initial_duration)

    local ok = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok ~= false, "zoom fit should succeed")

    local view_after_fit = current_view()
    local fit_start = (type(view_after_fit.start_value) == "table" and view_after_fit.start_value.frames) or view_after_fit.start_value
    local fit_duration = (type(view_after_fit.duration) == "table" and view_after_fit.duration.frames) or view_after_fit.duration
    assert(fit_start == 0, "zoom fit should start at 0")
    assert(fit_duration >= 6600, "zoom fit should cover all clips with 10% buffer")

    -- Toggle back to previous view
    local ok2 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok2 ~= false, "zoom fit toggle should succeed")
    assert_view(0, initial_duration) -- back to initial
end)

print("✅ timeline zoom fit regression passed")
