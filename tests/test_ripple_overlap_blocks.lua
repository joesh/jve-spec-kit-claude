#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_ripple_overlap_blocks.db"
local function seed_db(db_path)
    os.remove(db_path)

    assert(database.init(db_path))
    local seeded_db = database.get_connection()
    assert(seeded_db:exec(SCHEMA_SQL))

    local now = os.time()
    local seed = string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('default_project', 'Default Project', 'resample', %d, %d);

        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        )
        VALUES ('default_sequence', 'default_project', 'Timeline', 'nested', 1000, 1, 48000, 1920, 1080, 0, 300, 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 5000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

        -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 5000, 0, 5000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_left', 'default_project', 'Left', 'track_v1', 'master_media1', 'default_sequence', 0, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_right', 'default_project', 'Right', 'track_v1', 'master_media1', 'default_sequence', 3000, 2000, 1000, 3000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]],
        now, now,     -- projects
        now, now,     -- sequences
        now, now,     -- media
        now, now,     -- clip_left
        now, now      -- clip_right
    )
    assert(seeded_db:exec(seed))
    command_manager.init("default_sequence", "default_project")
    return seeded_db
end

local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 300, timebase_type = "video_frames", timebase_rate = 1000.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 0 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 1000, fps_denominator = 1} end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

local function fetch_start(db_conn, id)
    local stmt = db_conn:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

local function run_case(db_path, use_batch)
    local db_conn = seed_db(db_path)

    -- Gap between clip_left (end=2000) and clip_right (start=3000): gap_track_v1_2000
    local gap_id = string.format("gap_track_v1_%d", 2000)

    local cmd
    -- Gap operations always use BatchRippleEdit (gap clips are in-memory only)
    cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", {
        {clip_id = gap_id, edge_type = "out", track_id = "track_v1"}
    })
    cmd:set_parameter("delta_frames", -1500) -- drag ] LEFT to close the gap
    cmd:set_parameter("sequence_id", "default_sequence")

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleEdit failed")

    local start_value = fetch_start(db_conn, "clip_right")

    local args_stmt
    args_stmt = db_conn:prepare("SELECT command_args FROM commands WHERE command_type = 'BatchRippleEdit'")
    assert(args_stmt:exec() and args_stmt:next(), "command row missing")
    local args_json = tostring(args_stmt:value(0))
    args_stmt:finalize()
    assert(args_json:find("clamped_delta_ms"), "expected clamped_delta_ms persisted in command args")

    os.remove(db_path)
    return start_value
end

-- Gap operations use BatchRippleEdit (gap clips are in-memory only)
local start_batch = run_case(TEST_DB, true)
assert(start_batch == 2000, "batch ripple should clamp gap out-edge to avoid overlapping left clip")

-- 013/T046: zero-gap clamp behavior is covered by
-- test_batch_ripple_zero_gap_block_reports_implied_edge.lua. The legacy
-- single-edge RippleEdit path is gone; not re-tested here.

print("✅ Ripple edit clamps to avoid overlapping upstream clip")
