#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local function setup_db(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))

    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);

        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                              playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 600, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1),
               ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1);

        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 3600, 30, 1, 1920, 1080, 0, 'raw', %d, %d);

        -- Track V1: left/right with gap
        -- 2000ms @ 30fps = 60 frames. 5000ms = 150 frames.
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('v1_left', 'default_project', 'timeline', 'V1 Left', 'track_v1', 'media1', 'default_sequence',
                0, 60, 0, 60, 30, 1, 1, 0, %d, %d),
               ('v1_right', 'default_project', 'timeline', 'V1 Right', 'track_v1', 'media1', 'default_sequence',
                150, 60, 60, 120, 30, 1, 1, 0, %d, %d);

        -- Track V2: left/right with a different gap
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('v2_left', 'default_project', 'timeline', 'V2 Left', 'track_v2', 'media1', 'default_sequence',
                0, 90, 0, 90, 30, 1, 1, 0, %d, %d),
               ('v2_right', 'default_project', 'timeline', 'V2 Right', 'track_v2', 'media1', 'default_sequence',
                240, 60, 90, 150, 30, 1, 1, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)))

    -- Stub timeline_state for Command.save validation
    local timeline_state = require("ui.timeline.timeline_state")
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_sequence_frame_rate = function() return 30 end
    timeline_state.get_sequence_id = function() return "default_sequence" end

    command_manager.init(db, "default_sequence", "default_project")
    return db
end

local TEST_DB = "/tmp/jve/test_batch_ripple_gap_undo_no_temp_gap.db"
local db = setup_db(TEST_DB)

local function clip_count()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline' AND track_id IS NOT NULL")
    assert(stmt:exec() and stmt:next(), "Failed to count clips")
    local count = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return count
end

local initial_count = clip_count()

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "v1_right", edge_type = "gap_before", track_id = "track_v1"},
    {clip_id = "v2_right", edge_type = "gap_before", track_id = "track_v2"},
})
cmd:set_parameter("delta_ms", -4000)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local undo = command_manager.undo()
assert(undo.success, undo.error_message or "Undo failed for batch ripple")

-- Ensure undo did not materialize gap clips into timeline
assert(clip_count() == initial_count, string.format("Undo should restore original clip count (%d)", initial_count))

-- Ensure no temp gap ids exist
local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id LIKE 'temp_gap_%'")
assert(stmt:exec() and stmt:next(), "Failed to query temp gap clips")
local temp_count = tonumber(stmt:value(0)) or 0
stmt:finalize()
assert(temp_count == 0, "Undo should not leave temp_gap clips persisted")

os.remove(TEST_DB)
print("✅ Batch ripple undo does not persist gap placeholders")
