#!/usr/bin/env luajit

require('test_env')

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local function setup_db(path)
    os.remove(path)
    database.init(path)
    local db = database.get_connection()

    db:exec(require('import_schema'))

    local now = os.time()
    db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('default_project', 'Default Project', 'resample', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
        VALUES ('default_sequence', 'default_project', 'Sequence', 'nested', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1);
    ]], now, now, now, now))

    return db
end

local test_env = require("test_env")
local Sequence = require("models.sequence")

-- Bootstrap a placeholder master sequence so V13 clips can reference it.
-- The blade test creates 1 media row per clip; we point all clips at one
-- shared placeholder master with generous duration to satisfy the source window lower bound.
local function bootstrap_blade_master()
    local conn = database.get_connection()
    local exists = conn:prepare("SELECT 1 FROM sequences WHERE id = '_blade_master'")
    if exists and exists:exec() and exists:next() then exists:finalize(); return end
    if exists then exists:finalize() end
    conn:exec("INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata) VALUES ('_blade_media', 'default_project', 'placeholder', '_placeholder', 100000, 30, 1, 1920, 1080, 0, 'raw', 0, 0, '{\"start_tc_value\":0,\"start_tc_rate\":30}')")
    Sequence.ensure_master("_blade_media", "default_project", { id = "_blade_master" })
end

local function create_clip(id, track_id, start_frame, duration_frame)
    local conn = database.get_connection()
    local media_id = id .. "_media"
    bootstrap_blade_master()

    test_env.create_test_media({
        id = media_id,
        project_id = "default_project",
        name = id .. ".mov",
        file_path = "/tmp/jve/" .. id .. ".mov",
        duration_frames = duration_frame,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })

    local now = os.time()
    -- V13 INSERT: nested_sequence_id replaces media_id; placeholder master is
    -- created at file scope.
    local clip_stmt = conn:prepare([[
        INSERT INTO clips (id, project_id, name, track_id,
                            owner_sequence_id, nested_sequence_id,
                            timeline_start_frame, duration_frames,
                            source_in_frame, source_out_frame,
                            master_layer_track_id, master_audio_track_id,
                            fps_mismatch_policy,
                            enabled, volume, playhead_frame,
                            created_at, modified_at)
        VALUES (?, 'default_project', 'Clip', ?, 'default_sequence', '_blade_master',
                ?, ?, 0, ?, NULL, NULL, 'resample', 1, 1.0, 0, ?, ?)
    ]])
    assert(clip_stmt, "failed to prepare clip insert: " .. tostring(conn:last_error()))
    assert(clip_stmt:bind_value(1, id))
    assert(clip_stmt:bind_value(2, track_id))
    assert(clip_stmt:bind_value(3, start_frame))
    assert(clip_stmt:bind_value(4, duration_frame))
    assert(clip_stmt:bind_value(5, duration_frame))
    assert(clip_stmt:bind_value(6, now))
    assert(clip_stmt:bind_value(7, now))
    assert(clip_stmt:exec(), "failed to insert clip: " .. tostring(conn:last_error()))
    clip_stmt:finalize()
end

