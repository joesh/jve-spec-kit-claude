#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;../tests/?.lua"

local test_env = require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local _ = require('core.command_implementations') -- load for side effects
local Command = require('command')
local timeline_state = require('ui.timeline.timeline_state')
local Media = require('models.media')

local function setup_db(path)
    os.remove(path)
    assert(database.init(path))
    local conn = database.get_connection()

    conn:exec(require('import_schema'))

    assert(conn:exec([[
INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 10000, 0, strftime('%s','now'), strftime('%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('track_default_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    ]]))

    -- command_impl.register_commands({}, {}, conn)
    command_manager.init('default_sequence', 'default_project')
    timeline_state.init('default_sequence')

    -- Register schema for TestCreateMedia test command
    local test_create_media_spec = {
        args = {
            project_id = { kind = "string", required = false },
            media_id = { kind = "string", required = true },
            file_path = { kind = "string", required = true },
            file_name = { kind = "string", required = false },
            duration = { kind = "number", required = false },
            duration_value = { kind = "number", required = false },
            frame_rate = { kind = "number", required = false },
        }
    }

    command_manager.register_executor("TestCreateMedia", function(cmd)
        local media = Media.create({
            id = cmd:get_parameter("media_id"),
            project_id = cmd:get_parameter("project_id") or 'default_project',
            file_path = cmd:get_parameter("file_path"),
            name = cmd:get_parameter("file_name"),
            duration_frames = cmd:get_parameter("duration_value") or cmd:get_parameter("duration"),
            fps_numerator = 30,
            fps_denominator = 1,
            frame_rate = cmd:get_parameter("frame_rate") or 30.0,
            width = 1920,
            height = 1080,
            audio_channels = 0,  -- Video-only for this test
            audio_sample_rate = 48000,
            metadata = "{}"
        })
        assert(media, "failed to create media " .. tostring(cmd:get_parameter("media_id")))
        return media:save(conn)
    end, nil, test_create_media_spec)

    return conn
end

local db = setup_db("/tmp/jve/test_ripple_redo_integrity.db")

local media_cmd = Command.create("TestCreateMedia", "default_project")
media_cmd:set_parameter("media_id", "media_src")
media_cmd:set_parameter("file_path", "/tmp/jve/media_src.mov")
media_cmd:set_parameter("file_name", "Test Media")
media_cmd:set_parameter("duration", 10000000)
media_cmd:set_parameter("frame_rate", 30)
local media_result = command_manager.execute(media_cmd)
assert(media_result.success, media_result.error_message or "TestCreateMedia failed")

-- Create masterclip sequence for the media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Media Src Master', 30, 1, 10000000, 'media_src')

local function exec(cmd)
    local result = command_manager.execute(cmd)
    assert(result.success, "Command failed: " .. tostring(result.error_message))
    return result
end

local function clip_count()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline' AND owner_sequence_id = 'default_sequence'")
    assert(stmt:exec(), "Failed to count clips")
    assert(stmt:next(), "Count query produced no rows")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("master_clip_id", master_clip_id)
insert_cmd:set_parameter("track_id", "track_default_v1")
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("duration", 4543560)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4543560)
insert_cmd:set_parameter("sequence_id", "default_sequence")
exec(insert_cmd)

local stmt = db:prepare("SELECT id FROM clips LIMIT 1")
assert(stmt:exec() and stmt:next(), "Inserted clip not found")
local clip_id = stmt:value(0)
stmt:finalize()

local function delete_delta_frames(target_clip_id)
    local dur_stmt = db:prepare([[
        SELECT duration_frames, fps_numerator, fps_denominator
        FROM clips
        WHERE id = ?
    ]])
    assert(dur_stmt, "failed to prepare clip duration lookup")
    assert(dur_stmt:bind_value(1, target_clip_id))
    assert(dur_stmt:exec() and dur_stmt:next(), "Failed to load clip duration for ripple delete")
    local duration_frames = dur_stmt:value(0)
    local fps_num = dur_stmt:value(1)
    local fps_den = dur_stmt:value(2)
    dur_stmt:finalize()

    local extra_one_second = math.ceil(fps_num / fps_den)
    -- Overshoot by ~1s worth of frames to guarantee deletion
    return -(duration_frames + extra_one_second)
end

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {clip_id = clip_id, edge_type = "gap_before", track_id = "track_default_v1"})
ripple_cmd:set_parameter("delta_frames", delete_delta_frames(clip_id))  -- computed negative delta large enough to remove the clip
ripple_cmd:set_parameter("sequence_id", "default_sequence")
exec(ripple_cmd)

local function snapshot_clips()
    local snap_stmt = db:prepare([[
        SELECT id, track_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM clips
        WHERE clip_kind = 'timeline' AND owner_sequence_id = 'default_sequence'
        ORDER BY track_id, timeline_start_frame
    ]])
    assert(snap_stmt:exec(), "Failed to fetch clips for snapshot")

    local snap_clips = {}
    while snap_stmt:next() do
        snap_clips[#snap_clips + 1] = {
            id = snap_stmt:value(0),
            track_id = snap_stmt:value(1),
            start_value = snap_stmt:value(2),
            duration_value = snap_stmt:value(3),
            source_in_value = snap_stmt:value(4),
            source_out_value = snap_stmt:value(5),
        }
    end
    snap_stmt:finalize()
    return snap_clips
