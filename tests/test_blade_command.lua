#!/usr/bin/env luajit

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local function setup_db(path)
    os.remove(path)
    database.init(path)
    local db = database.get_connection()

    db:exec(require('import_schema'))

    local now = os.time()
    db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
        VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
        INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 2, 1);
    ]], now, now))

    return db
end

local function create_clip(id, track_id, start_value, duration_value)
    local conn = database.get_connection()
    local media_id = id .. "_media"

    local media_stmt = conn:prepare([[
        INSERT OR REPLACE INTO media (
            id,
            project_id,
            name,
            file_path,
            duration_value,
            timebase_type,
            timebase_rate,
            frame_rate,
            width,
            height,
            audio_channels,
            codec,
            created_at,
            modified_at,
            metadata
        )
        VALUES (?, ?, ?, ?, ?, 'video_frames', 30.0, 30.0, 1920, 1080, 0, '', 0, 0, '{}')
    ]])
    assert(media_stmt, "failed to prepare media insert")
    assert(media_stmt:bind_value(1, media_id))
    assert(media_stmt:bind_value(2, "default_project"))
    assert(media_stmt:bind_value(3, id .. ".mov"))
    assert(media_stmt:bind_value(4, "/tmp/jve/" .. id .. ".mov"))
    assert(media_stmt:bind_value(5, duration_value))
    assert(media_stmt:exec())
    media_stmt:finalize()

    local clip_stmt = conn:prepare([[
        INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled)
        VALUES (?, ?, ?, ?, ?, 0, ?, 'video_frames', 30.0, 1)
    ]])
    assert(clip_stmt, "failed to prepare clip insert")
    assert(clip_stmt:bind_value(1, id))
    assert(clip_stmt:bind_value(2, track_id))
    assert(clip_stmt:bind_value(3, media_id))
    assert(clip_stmt:bind_value(4, start_value))
    assert(clip_stmt:bind_value(5, duration_value))
    assert(clip_stmt:bind_value(6, duration_value))
    assert(clip_stmt:exec())
    clip_stmt:finalize()
end

local function fetch_clip(id)
    local stmt = database.get_connection():prepare([[SELECT start_value, duration_value FROM clips WHERE id = ?]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local start_value = stmt:value(0)
    local duration_value = stmt:value(1)
    stmt:finalize()
    return start_value, duration_value
end

local function clip_count()
    local stmt = database.get_connection():prepare([[SELECT COUNT(*) FROM clips]])
    assert(stmt:exec() and stmt:next())
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local function clip_exists_at(track_id, start_value)
    local stmt = database.get_connection():prepare([[
        SELECT 1 FROM clips WHERE track_id = ? AND start_value = ? LIMIT 1
    ]])
    assert(stmt, "failed to prepare clip lookup")
    assert(stmt:bind_value(1, track_id))
    assert(stmt:bind_value(2, start_value))
    local exists = stmt:exec() and stmt:next()
    stmt:finalize()
    return exists
end

local TEST_DB = "/tmp/jve/test_blade_command.db"
local db = setup_db(TEST_DB)

database.init(TEST_DB) -- ensure database module uses this db
db = database.get_connection()
command_impl.register_commands({}, {}, db)
command_manager.init(db, 'default_sequence', 'default_project')

local timeline_state = require('ui.timeline.timeline_state')

local function reset_clips()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM media")
    create_clip('clip_a', 'track_v1', 0, 1500)
    create_clip('clip_b', 'track_v1', 3000, 1500)
    create_clip('clip_c', 'track_v2', 500, 1200)
    create_clip('clip_d', 'track_v2', 5000, 1500)
    timeline_state.reload_clips()
end

local function execute_batch_split(split_value, clip_ids)
    local json = dkjson
    local specs = {}
    for _, clip in ipairs(clip_ids) do
        table.insert(specs, {
            command_type = "SplitClip",
            parameters = {
                clip_id = clip.id or clip,
                split_value = split_value
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
timeline_state.set_playhead_value(1000)
local targets = timeline_state.get_clips_at_time(1000)
assert(#targets == 2, "Expected two clips under playhead")
local before_count = clip_count()
execute_batch_split(1000, targets)
local after_count = clip_count()
assert(after_count == before_count + #targets, "Each split should add one clip")
local start_a, dur_a = fetch_clip('clip_a')
assert(start_a == 0 and dur_a == 1000, "clip_a should be trimmed to first segment")
assert(clip_exists_at('track_v1', 1000), "Second segment of clip_a should exist")
assert(clip_exists_at('track_v2', 1000), "Second segment of clip_c should exist")

-- Scenario 2: Selection limits split targets
reset_clips()
timeline_state.set_selection({{id = 'clip_a'}})
timeline_state.set_playhead_value(1000)
local selected_targets = timeline_state.get_clips_at_time(1000, {'clip_a'})
assert(#selected_targets == 1, "Only selected clip should be targeted")
before_count = clip_count()
execute_batch_split(1000, selected_targets)
after_count = clip_count()
assert(after_count == before_count + #selected_targets, "Split should only add one clip")
local _, dur_c = fetch_clip('clip_c')
assert(dur_c == 1200, "Unselected clip should remain unchanged")

print("✅ Blade splits apply to clips under playhead with selection rules")
