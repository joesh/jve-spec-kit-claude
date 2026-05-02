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
local fs_utils = require("core.fs_utils")
local media_status = require("core.media.media_status")
local offline_note_mod = require("core.media.offline_note")

-- Check whether the clip's media row carries a partial_coverage
-- offline_note that points at a file actually on disk. The relinker's
-- partial-fit/clone strategy leaves the original media row's file_path
-- at the (offline) volume path even though the candidate it found is
-- right there on the local disk; the candidate path lives only in the
-- offline_note. The source viewer reads the note and surfaces a useful
-- overlay; MatchFrame must do the same lookup so it doesn't pop a
-- "missing on disk" dialog naming a path the user has visibly relinked
-- past in the same session.
local function partial_coverage_candidate_present(clip)
    local raw = clip.resolved_media and clip.resolved_media.offline_note
    if not raw then return false end
    local note = offline_note_mod.parse(raw)
    if not note or note.kind ~= "partial_coverage" then return false end
    local cand = note.candidate_path
    return cand and cand ~= "" and fs_utils.file_exists(cand)
end

local function show_offline_dialog(file_path)
    assert(qt_constants and qt_constants.DIALOG and qt_constants.DIALOG.SHOW_CONFIRM,
        "match_frame.show_offline_dialog: qt_constants.DIALOG.SHOW_CONFIRM not registered")
    qt_constants.DIALOG.SHOW_CONFIRM({
        title = "Match Frame: Media Offline",
        message = "Cannot match-frame this clip — the media file is "
            .. "missing on disk.\n\n" .. tostring(file_path),
        icon = "critical",
        confirm_text = "OK",
    })
end

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

        -- Offline-file guard: pop a dialog naming the missing path
        -- before proceeding into the source-viewer load (which would
        -- otherwise either crash decoding or show an empty viewer
        -- with no diagnostic). Skipped when a partial_coverage note
        -- already names an on-disk candidate — the source viewer's
        -- own overlay surfaces that case, and a contradictory
        -- "missing" dialog would just confuse the user.
        media_status.ensure_clip_status(target_clip)
        if target_clip.media_path and target_clip.media_path ~= ""
            and not fs_utils.file_exists(target_clip.media_path)
            and not partial_coverage_candidate_present(target_clip) then
            local missing_path = target_clip.media_path
            log.warn("MatchFrame: media file not found: %s", missing_path)
            show_offline_dialog(missing_path)
            set_last_error("MatchFrame: media file not found: " .. missing_path)
            return false
        end

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
