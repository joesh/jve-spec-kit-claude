#!/usr/bin/env luajit

-- Regression test: moving a clip to another track and nudging it in a
-- single BatchCommand must not trim the clip that already lives on the
-- destination track. This used to happen because the MoveClipToTrack
-- command ran occlusion resolution before the follow-up nudge supplied
-- the clip's new time position.

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_track_move_nudge.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 2, 1);
]])

-- Existing clips:
--   track_v2: clip_dest (500-3000)
--   track_v1: clip_keep (0-2000), clip_move (2000-3500)
local clip_move_start = 2000
local clip_move_duration = 1500
local nudge_amount_ms = 2000

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata, timebase_type, timebase_rate)
    VALUES ('media_dest', 'default_project', 'clip_dest.mov', '/tmp/jve/clip_dest.mov', 2500, 30.0, 0, 0, '{}', 'video_frames', 30.0);
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata, timebase_type, timebase_rate)
    VALUES ('media_keep', 'default_project', 'clip_keep.mov', '/tmp/jve/clip_keep.mov', 2000, 30.0, 0, 0, '{}', 'video_frames', 30.0);
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata, timebase_type, timebase_rate)
    VALUES ('media_move', 'default_project', 'clip_move.mov', '/tmp/jve/clip_move.mov', %d, 30.0, 0, 0, '{}', 'video_frames', 30.0);
]], clip_move_duration))

db:exec(string.format([[
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate)
    VALUES ('clip_dest', 'track_v2', 'media_dest', 500, 2500, 0, 2500, 'video_frames', 30.0);
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate)
    VALUES ('clip_keep', 'track_v1', 'media_keep', 0, 2000, 0, 2000, 'video_frames', 30.0);
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate)
    VALUES ('clip_move', 'track_v1', 'media_move', %d, %d, 0, %d, 'video_frames', 30.0);
]], clip_move_start, clip_move_duration, clip_move_duration))

-- Minimal stub for timeline state used by command_manager internals.
local timeline_state = {
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    normalize_edge_selection = function() end,
    clear_edge_selection = function() end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_playhead_position = function() return 0 end,
    set_playhead_position = function() end,
    get_sequence_frame_rate = function() return 30.0 end,
    get_sequence_audio_sample_rate = function() return 48000 end,
    viewport_start_value = 0,
    viewport_duration_frames_value = 240,
    get_clips = function()
        local clips = {}
        local stmt = db:prepare("SELECT id FROM clips ORDER BY start_value")
        if stmt and stmt:exec() then
            while stmt:next() do
                clips[#clips + 1] = { id = stmt:value(0) }
            end
        end
        return clips
    end
}

local viewport_guard = 0

function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration_value = timeline_state.viewport_duration_frames_value,
    }
end

function timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration_value then
        timeline_state.viewport_duration_frames_value = snapshot.duration_value
    end

    if snapshot.start_value then
        timeline_state.viewport_start_value = snapshot.start_value
    end
end

function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)

command_manager.init(db, 'default_sequence', 'default_project')

print("=== MoveClipToTrack + Nudge Regression ===\n")

local function fetch_clip(id)
    local stmt = db:prepare("SELECT start_value, duration_value FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. id)
    return stmt:value(0), stmt:value(1)
end

local original_start, original_duration = fetch_clip('clip_dest')

local commands_json = dkjson.encode({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = "clip_move",
            target_track_id = "track_v2",
            skip_occlusion = true,
            pending_new_start_value = clip_move_start + nudge_amount_ms,
            pending_duration = clip_move_duration
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount_ms = nudge_amount_ms, -- move to the right, clearing the overlap
            selected_clip_ids = {"clip_move"}
        }
    }
})

local batch_cmd = Command.create("BatchCommand", "default_project")
batch_cmd:set_parameter("commands_json", commands_json)

local result = command_manager.execute(batch_cmd)
assert(result.success, "BatchCommand execution failed: " .. tostring(result.error_message))

local new_start, new_duration = fetch_clip('clip_dest')

assert(new_start == original_start,
    string.format("Destination clip start changed: %d -> %d", original_start, new_start))
assert(new_duration == original_duration,
    string.format("Destination clip duration changed: %d -> %d", original_duration, new_duration))

print("✅ MoveClipToTrack + Nudge preserves upstream clip on destination track")
