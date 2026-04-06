--- Match Frame: load the master clip for the clip under the playhead
--- into the source viewer, parked at the matching source frame.
--
-- Resolution order:
-- 1. Get all clips under the playhead
-- 2. If any are selected, filter to only selected clips
-- 3. Pick the best clip: video trumps audio, then topmost track_index
-- 4. Set marks + playhead on master clip, load in source viewer
--
-- @file match_frame.lua
local M = {}
local log = require("core.logger").for_area("commands")
local timeline_state = require('ui.timeline.timeline_state')
local source_viewer = require('ui.source_viewer')
local Sequence = require('models.sequence')
local command_helper = require("core.command_helper")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

local function extract_master_clip_id(clip)
    if type(clip) ~= "table" then return nil end
    if clip.master_clip_id and clip.master_clip_id ~= "" then
        return clip.master_clip_id
    end
    return nil
end

local function track_info_for_clip(clip)
    assert(clip.track_id, string.format(
        "track_info_for_clip: clip %s has no track_id", tostring(clip.id)))
    local track = timeline_state.get_track_by_id(clip.track_id)
    assert(track, string.format(
        "track_info_for_clip: track %s not found for clip %s",
        tostring(clip.track_id), tostring(clip.id)))
    return track.track_index, track.track_type
end

--- From candidates, pick best clip: video trumps audio, then topmost track_index.
local function pick_best(candidates)
    assert(#candidates > 0, "pick_best: candidates must be non-empty")

    local video_clips = {}
    local audio_clips = {}
    for _, clip in ipairs(candidates) do
        local _, track_type = track_info_for_clip(clip)
        if track_type == "VIDEO" then
            video_clips[#video_clips + 1] = clip
        else
            audio_clips[#audio_clips + 1] = clip
        end
    end

    local pool = #video_clips > 0 and video_clips or audio_clips

    local best = nil
    local best_index = -1
    for _, clip in ipairs(pool) do
        local idx = track_info_for_clip(clip)
        if idx > best_index then
            best = clip
            best_index = idx
        end
    end
    return best
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["MatchFrame"] = function(command)
        local target_clips, playhead = command_helper.resolve_clips_at_playhead()

        if #target_clips == 0 then
            set_last_error("MatchFrame: No clips under playhead")
            return false
        end

        local target_clip = pick_best(target_clips)

        local target_master_id = extract_master_clip_id(target_clip)
        if not target_master_id then
            set_last_error("MatchFrame: Clip is not linked to a master clip")
            return false
        end

        -- Write marks + playhead to master clip sequence (IS-a master clips).
        -- source_in/source_out are absolute TC (media_tc_origin + file offset).
        -- Masterclip playhead/marks use the same absolute TC space — TMB
        -- subtracts first_frame_tc at decode time.
        local master_seq = Sequence.load(target_master_id)
        if master_seq then
            master_seq:set_in(target_clip.source_in)
            master_seq:set_out(target_clip.source_out)
            master_seq:set_playhead(target_clip.source_in + (playhead - target_clip.timeline_start))
            master_seq:save()
        else
            -- FCP7 import doesn't create masterclip sequences (IS-a gap).
            -- Marks can't be written but focus_master_clip can still work.
            -- TODO: FCP7 import should create masterclip sequences.
            log.warn("MatchFrame: no masterclip sequence for %s — marks skipped (FCP7 import gap)",
                tostring(target_master_id))
        end

        -- Load master clip into source viewer and focus it
        local ok, err = pcall(source_viewer.load_master_clip, target_master_id)
        if not ok then
            set_last_error("MatchFrame: " .. tostring(err))
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
