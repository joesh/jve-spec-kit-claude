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
    assert(db:exec([[INSERT INTO projects(id,name,created_at,modified_at,settings) VALUES('proj','Test',0,0,'{}')]]))
    assert(db:exec([[INSERT INTO sequences(id,project_id,name,frame_rate,audio_sample_rate,width,height) VALUES('seq','proj','Sequence',24,48000,1920,1080)]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,timebase_type,timebase_rate,track_index,enabled) VALUES
        ('v1','seq','V1','VIDEO','video_frames',24,1,1)
    ]]))
    fn(db, db_path)
end

local function reload_state()
    timeline_state.reset()
    assert(timeline_state.init("seq"), "failed to init timeline state")
    keyboard_shortcuts.init(timeline_state)
end

local function capture_view()
    local snap = timeline_state.capture_viewport()
    return {
        start_value = snap.start_value,
        duration_value = snap.duration_value,
    }
end

with_db(function(db)
    -- Two clips spanning 0..6000ms
    assert(db:exec([[INSERT INTO clips(id,project_id,clip_kind,track_id,media_id,start_value,duration_value,source_in_value,source_out_value,timebase_type,timebase_rate,enabled) VALUES
        ('c1','proj','timeline','v1',NULL,0,2000,0,2000,'video_frames',24,1),
        ('c2','proj','timeline','v1',NULL,5000,1000,0,1000,'video_frames',24,1)
    ]]))

    reload_state()

    -- Start from a non-zero viewport so toggle has something to restore
    timeline_state.set_viewport_start_value(1000)
    timeline_state.set_viewport_duration_frames_value(4000)
    local initial = capture_view()

    local ok1 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok1 ~= false, "first zoom fit should succeed")
    local after_fit = capture_view()
    assert(after_fit.start_value == 0, "zoom fit should start at 0")
    assert(after_fit.duration_value >= 7000, "zoom fit should include padding")
    assert(after_fit.duration_value ~= initial.duration_value, "zoom fit should change viewport")

    local ok2 = keyboard_shortcuts.handle_command("TimelineZoomFit")
    assert(ok2 ~= false, "second zoom fit should restore previous view")
    local restored = capture_view()
    assert(restored.start_value == initial.start_value, string.format("expected start %d got %d", initial.start_value, restored.start_value))
    assert(restored.duration_value == initial.duration_value, string.format("expected duration %d got %d", initial.duration_value, restored.duration_value))
end)

print("✅ timeline zoom fit toggle regression passed")
