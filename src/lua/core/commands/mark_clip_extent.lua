--- MarkClipExtent command: X key — set marks to clip boundaries under playhead.
--
-- Finds the best clip under playhead (priority: video > audio, lower track_index first).
-- Sets mark_in to clip start and mark_out to clip's last frame.
--
-- @file mark_clip_extent.lua
local M = {}

local SPEC = {
    undoable = false,  -- delegates to SetMarkIn/SetMarkOut which ARE undoable
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local timeline_state = require('ui.timeline.timeline_state')

        local playhead = timeline_state.get_playhead_position()
        assert(playhead, "MarkClipExtent: playhead is nil")

        local clips = timeline_state.get_clips()
        local best_clip = nil
        local best_priority = nil

        for _, clip in ipairs(clips) do
            local clip_start = clip.timeline_start or clip.start_value
            assert(clip_start, string.format("MarkClipExtent: clip %s missing timeline_start", tostring(clip.id)))
            assert(clip.duration, string.format("MarkClipExtent: clip %s missing duration", tostring(clip.id)))
            local clip_end = clip_start + clip.duration

            if playhead >= clip_start and playhead <= clip_end then
                local track = timeline_state.get_track_by_id and timeline_state.get_track_by_id(clip.track_id)
                if track then
                    local type_priority = (track.track_type == "VIDEO") and 0 or 1
                    local track_index = track.track_index
                        or (timeline_state.get_track_index and timeline_state.get_track_index(clip.track_id))
                    assert(track_index,
                        string.format("MarkClipExtent: track %s missing track_index", tostring(clip.track_id)))
                    local priority = type_priority * 1000 + track_index
                    if not best_priority or priority < best_priority then
                        best_priority = priority
                        best_clip = clip
                    end
                end
            end
        end

        if best_clip then
            local clip_start = best_clip.timeline_start or best_clip.start_value
            -- Last included frame = clip_start + duration - 1
            local clip_last_frame = clip_start + best_clip.duration - 1
            local args = command:get_all_parameters()
            local seq_id = args.sequence_id or timeline_state.get_sequence_id()
            assert(seq_id, "MarkClipExtent: sequence_id missing from args and timeline_state")

            local command_manager = require("core.command_manager")
            command_manager.execute("SetMarkIn", {sequence_id = seq_id, frame = clip_start})
            command_manager.execute("SetMarkOut", {sequence_id = seq_id, frame = clip_last_frame})
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
