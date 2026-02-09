#!/usr/bin/env luajit

require('test_env')

local dkjson = require('dkjson')
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
        INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
        VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1);
    ]], now, now, now, now))

    return db
end

local function create_clip(id, track_id, start_frame, duration_frame)
    local conn = database.get_connection()
    local media_id = id .. "_media"

    local media_stmt = conn:prepare([[
        INSERT OR REPLACE INTO media (
            id,
            project_id,
            name,
            file_path,
            duration_frames,
            fps_numerator,
            fps_denominator,
            width,
            height,
            audio_channels,
            codec,
            created_at,
            modified_at,
            metadata
        )
        VALUES (?, ?, ?, ?, ?, 30, 1, 1920, 1080, 0, '', 0, 0, '{}')
    ]])
    assert(media_stmt, "failed to prepare media insert")
    assert(media_stmt:bind_value(1, media_id))
    assert(media_stmt:bind_value(2, "default_project"))
    assert(media_stmt:bind_value(3, id .. ".mov"))
    assert(media_stmt:bind_value(4, "/tmp/jve/" .. id .. ".mov"))
    assert(media_stmt:bind_value(5, duration_frame))
    assert(media_stmt:exec())
    media_stmt:finalize()

    local now = os.time()
    local clip_stmt = conn:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, created_at, modified_at)
        VALUES (?, 'default_project', 'timeline', 'Clip', ?, ?, 'default_sequence', ?, ?, 0, ?, 30, 1, 1, ?, ?)
    ]])
    assert(clip_stmt, "failed to prepare clip insert: " .. tostring(conn:last_error()))
    assert(clip_stmt:bind_value(1, id))
    assert(clip_stmt:bind_value(2, track_id))
    assert(clip_stmt:bind_value(3, media_id))
    assert(clip_stmt:bind_value(4, start_frame))
    assert(clip_stmt:bind_value(5, duration_frame))
    assert(clip_stmt:bind_value(6, duration_frame))
    assert(clip_stmt:bind_value(7, now))
    assert(clip_stmt:bind_value(8, now))
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
    local stmt = database.get_connection():prepare([[SELECT COUNT(*) FROM clips]])
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
local db = setup_db(TEST_DB)

database.init(TEST_DB) -- ensure database module uses this db
db = database.get_connection()
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
    local json = dkjson
    local specs = {}
    -- Convert MS to Frames (approx 30fps)
    local frames = math.floor(split_value_ms * 30.0 / 1000.0 + 0.5)
    
    for _, clip in ipairs(clip_ids) do
        table.insert(specs, {
            command_type = "SplitClip",
            parameters = {
                clip_id = clip.id or clip,
                split_value = frames  -- integer frames
            }
        })
    end

    local batch_cmd = Command.create("BatchCommand", "default_project")
    batch_cmd:set_parameter("commands_json", json.encode(specs))
    local ok = command_manager.execute(batch_cmd)
    assert(ok.success, ok.error_message or "Batch split failed")
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