end

local function states_match(expected, actual)
    if #expected ~= #actual then
        return false
    end
    for idx = 1, #expected do
        local want = expected[idx]
        local got = actual[idx]
        for _, field in ipairs({"id", "track_id", "start_value", "duration_value", "source_in_value", "source_out_value"}) do
            if want[field] ~= got[field] then
                return false, string.format(
                    "clip mismatch at index %d field %s (expected=%s, actual=%s)",
                    idx,
                    field,
                    tostring(want[field]),
                    tostring(got[field])
                )
            end
        end
    end
    return true
end

local state_after_ripple = snapshot_clips()
local clip_count_after_ripple = clip_count()

assert(command_manager.undo().success, "Undo failed")
assert(clip_count() == 1, "Undo should restore the original clip")

assert(command_manager.redo().success, "Redo failed")
assert(clip_count() == clip_count_after_ripple, "Redo should return to post-ripple clip count")

local redo_state = snapshot_clips()
local ok, mismatch = states_match(state_after_ripple, redo_state)
assert(ok, mismatch or "Redo clip state differs from original post-ripple state")

print("✅ Ripple redo preserves clip deletions")

-- Regression: extending a clip keeps the downstream neighbour adjacent (no gaps)
db = setup_db("/tmp/jve/test_ripple_gap_alignment.db")

media_cmd = Command.create("TestCreateMedia", "default_project")
media_cmd:set_parameter("media_id", "media_src")
media_cmd:set_parameter("file_path", "/tmp/jve/media_src.mov")
media_cmd:set_parameter("file_name", "Test Media")
media_cmd:set_parameter("duration", 10000000)
media_cmd:set_parameter("frame_rate", 30)
media_result = command_manager.execute(media_cmd)
assert(media_result.success, media_result.error_message or "TestCreateMedia failed")

-- Create masterclip sequence for the media (required for Insert)
master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Media Src Master', 30, 1, 10000000, 'media_src')

local function insert_clip(start_value, duration, source_in)
    local cmd = Command.create("Insert", "default_project")
    cmd:set_parameter("master_clip_id", master_clip_id)
    cmd:set_parameter("track_id", "track_default_v1")
    cmd:set_parameter("insert_time", start_value)
    cmd:set_parameter("duration", duration)
    cmd:set_parameter("source_in", source_in or 0)
    cmd:set_parameter("source_out", (source_in or 0) + duration)
    cmd:set_parameter("sequence_id", "default_sequence")
    exec(cmd)
end

local function fetch_clips_ordered()
    local order_stmt = db:prepare([[
        SELECT id, timeline_start_frame, duration_frames
        FROM clips
        WHERE clip_kind = 'timeline' AND owner_sequence_id = 'default_sequence'
        ORDER BY timeline_start_frame
    ]])
    assert(order_stmt:exec(), "Failed to fetch clip ordering")
    local ordered_clips = {}
    while order_stmt:next() do
        ordered_clips[#ordered_clips + 1] = {
            id = order_stmt:value(0),
            start_value = order_stmt:value(1),
            duration_value = order_stmt:value(2)
        }
    end
    order_stmt:finalize()
    return ordered_clips
end

insert_clip(0, 1713800, 0)
insert_clip(1713800, 2332838, 1713800)

local initial_clips = fetch_clips_ordered()
assert(#initial_clips == 2, string.format("expected two clips before ripple, got %d", #initial_clips))

local first_initial = initial_clips[1]
local second_initial = initial_clips[2]

local extend_delta_frames = math.floor((1900329 * 30 / 1000) + 0.5) -- convert ms to frames at 30fps
local extend_cmd = Command.create("RippleEdit", "default_project")
extend_cmd:set_parameter("edge_info", {clip_id = first_initial.id, edge_type = "out", track_id = "track_default_v1"})
extend_cmd:set_parameter("delta_frames", extend_delta_frames)
extend_cmd:set_parameter("sequence_id", "default_sequence")
exec(extend_cmd)

local post_clips = fetch_clips_ordered()
assert(#post_clips == 2, string.format("expected two clips after ripple, got %d", #post_clips))

local first_after = post_clips[1]
local second_after = post_clips[2]
local actual_extension = first_after.duration_value - first_initial.duration_value

assert(actual_extension > 0, "expected first clip duration to increase")

local expected_second_start = second_initial.start_value + actual_extension
assert(second_after.start_value == expected_second_start,
    string.format("downstream clip should shift by actual extension (expected %d, got %d)",
        expected_second_start, second_after.start_value))

local first_end = first_after.start_value + first_after.duration_value
assert(first_end == second_after.start_value,
    string.format("clips should remain touching after ripple (expected contact %d, found %d)",
        first_end, second_after.start_value))

print("✅ Ripple extension maintains adjacency")
