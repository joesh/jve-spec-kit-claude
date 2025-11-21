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
    assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',0,0,'{}')]]))
    assert(db:exec([[INSERT INTO sequences(id,project_id,name,frame_rate,audio_sample_rate,width,height) VALUES('seq','proj','Sequence',24,48000,1920,1080)]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,timebase_type,timebase_rate,track_index,enabled) VALUES
        ('v1','seq','V1','VIDEO','video_frames',24,1,1),
        ('v2','seq','V2','VIDEO','video_frames',24,2,1)
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
        start_value = timeline_state.get_viewport_start_value(),
        duration = timeline_state.get_viewport_duration()
    }
end

local function assert_view(expected_start, expected_duration)
    local view = current_view()
    assert(view.start_value == expected_start, string.format("start_value expected %d got %d", expected_start, view.start_value))
    assert(view.duration == expected_duration, string.format("duration expected %d got %d", expected_duration, view.duration))
end

-- Regression: ZoomFit updates viewport to cover all clips and toggles back.
with_db(function(db)
    -- Seed two clips with gap
    assert(db:exec([[INSERT INTO clips(id,project_id,clip_kind,track_id,media_id,start_value,duration_value,source_in_value,source_out_value,timebase_type,timebase_rate,enabled) VALUES
        ('c1','proj','timeline','v1',NULL,0,2000,0,2000,'video_frames',24,1),
        ('c2','proj','timeline','v1',NULL,5000,1000,0,1000,'video_frames',24,1)
    ]]))

    reload_state()
    -- Prime snapshot for toggle
    assert_view(0, timeline_state.get_viewport_duration())

    local ok = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok ~= false, "zoom fit should succeed")

    local view_after_fit = current_view()
    assert(view_after_fit.start_value == 0, "zoom fit should start at 0")
    assert(view_after_fit.duration >= 6000, "zoom fit should cover all clips")

    -- Toggle back to previous view
    local ok2 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok2 ~= false, "zoom fit toggle should succeed")
    assert_view(0, timeline_state.get_viewport_duration()) -- back to initial
end)

print("✅ timeline zoom fit regression passed")
