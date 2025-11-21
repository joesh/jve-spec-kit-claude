#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local Clip = require('models.clip')
local Media = require('models.media')

local TEST_DB = "/tmp/jve/test_ripple_delete_gap.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec(require('import_schema')))
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                          timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 'video_frames', 30.0, 1, 1),
           ('track_v2', 'default_sequence', 'V2', 'VIDEO', 'video_frames', 30.0, 2, 1);
]]))

local function ensure_media(id, duration_value)
    local stmt = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, 'default_project', ?, ?, ?, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'raw', strftime('%s','now'), strftime('%s','now'), '{}')
    ]])
    assert(stmt, "failed to prepare media insert")
    assert(stmt:bind_value(1, id))
    assert(stmt:bind_value(2, id))
    assert(stmt:bind_value(3, "/tmp/jve/" .. id .. ".mov"))
    assert(stmt:bind_value(4, duration_value))
    assert(stmt:exec(), "failed to insert media")
    stmt:finalize()
    return id
end

local function insert_clip(id, track_id, start_value, duration_value)
    local media_id = ensure_media(id .. "_media", duration_value)
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id,
                           start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled, offline, created_at, modified_at)
        VALUES (?, 'default_project', 'timeline', ?, ?, ?, 'default_sequence', NULL, 'default_sequence',
                ?, ?, 0, ?, 'video_frames', 30.0, 1, 0, strftime('%s','now'), strftime('%s','now'))
    ]])
    assert(stmt, "failed to prepare clip insert")
    assert(stmt:bind_value(1, id))
    assert(stmt:bind_value(2, id))
    assert(stmt:bind_value(3, track_id))
    assert(stmt:bind_value(4, media_id))
    assert(stmt:bind_value(5, start_value))
    assert(stmt:bind_value(6, duration_value))
    assert(stmt:bind_value(7, start_value + duration_value))
    assert(stmt:exec(), "failed to insert clip " .. id)
    stmt:finalize()
end

local function fetch_clip_start(id)
    local stmt = db:prepare("SELECT start_value FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

insert_clip("clip_a", "track_v1", 0, 1000)
insert_clip("clip_b", "track_v1", 2000, 500)
insert_clip("clip_c", "track_v2", 2000, 500)

local timeline_state = {
    playhead_value = 0,
}

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.set_selection() end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    return mutations ~= nil
end
function timeline_state.get_sequence_frame_rate() return 30.0 end
function timeline_state.consume_mutation_failure()
    return nil
end
function timeline_state.get_clips()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, start_value, duration_value FROM clips ORDER BY track_id, start_value")
    if stmt:exec() then
        while stmt:next() do
            clips[#clips + 1] = {
                id = stmt:value(0),
                track_id = stmt:value(1),
                start_value = stmt:value(2),
                duration_value = stmt:value(3)
            }
        end
    end
    stmt:finalize()
    return clips
end
function timeline_state.get_sequence_id() return "default_sequence" end
function timeline_state.get_project_id() return "default_project" end
function timeline_state.get_playhead_value() return timeline_state.playhead_value end
function timeline_state.set_playhead_value(t) timeline_state.playhead_value = t end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 30.0} end
function timeline_state.restore_viewport(_) end
function timeline_state.get_viewport_start_value() return 0 end
function timeline_state.get_viewport_duration_frames_value() return 240 end
function timeline_state.set_viewport_start_value(_) end
function timeline_state.set_viewport_duration_frames_value(_) end
-- Legacy aliases for any remaining callers
timeline_state.get_viewport_start_value = timeline_state.get_viewport_start_value
timeline_state.get_viewport_duration_frames_value = timeline_state.get_viewport_duration_frames_value
timeline_state.set_viewport_start_value = timeline_state.set_viewport_start_value
timeline_state.set_viewport_duration_frames_value = timeline_state.set_viewport_duration_frames_value
function timeline_state.set_dragging_playhead(_) end
function timeline_state.is_dragging_playhead() return false end
function timeline_state.get_selected_gaps() return {} end
function timeline_state.get_all_tracks()
    return {
        {id = "track_v1", track_type = "VIDEO"},
        {id = "track_v2", track_type = "VIDEO"},
    }
end
function timeline_state.get_track_height(_) return 50 end
function timeline_state.time_to_pixel(time_ms, _) return time_ms end
function timeline_state.pixel_to_time(x, _) return x end
function timeline_state.get_sequence_frame_rate() return 30 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
command_manager.init(db, 'default_sequence', 'default_project')

local function exec_ripple()
    local cmd = Command.create("RippleDelete", "default_project")
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("gap_start", 1000)
    cmd:set_parameter("gap_duration", 1000)
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleDelete failed")
end

local function assert_close(expected, actual, label)
    if math.abs(expected - actual) > 0 then
        error(string.format("%s expected %d, got %d", label, expected, actual))
    end
end

-- Execute ripple delete: both tracks should shift
exec_ripple()
assert_close(1000, fetch_clip_start("clip_b"), "clip_b start")
assert_close(1000, fetch_clip_start("clip_c"), "clip_c start")

-- Undo should restore original positions
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")
assert_close(2000, fetch_clip_start("clip_b"), "clip_b undo start")
assert_close(2000, fetch_clip_start("clip_c"), "clip_c undo start")

-- Redo should shift again on all tracks
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")
assert_close(1000, fetch_clip_start("clip_b"), "clip_b redo start")
assert_close(1000, fetch_clip_start("clip_c"), "clip_c redo start")

print("✅ RippleDelete gap ripple test passed")
