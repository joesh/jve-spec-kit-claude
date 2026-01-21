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
local Rational = require('core.rational')

local TEST_DB = "/tmp/jve/test_track_move_nudge.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Existing clips:
--   track_v2: clip_dest (500-3000)
--   track_v1: clip_keep (0-2000), clip_move (2000-3500)
local clip_move_start = 2000
local clip_move_duration = 1500
local nudge_amount_frames = 2000

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_dest', 'default_project', 'clip_dest.mov', '/tmp/jve/clip_dest.mov', 2500, 30, 1, 1920, 1080, 0, '', '{}', strftime('%%s','now'), strftime('%%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_keep', 'default_project', 'clip_keep.mov', '/tmp/jve/clip_keep.mov', 2000, 30, 1, 1920, 1080, 0, '', '{}', strftime('%%s','now'), strftime('%%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_move', 'default_project', 'clip_move.mov', '/tmp/jve/clip_move.mov', %d, 30, 1, 1920, 1080, 0, '', '{}', strftime('%%s','now'), strftime('%%s','now'));
]], clip_move_duration))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_dest', 'default_project', 'timeline', 'track_v2', 'media_dest', 'default_sequence', 500, 2500, 0, 2500, 30, 1, 1, 0, strftime('%%s','now'), strftime('%%s','now'));
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_keep', 'default_project', 'timeline', 'track_v1', 'media_keep', 'default_sequence', 0, 2000, 0, 2000, 30, 1, 1, 0, strftime('%%s','now'), strftime('%%s','now'));
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_move', 'default_project', 'timeline', 'track_v1', 'media_move', 'default_sequence', %d, %d, 0, %d, 30, 1, 1, 0, strftime('%%s','now'), strftime('%%s','now'));
]], clip_move_start, clip_move_duration, clip_move_duration))

-- Minimal stub for timeline state used by command_manager internals.
local timeline_state = {
    get_sequence_id = function() return "default_sequence" end,
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    normalize_edge_selection = function() end,
    clear_edge_selection = function() end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_playhead_position = function() return Rational.new(0, 30, 1) end,
    set_playhead_position = function() end,
    get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end,
    get_sequence_audio_sample_rate = function() return 48000 end,
    viewport_start_value = Rational.new(0, 30, 1),
    viewport_duration_frames_value = Rational.new(240, 30, 1),
    get_clips = function()
        local clips = {}
        local stmt = db:prepare("SELECT id, track_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator FROM clips ORDER BY timeline_start_frame")
        if stmt and stmt:exec() then
            while stmt:next() do
                local fps_num = stmt:value(7) or 30
                local fps_den = stmt:value(8) or 1
                clips[#clips + 1] = {
                    id = stmt:value(0),
                    track_id = stmt:value(1),
                    owner_sequence_id = stmt:value(2),
                    timeline_start = Rational.new(stmt:value(3), fps_num, fps_den),
                    duration = Rational.new(stmt:value(4), fps_num, fps_den),
                    source_in = Rational.new(stmt:value(5), fps_num, fps_den),
                    source_out = Rational.new(stmt:value(6), fps_num, fps_den)
                }
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
-- command_impl.register_commands(executors, undoers, db)

command_manager.init('default_sequence', 'default_project')

print("=== MoveClipToTrack + Nudge Regression ===\n")

local function fetch_clip(id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare clip fetch statement")
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
            pending_new_start_rat = {frames = clip_move_start + nudge_amount_frames, fps_numerator = 30, fps_denominator = 1},
            pending_duration_rat = {frames = clip_move_duration, fps_numerator = 30, fps_denominator = 1}
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount = nudge_amount_frames, -- move to the right, clearing the overlap
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
