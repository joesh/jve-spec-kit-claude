--- MarkClipExtent command: X key — set marks to clip boundaries under playhead.
--
-- Finds the best clip under playhead (priority: video > audio, lower track_index first).
-- Sets mark_in to clip start and mark_out to clip's last frame.
--
-- @file mark_clip_extent.lua
local M = {}

local SPEC = {
    -- SetMarkIn and SetMarkOut are each individually undoable. MarkClipExtent
    -- is one user action (X press) → must collapse to one undo step. We
    -- bracket the two sub-executes in begin_undo_group / end_undo_group;
    -- this command itself is not directly undoable (no own undoer), it just
    -- groups the two writes.
    undoable = false,
    mutates_clips = false,
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

-- Find the topmost clip under `playhead`. Priority: video over audio; within
-- a type, lower track_index wins. Returns nil if no clip straddles the
-- playhead. Asserts on malformed clip/track data — those are bugs, not
-- "no clip here" situations.
local function pick_clip_under_playhead(timeline_state, playhead)
    local clips = timeline_state.get_clips()
    local best_clip, best_priority

    for _, clip in ipairs(clips) do
        local clip_start = clip.timeline_start or clip.start_value
        assert(clip_start, string.format(
            "MarkClipExtent: clip %s missing timeline_start", tostring(clip.id)))
        assert(clip.duration, string.format(
            "MarkClipExtent: clip %s missing duration", tostring(clip.id)))
        local clip_end = clip_start + clip.duration

        if playhead >= clip_start and playhead <= clip_end then
            local track = timeline_state.get_track_by_id
                and timeline_state.get_track_by_id(clip.track_id)
            if track then
                local type_priority = (track.track_type == "VIDEO") and 0 or 1
                local track_index = track.track_index
                    or (timeline_state.get_track_index
                        and timeline_state.get_track_index(clip.track_id))
                assert(track_index, string.format(
                    "MarkClipExtent: track %s missing track_index", tostring(clip.track_id)))
                local priority = type_priority * 1000 + track_index
                if not best_priority or priority < best_priority then
                    best_priority = priority
                    best_clip = clip
                end
            end
        end
    end

    return best_clip
end

-- Atomically set mark_in + mark_out so a single undo restores the prior
-- mark state. SetMarkIn and SetMarkOut are independently undoable; bracketing
-- them in begin_undo_group / end_undo_group collapses them into one stack
-- entry. The pcall is purely to guarantee end_undo_group runs on inner
-- failure — the assert(ok, err) re-raises after cleanup (rule 1.14).
local function dispatch_grouped_marks(project_id, sequence_id, mark_in, mark_out_last_frame)
    local command_manager = require("core.command_manager")
    command_manager.begin_undo_group("MarkClipExtent")
    local ok, err = pcall(function()
        local r_in = command_manager.execute("SetMarkIn",
            { project_id = project_id, sequence_id = sequence_id, frame = mark_in })
        assert(r_in and (r_in == true or r_in.success),
            "MarkClipExtent: SetMarkIn failed: "
            .. tostring(r_in and r_in.error_message))
        local r_out = command_manager.execute("SetMarkOut",
            { project_id = project_id, sequence_id = sequence_id, frame = mark_out_last_frame })
        assert(r_out and (r_out == true or r_out.success),
            "MarkClipExtent: SetMarkOut failed: "
            .. tostring(r_out and r_out.error_message))
    end)
    command_manager.end_undo_group()
    assert(ok, err)
end

function M.register(executors, undoers, db)
    local function executor(command)
        local timeline_state = require('ui.timeline.timeline_state')

        local playhead = timeline_state.get_playhead_position()
        assert(playhead, "MarkClipExtent: playhead is nil")

        local best_clip = pick_clip_under_playhead(timeline_state, playhead)
        if not best_clip then return true end

        local clip_start = best_clip.timeline_start or best_clip.start_value
        -- mark_out is stored exclusive; inclusive last frame = start + dur - 1.
        local clip_last_frame = clip_start + best_clip.duration - 1

        local args = command:get_all_parameters()
        -- MarkClipExtent is a movement command (mutates_clips=false). For
        -- UI/keymap dispatch the framework auto-injects sequence_id from
        -- the focused panel via execute_interactive (command_manager.lua
        -- §movement-injection). Scripted callers must pass it explicitly.
        -- No `or get_sequence_id()` fallback — the framework injection and
        -- the executor reading from a different state-getter were two
        -- sources of truth that could disagree on Source-tab dispatch
        -- (display-aware vs active-record).
        assert(args.sequence_id, "MarkClipExtent: sequence_id required — "
            .. "UI dispatch auto-injects via execute_interactive; "
            .. "scripted callers must pass it explicitly")

        dispatch_grouped_marks(args.project_id, args.sequence_id, clip_start, clip_last_frame)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
