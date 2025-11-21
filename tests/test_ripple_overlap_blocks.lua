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
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);

        INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                              timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 300);

        INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 'video_frames', 30.0, 1, 1);

        INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec)
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 5000, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'raw');

        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled, offline,
                           created_at, modified_at)
        VALUES
            ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
             0, 2000, 0, 2000, 'video_frames', 30.0, 1, 0, %d, %d),
            ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
             3000, 2000, 1000, 3000, 'video_frames', 30.0, 1, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now)
    assert(seeded_db:exec(seed))
    command_manager.init(seeded_db, "default_sequence", "default_project")
    return seeded_db
end

local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 300, timebase_type = "video_frames", timebase_rate = 30.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_value = function(_) end
timeline_state.get_playhead_value = function() return 0 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

local function fetch_start(db_conn, id)
    local stmt = db_conn:prepare("SELECT start_value FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

local function run_case(db_path, use_batch)
    local db_conn = seed_db(db_path)

    local cmd
    if use_batch then
        cmd = Command.create("BatchRippleEdit", "default_project")
        cmd:set_parameter("edge_infos", {
            {clip_id = "clip_right", edge_type = "gap_before", track_id = "track_v1"}
        })
    else
        cmd = Command.create("RippleEdit", "default_project")
        cmd:set_parameter("edge_info", {clip_id = "clip_right", edge_type = "gap_before", track_id = "track_v1"})
    end
    cmd:set_parameter("delta_ms", -1500) -- would overlap left clip if not clamped
    cmd:set_parameter("sequence_id", "default_sequence")

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleEdit failed")

    local start_value = fetch_start(db_conn, "clip_right")

    local args_stmt
    if use_batch then
        args_stmt = db_conn:prepare("SELECT command_args FROM commands WHERE command_type = 'BatchRippleEdit'")
    else
        args_stmt = db_conn:prepare("SELECT command_args FROM commands WHERE command_type = 'RippleEdit'")
    end
    assert(args_stmt:exec() and args_stmt:next(), "command row missing")
    local args_json = tostring(args_stmt:value(0))
    args_stmt:finalize()
    assert(args_json:find("clamped_delta_ms"), "expected clamped_delta_ms persisted in command args")

    os.remove(db_path)
    return start_value
end

-- Single-edge ripple clamp
local start_single = run_case(TEST_DB, false)
assert(start_single == 2000, "single ripple should clamp to avoid overlapping left clip")

-- Batch ripple (single edge in batch path) uses the same clamp rules
local start_batch = run_case("/tmp/jve/test_ripple_overlap_batch.db", true)
assert(start_batch == 2000, "batch ripple should clamp gap-before edges identically to single ripple")

-- Zero-gap: clamp to no movement when clips touch
local function run_zero_gap(db_path)
    local db_conn = seed_db(db_path)
    -- Move right clip to butt against left (gap=0)
    assert(db_conn:exec("UPDATE clips SET start_value = 2000 WHERE id = 'clip_right'"))

    local cmd = Command.create("RippleEdit", "default_project")
    cmd:set_parameter("edge_info", {clip_id = "clip_right", edge_type = "gap_before", track_id = "track_v1"})
    cmd:set_parameter("delta_ms", -500) -- no gap to close
    cmd:set_parameter("sequence_id", "default_sequence")

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleEdit zero-gap should succeed")

    local start_value = fetch_start(db_conn, "clip_right")
    os.remove(db_path)
    return start_value
end

local zero_gap_start = run_zero_gap("/tmp/jve/test_ripple_overlap_zero_gap.db")
assert(zero_gap_start == 2000, "zero-gap ripple should clamp to no movement")

print("✅ Ripple edit clamps to avoid overlapping upstream clip (single and batch)")
