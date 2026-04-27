--- SplitClip command (Feature 013, rewrite per T045).
--
-- Divides one clip at a chosen owner-timeline frame into two adjacent
-- clips that together cover the same owner range. Per commands.md §Split:
--
--   Left half:  timeline_start unchanged;
--               duration = split_offset (owner frames);
--               source_in  unchanged;
--               source_out = source_in + source_offset.
--   Right half: timeline_start = orig_ts + split_offset;
--               duration = orig_dur - split_offset;
--               source_in  = orig_source_in + source_offset;
--               source_out unchanged.
--
-- split_offset = split_frame - original.timeline_start (owner frames).
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
-- Refuses: split_frame at or outside [timeline_start, timeline_start+duration).
-- Refusal is loud; DB unchanged.
--
-- SQL isolation: all DB access via models.
--
-- @file split_clip.lua

local M = {}

local Clip     = require("models.clip")
local Sequence = require("models.sequence")
local database = require("core.database")
local uuid     = require("uuid")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "split_clip_atomic"

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
    local clip_end    = clip.timeline_start_frame + clip.duration_frames
    assert(split_frame > clip.timeline_start_frame and split_frame < clip_end,
        string.format(
            "SplitClip: split_frame=%d must be strictly inside clip [%d, %d)",
            split_frame, clip.timeline_start_frame, clip_end))

    local owner  = Sequence.find(args.sequence_id)
    local nested = Sequence.find(clip.nested_sequence_id)
    assert(owner and nested, "SplitClip: owner or nested sequence not found")

    local split_offset  = split_frame - clip.timeline_start_frame
    local source_offset = Clip.owner_delta_to_source(
        clip.fps_mismatch_policy, split_offset,
        owner.fps_numerator,  owner.fps_denominator,
        nested.fps_numerator, nested.fps_denominator)

    local left_new_duration   = split_offset
    local left_new_source_out = clip.source_in_frame + source_offset

    local right_id           = args.second_clip_id or uuid.generate()
    local right_timeline     = split_frame
    local right_duration     = clip.duration_frames - split_offset
    local right_source_in    = clip.source_in_frame + source_offset
    local right_source_out   = clip.source_out_frame

    -- Atomic: shrink left first (frees [split_frame, clip_end) on the track),
    -- then create the right half into that freed range. SAVEPOINT unwinds
    -- either error before any row commits.
    assert(database.savepoint(SAVEPOINT), "SplitClip: savepoint failed")
    local ok, err = pcall(function()
        Clip.update_bounds(args.clip_id,
            clip.timeline_start_frame, left_new_duration,
            clip.source_in_frame, left_new_source_out)

        Clip._create_v13_row({
            id                    = right_id,
            project_id            = clip.project_id,
            owner_sequence_id     = clip.owner_sequence_id,
            track_id              = clip.track_id,
            nested_sequence_id    = clip.nested_sequence_id,
            name                  = clip.name,
            timeline_start_frame  = right_timeline,
            duration_frames       = right_duration,
            source_in_frame       = right_source_in,
            source_out_frame      = right_source_out,
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
            timeline_start_frame = clip.timeline_start_frame,
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
        second_clip_id = {},  -- caller-supplied id (optional); else uuid
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
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts = { {
                clip_id              = right.id,
                track_id             = right.track_id,
                timeline_start_value = right.timeline_start_frame,
                duration_value       = right.duration_frames,
                source_in_value      = right.source_in_frame,
                source_out_value     = right.source_out_frame,
            } },
            deletes = {},
            updates = { {
                clip_id          = args.clip_id,
                start_value      = left.timeline_start_frame,
                duration_value   = left.duration_frames,
                source_in_value  = left.source_in_frame,
                source_out_value = left.source_out_frame,
            } },
        })
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true, { second_clip_id = result_or_err.second_clip_id }
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
                prior.timeline_start_frame, prior.duration_frames,
                prior.source_in_frame, prior.source_out_frame)
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT),
            "Undo SplitClip: release savepoint failed")

        -- Emit __timeline_mutations on undo so timeline_state cache stays
        -- in sync (delete the right half, restore the left half's bounds).
        do
            local row = Clip.load_v13_row(args.clip_id)
            local bucket = {
                sequence_id = args.sequence_id,
                inserts = {},
                updates = {},
                deletes = { { clip_id = second } },
                bulk_shifts = {},
            }
            if row then
                bucket.updates[#bucket.updates + 1] = {
                    id                  = row.id,
                    owner_sequence_id   = row.owner_sequence_id,
                    track_sequence_id   = row.owner_sequence_id,
                    track_id            = row.track_id,
                    nested_sequence_id  = row.nested_sequence_id,
                    start_value         = row.timeline_start_frame,
                    timeline_start      = row.timeline_start_frame,
                    duration_value      = row.duration_frames,
                    duration            = row.duration_frames,
                    source_in           = row.source_in_frame,
                    source_out           = row.source_out_frame,
                    fps_mismatch_policy = row.fps_mismatch_policy,
                    name                = row.name,
                    enabled             = row.enabled,
                    volume              = row.volume,
                    playhead_frame      = row.playhead_frame,
                }
            end
            command:set_parameter("__timeline_mutations", bucket)
        end

        local Signals = require("core.signals")
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
