require("test_env")

local import_schema = require("import_schema")
local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local function with_db(fn)
    local db_path = "/tmp/jve/test_zoom_fit_toggle.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id,name,fps_mismatch_policy, created_at,modified_at,settings) VALUES('proj','Test','resample',0,0,'{}')]]))
    assert(db:exec([[
        INSERT INTO sequences(id,project_id,name,kind,fps_numerator,fps_denominator,audio_rate,width,height,
            view_start_frame,view_duration_frames,playhead_frame,selected_clip_ids,selected_edge_infos,selected_gap_infos,
            current_sequence_number,created_at,modified_at)
        VALUES('seq','proj','Sequence','nested',24,1,48000,1920,1080,0,8000,0,'[]','[]','[]',0,0,0)
    ]]))
    assert(db:exec([[INSERT INTO tracks(id,sequence_id,name,track_type,track_index,enabled,locked,muted,soloed,volume,pan) VALUES
        ('v1','seq','V1','VIDEO',1,1,0,0,0,1.0,0.0)
    ]]))
    fn(db, db_path)
end

-- Set up zoom fit command executor
local zoom_fit_mod = require("core.commands.timeline_zoom_fit")
local executors = {}
zoom_fit_mod.register(executors, {}, nil, function(e) error(e) end)

local function make_cmd()
    return { get_all_parameters = function() return { project_id = "proj" } end }
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
    assert(db:exec([[-- V13 placeholder master sequence (was V8 NULL media_id)
INSERT OR IGNORE INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 2000, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT OR IGNORE INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT OR IGNORE INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('c1', 'proj', 'v1', '_v13_placeholder_master', 'seq', 0, 2000, 0, 2000, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
    ('c2', 'proj', 'v1', '_v13_placeholder_master', 'seq', 5000, 1000, 0, 1000, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);))

    timeline_state.reset()
    assert(timeline_state.init("seq"), "failed to init timeline state")
    zoom_fit_mod.clear_toggle_state()

    -- Start from a non-zero viewport so toggle has something to restore
    timeline_state.set_viewport_start_time(1000)
    timeline_state.set_viewport_duration(4000)
    local initial = capture_view()

    local ok1 = executors["TimelineZoomFit"](make_cmd())
    assert(ok1 ~= false, "first zoom fit should succeed")
    local after_fit = capture_view()
    assert(after_fit.start_frames == 0, "zoom fit should start at 0")
    assert(after_fit.duration_frames >= 6000, "zoom fit should cover the full span")
    assert(after_fit.duration_frames ~= initial.duration_frames, "zoom fit should change viewport")

    local ok2 = executors["TimelineZoomFit"](make_cmd())
    assert(ok2 ~= false, "second zoom fit should restore previous view")
    local restored = capture_view()
    assert(restored.start_frames == initial.start_frames, string.format("expected start %d got %d", initial.start_frames, restored.start_frames))
    assert(restored.duration_frames == initial.duration_frames, string.format("expected duration %d got %d", initial.duration_frames, restored.duration_frames))
end)

print("✅ timeline zoom fit toggle regression passed")
