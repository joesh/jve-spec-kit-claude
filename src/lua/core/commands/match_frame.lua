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
local source_viewer = require('ui.source_viewer')
local Sequence = require('models.sequence')
local command_helper = require("core.command_helper")
local media_status = require("core.media.media_status")

-- Clamp a frame into [mstart, mend), or [mstart, mend] when hi_inclusive.
local function clamp_frame(f, mstart, mend, hi_inclusive)
    if f < mstart then return mstart end
    if hi_inclusive then
        if f > mend then return mend end
    elseif f >= mend then
        return mend - 1
    end
    return f
end

-- Bring source_in/source_out/playhead inside the master sequence's valid
-- frame range. Returns the clamped triple plus a shortfall table when any
-- clamp actually moved a value; nil when the inputs already fit.
local function clamp_to_master_range(master_seq, raw_in, raw_out, raw_play)
    local dur = master_seq:content_duration()
    if dur <= 0 then
        return raw_in, raw_out, raw_play, nil
    end
    local mstart = master_seq.start_timecode_frame or 0
    local mend = mstart + dur
    local in_c   = clamp_frame(raw_in,   mstart, mend, false)
    local out_c  = clamp_frame(raw_out,  mstart, mend, true)
    local play_c = clamp_frame(raw_play, mstart, mend, false)
    if in_c == raw_in and out_c == raw_out and play_c == raw_play then
        return in_c, out_c, play_c, nil
    end
    return in_c, out_c, play_c, {
        head_short = math.max(0, mstart - raw_in),
        tail_short = math.max(0, raw_out - mend),
        master_start = mstart,
        master_end = mend,
    }
end

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

local function extract_nested_sequence_id(clip)
    if type(clip) ~= "table" then return nil end
    if clip.nested_sequence_id and clip.nested_sequence_id ~= "" then
        return clip.nested_sequence_id
    end
    return nil
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["MatchFrame"] = function(command)
        local target_clips, playhead = command_helper.resolve_clips_at_playhead()

        if #target_clips == 0 then
            set_last_error("MatchFrame: No clips under playhead")
            return false
        end

        local target_clip = command_helper.pick_best_clip(target_clips)

        local target_master_id = extract_nested_sequence_id(target_clip)
        if not target_master_id then
            set_last_error("MatchFrame: Clip has no nested sequence")
            return false
        end

        -- Offline media is fine: load the master into the source viewer
        -- regardless of disk presence. The viewer's own overlay surfaces
        -- offline state. MatchFrame's job is navigation, not playback —
        -- consistent with the importer-no-probe philosophy applied to
        -- downstream operations. Refresh status caches so the viewer's
        -- offline indicators are accurate when it loads.
        media_status.ensure_clip_status(target_clip)

-- Write marks + playhead to the master sequence. Clamp to its
        -- valid range first: a relink to a shorter candidate leaves the
        -- master covering only part of the clip's recorded source range,
        -- and Sequence:set_in / set_out / set_playhead assert when out
        -- of bounds. Clamping parks the source viewer at the coverage
        -- boundary; log.warn carries the per-frame deficit for diagnosis.
        local master_seq = Sequence.load(target_master_id)
        if master_seq then
            local raw_play = target_clip.source_in
                + (playhead - target_clip.timeline_start)
            local in_c, out_c, play_c, sf = clamp_to_master_range(
                master_seq, target_clip.source_in, target_clip.source_out, raw_play)
            if sf then
                log.warn("MatchFrame: clip extends past media coverage — "
                    .. "short %df at head, %df at tail. "
                    .. "Marks set at coverage boundary [%d, %d).",
                    sf.head_short, sf.tail_short,
                    sf.master_start, sf.master_end)
            end
            master_seq:set_in(in_c)
            master_seq:set_out(out_c)
            master_seq:set_playhead(play_c)
            master_seq:save()
        else
            -- FCP7 import doesn't create master sequences (IS-a gap).
            -- TODO: FCP7 import should create master sequences.
            log.warn("MatchFrame: no master sequence for %s — marks skipped (FCP7 import gap)",
                tostring(target_master_id))
        end

        -- No pcall: source_viewer.load_master_clip uses fail-fast asserts
        -- (rule 1.14). A missing audio bus rate, missing source monitor, or
        -- engine config error is a bug to surface — wrapping in pcall and
        -- routing through set_last_error is silent failure (rule 2.32).
        source_viewer.load_master_clip(target_master_id)

        return true
    end

    return {
        executor = command_executors["MatchFrame"],
        spec = SPEC,
    }
end

return M
