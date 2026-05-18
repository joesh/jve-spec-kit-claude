--- SplitClip command (Feature 013, rewrite per T045).
--
-- Divides one clip at a chosen owner-timeline frame into two adjacent
-- clips that together cover the same owner range. Per commands.md §Split:
--
--   Left half:  sequence_start unchanged;
--               duration = split_offset (owner frames);
--               source_in  unchanged;
--               source_out = source_in + source_offset.
--   Right half: sequence_start = orig_ts + split_offset;
--               duration = orig_dur - split_offset;
--               source_in  = orig_source_in + source_offset;
--               source_out unchanged.
--
-- split_offset = split_frame - original.sequence_start (owner frames).
-- source_offset = owner_delta_to_source(clip.fps_mismatch_policy, split_offset,
--                                      owner.fps, nested.fps).
--
-- Both halves preserve master_layer_track_id, fps_mismatch_policy, and all
-- clip_channel_override rows from the original — the editor's interpretive
-- intent survives a cut.
--
-- This command splits ONE clip. The interactive "Split" wrapper routes
-- playhead-at-armed-tracks across multiple SplitClip calls and reassembles
-- new link groups for the second halves — see T045a (blade.lua) for the
-- cross-track razor. link_group relinking is NOT this command's concern.
--
-- Refuses: split_frame at or outside [sequence_start, sequence_start+duration).
-- Refusal is loud; DB unchanged.
--
-- SQL isolation: all DB access via models.
--
-- @file split_clip.lua

local M = {}

local Clip     = require("models.clip")
local Sequence = require("models.sequence")
local database = require("core.database")
local Signals  = require("core.signals")
local uuid     = require("uuid")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "split_clip_atomic"

-- Build a timeline_state mutation entry from a V13 row.
-- Provides both direct field names (for inserts/normalize_clip_integers)
-- and _value variants (for clip_state.apply_mutations update checks).
local function mutation_entry(row)
    return {
        id                    = row.id,
        owner_sequence_id     = row.owner_sequence_id,
        track_sequence_id     = row.owner_sequence_id,
        track_id              = row.track_id,
        sequence_id    = row.sequence_id,
        start_value           = row.sequence_start_frame,
        sequence_start        = row.sequence_start_frame,
        duration_value        = row.duration_frames,
        duration              = row.duration_frames,
        source_in             = row.source_in_frame,
        source_in_value       = row.source_in_frame,
        source_out            = row.source_out_frame,
        source_out_value      = row.source_out_frame,
        master_layer_track_id = row.master_layer_track_id,
        fps_mismatch_policy   = row.fps_mismatch_policy,
        name                  = row.name,
        enabled               = row.enabled,
        volume                = row.volume,
        playhead_frame        = row.playhead_frame,
    }
end

function M.execute(args)
    assert(type(args) == "table", "SplitClip.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "SplitClip: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "SplitClip: clip_id required")
    assert(type(args.split_frame) == "number",
        "SplitClip: split_frame must be integer (owner-timeline frame)")

    local clip = Clip.load_v13_row(args.clip_id)
    assert(clip, string.format("SplitClip: clip %s not found", args.clip_id))
    assert(clip.owner_sequence_id == args.sequence_id, string.format(
        "SplitClip: clip %s owner=%s != sequence_id=%s",
        args.clip_id, clip.owner_sequence_id, args.sequence_id))

    local split_frame = args.split_frame
    local clip_end    = clip.sequence_start_frame + clip.duration_frames
    assert(split_frame > clip.sequence_start_frame and split_frame < clip_end,
        string.format(
            "SplitClip: split_frame=%d must be strictly inside clip [%d, %d)",
            split_frame, clip.sequence_start_frame, clip_end))

    local owner  = Sequence.find(args.sequence_id)
    local nested = Sequence.find(clip.sequence_id)
    assert(owner and nested, "SplitClip: owner or nested sequence not found")

    local split_offset  = split_frame - clip.sequence_start_frame
    local source_offset = Clip.owner_delta_to_source(
        clip.fps_mismatch_policy, split_offset,
        owner.fps_numerator,  owner.fps_denominator,
        nested.fps_numerator, nested.fps_denominator)

    local left_new_duration   = split_offset
    local left_new_source_out = clip.source_in_frame + source_offset

    local right_id           = args.second_clip_id or uuid.generate()
    -- right_half_offset: optional caller-supplied displacement of the right
    -- half's sequence_start away from split_frame. Used by BatchRippleEdit's
    -- cut-mode ripple to place the right half at its post-ripple position
    -- in one shot (so BRE doesn't have to bulk-shift it afterwards, which
    -- would entangle BRE's planned_mutations with SplitClip's own undo).
    -- Default 0 = right half lives exactly at split_frame.
    local right_half_offset  = args.right_half_offset or 0
    assert(type(right_half_offset) == "number" and right_half_offset >= 0,
        string.format("SplitClip: right_half_offset must be a non-negative integer; got %s",
            tostring(right_half_offset)))
    local right_timeline     = split_frame + right_half_offset
    local right_duration     = clip.duration_frames - split_offset
    local right_source_in    = clip.source_in_frame + source_offset
    local right_source_out   = clip.source_out_frame

    -- Atomic: shrink left first (frees [split_frame, clip_end) on the track),
    -- then create the right half into that freed range. SAVEPOINT unwinds
    -- either error before any row commits.
    assert(database.savepoint(SAVEPOINT), "SplitClip: savepoint failed")
    local ok, err = pcall(function()
        Clip.update_bounds(args.clip_id,
            clip.sequence_start_frame, left_new_duration,
            clip.source_in_frame, left_new_source_out)

        -- 018 FR-023 / NSF: split must preserve sub-frame precision through
        -- the split point. owner_delta_to_source returns frames-only today,
        -- so a clip whose source range is already sub-frame-aligned cannot
        -- be split correctly — refuse loudly until Phase 3.6 lands the
        -- (frame, subframe) carry math. Frame-aligned clips (subframe==0)
        -- pass through unchanged.
        -- Canonical states per INV-3: VIDEO has subframe=NULL, AUDIO has
        -- subframe∈[0, ticks_per_frame). Anything else (AUDIO with
        -- subframe>0) refuses until Phase 3.6.
        local sub_in_ok  = clip.source_in_subframe  == nil or clip.source_in_subframe  == 0
        local sub_out_ok = clip.source_out_subframe == nil or clip.source_out_subframe == 0
        assert(sub_in_ok and sub_out_ok, string.format(
            "SplitClip: clip %s has non-zero subframe "
            .. "(in=%s out=%s) — sample-precise split deferred to Phase 3.6; "
            .. "refuse rather than corrupt audio at the cut point",
            tostring(args.clip_id),
            tostring(clip.source_in_subframe),
            tostring(clip.source_out_subframe)))
        local right_source_in_sub  = clip.source_in_subframe
        local right_source_out_sub = clip.source_out_subframe
        Clip._create_v13_row({
            id                    = right_id,
            project_id            = clip.project_id,
            owner_sequence_id     = clip.owner_sequence_id,
            track_id               = clip.track_id,
            sequence_id           = clip.sequence_id,
            name                  = clip.name,
            sequence_start_frame  = right_timeline,
            duration_frames       = right_duration,
            source_in_frame       = right_source_in,
            source_out_frame      = right_source_out,
            source_in_subframe    = right_source_in_sub,
            source_out_subframe   = right_source_out_sub,
            master_layer_track_id = clip.master_layer_track_id,
            fps_mismatch_policy   = clip.fps_mismatch_policy,
            enabled               = clip.enabled,
            volume                = clip.volume,
            mark_in_frame         = clip.mark_in_frame,
            mark_out_frame        = clip.mark_out_frame,
            playhead_frame        = clip.playhead_frame,
        })

        Clip.copy_channel_overrides(args.clip_id, right_id)
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "SplitClip: release savepoint failed")

    log.event("SplitClip clip=%s split_frame=%d split_offset=%d source_offset=%d second=%s",
        args.clip_id, split_frame, split_offset, source_offset, right_id)

    return {
        clip_id         = args.clip_id,
        second_clip_id  = right_id,
        split_frame     = split_frame,
        split_offset    = split_offset,
        source_offset   = source_offset,
        prior = {
            sequence_start_frame = clip.sequence_start_frame,
            duration_frames      = clip.duration_frames,
            source_in_frame      = clip.source_in_frame,
            source_out_frame     = clip.source_out_frame,
        },
    }
