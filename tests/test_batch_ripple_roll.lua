#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
-- core.command_implementations is deleted. Commands are auto-loaded by command_manager.
-- require("core.command_implementations") 

local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local TEST_DB = "/tmp/jve/test_batch_ripple_roll.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()

local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, selected_clip_ids, selected_edge_infos, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, '[]', '[]', 0, 240, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_a', 'default_project', 'timeline', 'A', 'track_v1', 'default_sequence',
         0, 30, 0, 30, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'default_project', 'timeline', 'B', 'track_v1', 'default_sequence',
         30, 30, 0, 30, 30, 1, 1, 0, %d, %d),
        ('clip_c', 'default_project', 'timeline', 'C', 'track_v1', 'default_sequence',
         60, 30, 0, 30, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)

assert(db:exec(seed))

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 30}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.set_gap_selection = function(_) end
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_sequence_frame_rate = function() return {fps_numerator=30, fps_denominator=1} end
    timeline_state.get_sequence_id = function() return "default_sequence" end
    timeline_state.reload_clips = function() return true end
    timeline_state.get_clip_by_id = function(id)
        return require("models.clip").load(id, db)
    end
    timeline_state.get_clips = function()
        return require("core.database").load_clips("default_sequence")
    end
    timeline_state.describe_track_neighbors = require("ui.timeline.timeline_state").describe_track_neighbors

    timeline_state.get_selected_clips = function() return {} end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_position = function(_) end
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_project_id = function() return "default_project" end
    timeline_state.get_sequence_id = function() return "default_sequence" end
    timeline_state.reload_clips = function(_) end
    timeline_state.consume_mutation_failure = function() return nil end
    timeline_state.apply_mutations = function(_, mutations)
        timeline_state.last_mutations_attempt = {
            sequence_id = mutations and mutations.sequence_id,
            bucket = mutations
        }
        timeline_state.last_mutations = mutations
        return true
    end
end

stub_timeline_state()

command_manager.init(db, "default_sequence", "default_project")

local function fetch_clip_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    -- Convert frames back to approx MS
    return math.floor(value / 30.0 * 1000.0 + 0.5)
end

local function fetch_clip_duration(clip_id)
    local stmt = db:prepare("SELECT duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return math.floor(value / 30.0 * 1000.0 + 0.5)
end

local function exec_batch(edge_infos, delta_ms)
    local batch_cmd = Command.create("BatchRippleEdit", "default_project")
    batch_cmd:set_parameter("edge_infos", edge_infos)
    local frames = math.floor((delta_ms * 30 / 1000) + 0.5)
    batch_cmd:set_parameter("delta_frames", frames)
    batch_cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(batch_cmd)
    assert(result.success, result.error_message or "BatchRippleEdit failed")
end

-- Test 1: Dual-edge roll should not ripple downstream clips
local roll_edges = {
    {clip_id = "clip_a", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_b", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

exec_batch(roll_edges, 200)

-- Verify roll pair only adjusts boundary without rippling downstream clips
-- Frame-to-ms conversion is exact: integer frames * (1000ms / 30fps) rounds deterministically
-- 60 frames @ 30fps = 2000ms, 36 frames = 1200ms (exact integer results)
assert(fetch_clip_start("clip_c") == 2000, "Roll edit should not ripple clip C")
assert(fetch_clip_duration("clip_a") == 1200, "Clip A should extend by roll amount")
assert(fetch_clip_start("clip_b") == 1200, "Clip B should shift with roll boundary")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed after roll test")

-- Test 2: Mixed selection (roll + ripple) should ripple only unmatched edges
local mixed_edges = {
    {clip_id = "clip_a", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_b", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_b", edge_type = "out", track_id = "track_v1"}
}

exec_batch(mixed_edges, 150)

-- Frame snapping: 150ms @ 30fps = 4.5 frames → rounds to 5 frames
-- Roll +5 frames: A extends to 35 frames, B start moves to 35 frames
-- B out ripple +5 frames: B duration = 30 (original) - 5 (roll in) + 5 (ripple out) = 30 frames
-- C shifts +5 frames: 60 → 65 frames
--
-- Frame-to-ms conversion (fetch_clip_* functions):
--   35 frames: floor(35 / 30.0 * 1000.0 + 0.5) = floor(1166.67 + 0.5) = 1167ms
--   30 frames: floor(30 / 30.0 * 1000.0 + 0.5) = 1000ms
--   65 frames: floor(65 / 30.0 * 1000.0 + 0.5) = floor(2166.67 + 0.5) = 2167ms

local mixed_c_start = fetch_clip_start("clip_c")
local mixed_a_duration = fetch_clip_duration("clip_a")
local mixed_b_start = fetch_clip_start("clip_b")
local mixed_b_duration = fetch_clip_duration("clip_b")

assert(mixed_c_start == 2167, "Ripple edge should shift clip C forward by 5 frames (2167ms)")
assert(mixed_a_duration == 1167, "Roll pair should adjust clip A duration to 35 frames (1167ms)")
assert(mixed_b_start == 1167, "Roll pair should update clip B start to 35 frames (1167ms)")
assert(mixed_b_duration == 1000, "B out ripple should maintain 30 frame duration (1000ms)")

local undo_result2 = command_manager.undo()
assert(undo_result2.success, undo_result2.error_message or "Undo failed after mixed test")

os.remove(TEST_DB)
print("✅ BatchRippleEdit handles dual-edge roll and mixed roll+ripple selections")
