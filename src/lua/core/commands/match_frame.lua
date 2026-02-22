--- Match Frame: reveal the master clip for the clip under the playhead.
--
-- Resolution order:
-- 1. Get all clips under the playhead
-- 2. If any are selected, filter to only selected clips
-- 3. Pick the topmost (highest track_index) from the candidates
-- 4. Focus that clip's master clip in the project browser
--
-- @file match_frame.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local project_browser = require('ui.project_browser')


local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = {},
        skip_activate = {},
        skip_focus = {},
    }
}

local function extract_master_clip_id(clip)
    if type(clip) ~= "table" then return nil end
    if clip.master_clip_id and clip.master_clip_id ~= "" then
        return clip.master_clip_id
    end
    return nil
end

local function track_index_for_clip(clip)
    assert(clip.track_id, string.format(
        "track_index_for_clip: clip %s has no track_id", tostring(clip.id)))
    local track = timeline_state.get_track_by_id(clip.track_id)
    assert(track, string.format(
        "track_index_for_clip: track %s not found for clip %s",
        tostring(clip.track_id), tostring(clip.id)))
    return track.track_index
end

--- From candidates, pick the topmost (highest track_index).
local function pick_topmost(candidates)
    assert(#candidates > 0, "pick_topmost: candidates must be non-empty")
    local best = nil
    local best_index = -1
    for _, clip in ipairs(candidates) do
        local idx = track_index_for_clip(clip)
        if idx > best_index then
            best = clip
            best_index = idx
        end
    end
    return best
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["MatchFrame"] = function(command)
        local args = command:get_all_parameters()

        local playhead = timeline_state.get_playhead_position()
        local clips_at_playhead = timeline_state.get_clips_at_time(playhead)

        if #clips_at_playhead == 0 then
            set_last_error("MatchFrame: No clips under playhead")
            return false
        end

        -- If any clip under playhead is selected, prefer selected clips
        assert(timeline_state.get_selected_clips,
            "MatchFrame: timeline_state.get_selected_clips is missing")
        local selected = timeline_state.get_selected_clips()
        local selected_set = {}
        for _, clip in ipairs(selected) do
            if clip.id then selected_set[clip.id] = true end
        end

        local selected_under_playhead = {}
        for _, clip in ipairs(clips_at_playhead) do
            if selected_set[clip.id] then
                selected_under_playhead[#selected_under_playhead + 1] = clip
            end
        end

        local target_clip
        if #selected_under_playhead > 0 then
            target_clip = pick_topmost(selected_under_playhead)
        else
            target_clip = pick_topmost(clips_at_playhead)
        end

        local target_master_id = extract_master_clip_id(target_clip)
        if not target_master_id then
            set_last_error("MatchFrame: Clip is not linked to a master clip")
            return false
        end

        local ok, err = pcall(project_browser.focus_master_clip, target_master_id, {
            skip_focus = args.skip_focus == true,
            skip_activate = args.skip_activate == true
        })
        if not ok then
            set_last_error("MatchFrame: " .. tostring(err))
            return false
        end

        if err == false then
            set_last_error("MatchFrame: Failed to focus master clip")
            return false
        end

        return true
    end

    return {
        executor = command_executors["MatchFrame"],
        spec = SPEC,
    }
end

return M