local function fetch_clip(id)
    local stmt = database.get_connection():prepare([[SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local start_val = stmt:value(0)
    local duration_val = stmt:value(1)
    stmt:finalize()
    -- Convert to MS for test logic
    local start_ms = math.floor(start_val / 30.0 * 1000.0 + 0.5)
    local dur_ms = math.floor(duration_val / 30.0 * 1000.0 + 0.5)
    return start_ms, dur_ms
end

local function clip_count()
    local stmt = database.get_connection():prepare([[SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'default_sequence']])
    assert(stmt:exec() and stmt:next())
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local function clip_exists_at(track_id, start_ms)
    -- Convert MS to frames for query
    local start_frame = math.floor(start_ms * 30.0 / 1000.0 + 0.5)
    local stmt = database.get_connection():prepare([[
        SELECT 1 FROM clips WHERE track_id = ? AND timeline_start_frame = ? LIMIT 1
    ]])
    assert(stmt, "failed to prepare clip lookup")
    assert(stmt:bind_value(1, track_id))
    assert(stmt:bind_value(2, start_frame))
    local exists = stmt:exec() and stmt:next()
    stmt:finalize()
    return exists
end

local TEST_DB = "/tmp/jve/test_blade_command.db"
setup_db(TEST_DB)

database.init(TEST_DB) -- ensure database module uses this db
local db = database.get_connection()
command_manager.init('default_sequence', 'default_project')

-- Stub timeline state
timeline_state.get_playhead_position = function() return 0 end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator=30, fps_denominator=1} end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.reload_clips = function(_) end

local function reset_clips()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM media")
    -- Create clips with Frame values
    -- 1500ms = 45 frames. 3000ms = 90 frames. 500ms = 15 frames. 1200ms = 36 frames. 5000ms = 150 frames.
    create_clip('clip_a', 'track_v1', 0, 45)
    create_clip('clip_b', 'track_v1', 90, 45)
    create_clip('clip_c', 'track_v2', 15, 36)
    create_clip('clip_d', 'track_v2', 150, 45)
    timeline_state.reload_clips()
end

local function execute_batch_split(split_value_ms, clip_ids)
    -- Convert MS to Frames (approx 30fps)
    local frames = math.floor(split_value_ms * 30.0 / 1000.0 + 0.5)

    command_manager.begin_undo_group("split")
    for _, clip in ipairs(clip_ids) do
        local cmd = Command.create("SplitClip", "default_project")
        cmd:set_parameter("clip_id", clip.id or clip)
        cmd:set_parameter("split_frame", frames)
        cmd:set_parameter("sequence_id", "default_sequence")
        local ok = command_manager.execute(cmd)
        assert(ok.success, ok.error_message or "SplitClip failed")
    end
    command_manager.end_undo_group()
end

print("=== Blade Command Tests ===\n")

-- Scenario 1: No selection - split all clips under playhead
reset_clips()
timeline_state.set_selection({})
timeline_state.set_playhead_position(1000) -- 1000ms = 30 frames

-- Stub get_clips_at_time to return mock clips with ID and MS start/dur for test logic (before DB reload?)
-- Wait, execute_batch_split takes clip_ids.
-- get_clips_at_time queries DB/state.
-- I need a real implementation of get_clips_at_time or a better stub.
timeline_state.get_clips_at_time = function(time_ms, allowed)
    local results = {}
    -- Check DB directly
    local conn = database.get_connection()
    local q = conn:prepare("SELECT id, timeline_start_frame, duration_frames FROM clips")
    if q:exec() then
        while q:next() do
            local start = q:value(1) * 1000.0 / 30.0
            local dur = q:value(2) * 1000.0 / 30.0
            if time_ms > start and time_ms < (start + dur) then
                table.insert(results, {id = q:value(0)})
            end
        end
    end
    q:finalize()
    -- Apply selection filter if needed (logic skipped for simplicity if allowed is used later)
    if allowed and #allowed > 0 then
        local filtered = {}
        for _, c in ipairs(results) do
            for _, a in ipairs(allowed) do
                if c.id == (a.id or a) then table.insert(filtered, c) break end
            end
        end
        return filtered
    end
    return results
end

local targets = timeline_state.get_clips_at_time(1000)
assert(#targets == 2, "Expected two clips under playhead (A and C)")
local before_count = clip_count()
execute_batch_split(1000, targets)
local after_count = clip_count()
assert(after_count == before_count + #targets, "Each split should add one clip")
local start_a, dur_a = fetch_clip('clip_a')
-- 1000ms = 30 frames. Clip A was 45 frames (1500ms).
-- Should be trimmed to 30 frames (1000ms).
assert(start_a == 0 and dur_a == 1000, "clip_a should be trimmed to first segment")
assert(clip_exists_at('track_v1', 1000), "Second segment of clip_a should exist")
assert(clip_exists_at('track_v2', 1000), "Second segment of clip_c should exist")

-- Scenario 2: Selection limits split targets
reset_clips()
timeline_state.set_selection({{id = 'clip_a'}})
timeline_state.set_playhead_position(1000)
local selected_targets = timeline_state.get_clips_at_time(1000, {'clip_a'})
assert(#selected_targets == 1, "Only selected clip should be targeted")
before_count = clip_count()
execute_batch_split(1000, selected_targets)
after_count = clip_count()
assert(after_count == before_count + #selected_targets, "Split should only add one clip")
local _, dur_c = fetch_clip('clip_c')
assert(dur_c == 1200, "Unselected clip should remain unchanged (36 frames = 1200ms)")

print("✅ Blade splits apply to clips under playhead with selection rules")