end

local SPEC = {
    args = {
        sequence_id    = { required = true },
        clip_id        = { required = true },
        split_frame    = { required = true },
        second_clip_id    = {},  -- caller-supplied id (optional); else uuid
        right_half_offset = {},  -- caller-supplied displacement (optional); else 0
    },
    persisted = {
        prior_state    = {},
        second_clip_id = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SplitClip"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SplitClip: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_state", result_or_err.prior)
        command:set_parameter("second_clip_id", result_or_err.second_clip_id)

        local left  = Clip.load_v13_row(args.clip_id)
        local right = Clip.load_v13_row(result_or_err.second_clip_id)
        assert(left,  string.format("SplitClip executor: left half %s missing after create", args.clip_id))
        assert(right, string.format("SplitClip executor: right half %s missing after create", result_or_err.second_clip_id))

        -- Hydrate the media chain leaf (resolved_media + media_path) so the
        -- new right-half row carries the same waveform/peak/offline keys as
        -- the source clip. Without this the timeline renderer reaches for
        -- clip.resolved_media.id when fetching peaks, finds nil, and the
        -- right half renders as a clip with no waveform. Both halves share
        -- one media chain — load once from the left half.
        local hydrated_left = Clip.load(args.clip_id)
        assert(hydrated_left, string.format(
            "SplitClip executor: chain-resolved left half %s missing after create",
            args.clip_id))
        local resolved_media = hydrated_left.resolved_media
        local media_path     = hydrated_left.media_path
        local function entry_with_media(row)
            local e = mutation_entry(row)
            e.resolved_media = resolved_media
            e.media_path     = media_path
            return e
        end

        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts     = { entry_with_media(right) },
            deletes     = {},
            updates     = { entry_with_media(left) },
        })
        Signals.emit("sequence_content_changed", args.sequence_id)
        return { success = true, result_data = result_or_err }
    end

    command_undoers["SplitClip"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_state
        local second = args.second_clip_id
        assert(prior, "Undo SplitClip: prior_state missing")
        assert(second, "Undo SplitClip: second_clip_id missing")

        -- Order matters for the video-overlap trigger: delete the right
        -- half first (frees the range), then grow the left half back.
        assert(database.savepoint(SAVEPOINT), "Undo SplitClip: savepoint failed")
        local ok, err = pcall(function()
            Clip.delete_one(second)
            Clip.update_bounds(args.clip_id,
                prior.sequence_start_frame, prior.duration_frames,
                prior.source_in_frame, prior.source_out_frame)
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT),
            "Undo SplitClip: release savepoint failed")

        local row = Clip.load_v13_row(args.clip_id)
        assert(row, string.format("Undo SplitClip: left half %s missing after restore", args.clip_id))
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts     = {},
            updates     = { mutation_entry(row) },
            deletes     = { { clip_id = second } },
            bulk_shifts = {},
        })
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = command_executors["SplitClip"],
        undoer   = command_undoers["SplitClip"],
        spec     = SPEC,
    }
end

return M
