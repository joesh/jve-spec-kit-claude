--- OverwriteTrimEdge — peer of RippleTrimEdge. Mutates ONE clip row's
--- source range without propagating the duration delta to downstream
--- clips. Per spec 019 FR-014, FR-015, FR-015b.
---
--- Right-edge trim:
---   source_out_frame += delta
---   duration_frames += delta
---   sequence_start_frame unchanged
---   downstream stays put → gap if shrinking, overlap-attempt if growing
---
--- Left-edge trim:
---   source_in_frame += delta
---   duration_frames -= delta
---   sequence_start_frame += delta  (the placement shifts to absorb the trim)
---   downstream stays put
---
--- Asserts on every precondition violation (FR-015): missing clip,
--- edge ∉ {"left","right"}, delta_frames == 0, resulting range out of
--- the clip's source-sequence content extent. No silent clamps.
---
--- Own undo entry capturing the four pre-mutation columns
--- (source_in/out_frame, duration_frames, sequence_start_frame).
---
--- @file overwrite_trim_edge.lua

local M = {}

local SPEC = {
    args = {
        clip_id      = { required = true, kind = "string" },
        edge         = { required = true, kind = "string" },  -- "left" or "right"
        delta_frames = { required = true, kind = "number" },
        sequence_id  = { required = true, kind = "string" },
        project_id   = { required = true, kind = "string" },
    },
    persisted = {
        _old_source_in      = {},
        _old_source_out     = {},
        _old_duration       = {},
        _old_sequence_start = {},
    },
}

--- Compute the four new columns from the edge + delta. The Clip model
--- (see `models/clip.lua` build_clip_from_load_row) exposes the columns
--- WITHOUT the `_frame` suffix; the DB column names retain it. This
--- function reads from the model fields and returns the DB-column-named
--- payload Clip.update_bounds expects.
local function compute_trim(clip, edge, delta)
    if edge == "right" then
        return {
            source_in_frame      = clip.source_in,
            source_out_frame     = clip.source_out + delta,
            duration_frames      = clip.duration + delta,
            sequence_start_frame = clip.sequence_start,
        }
    end
    -- edge == "left" — validated by caller
    return {
        source_in_frame      = clip.source_in + delta,
        source_out_frame     = clip.source_out,
        duration_frames      = clip.duration - delta,
        sequence_start_frame = clip.sequence_start + delta,
    }
end

--- Build the __timeline_mutations bucket for this command's single-row
--- update. Used by both the executor (after the mutation lands) and the
--- undoer (after restoring the prior state) — same payload, same shape.
local function single_row_update_bucket(sequence_id, clip_id)
    return {
        sequence_id = sequence_id,
        inserts     = {},
        updates     = { clip_id },
        deletes     = {},
        bulk_shifts = {},
    }
end

--- Report a single-row clip mutation to the __timeline_mutations bucket
--- and emit sequence_content_changed. Both executor and undoer use the
--- exact same pair, so factor it out (DRY).
local function report_single_row_mutation(command, sequence_id, clip_id)
    command:set_parameter("__timeline_mutations",
        single_row_update_bucket(sequence_id, clip_id))
    require("core.signals").emit("sequence_content_changed", sequence_id)
end

--- Assert the new source range lies inside the source-sequence's content
--- extent. Per FR-015: no silent clamp.
local function assert_in_content_extent(clip_id, sequence_id, new_in, new_out)
    assert(new_in >= 0, string.format(
        "OverwriteTrimEdge: new source_in (%d) must be >= 0 for clip %s",
        new_in, clip_id))
    assert(new_out > new_in, string.format(
        "OverwriteTrimEdge: new source range must be non-empty for clip %s "
        .. "(new_in=%d, new_out=%d)", clip_id, new_in, new_out))
    -- Upper-bound check against the source sequence's media coverage.
    -- assert_within_master_coverage is the existing helper used by Slip/Roll
    -- to enforce the same invariant on master-kind sources.
    local Clip = require("models.clip")
    Clip.assert_within_master_coverage(sequence_id, new_out,
        string.format("OverwriteTrimEdge[%s]", clip_id))
end

function M.register(executors, undoers, _db, _set_last_error)
    executors["OverwriteTrimEdge"] = function(command)
        local args = command:get_all_parameters()
        local Clip = require("models.clip")
        local log  = require("core.logger").for_area("commands")

        assert(args.edge == "left" or args.edge == "right", string.format(
            "OverwriteTrimEdge: edge must be 'left' or 'right'; got %q",
            tostring(args.edge)))
        assert(args.delta_frames ~= 0,
            "OverwriteTrimEdge: delta_frames must be non-zero")

        local clip = Clip.load(args.clip_id)
        assert(clip, string.format(
            "OverwriteTrimEdge: clip not found: %s", tostring(args.clip_id)))

        local new_vals = compute_trim(clip, args.edge, args.delta_frames)
        assert_in_content_extent(args.clip_id, clip.sequence_id,
            new_vals.source_in_frame, new_vals.source_out_frame)

        -- Capture pre-mutation state on the command for the undoer. The
        -- Clip model exposes columns without the `_frame` suffix; the
        -- underlying DB columns retain it. See compute_trim header.
        command:set_parameter("_old_source_in",      clip.source_in)
        command:set_parameter("_old_source_out",     clip.source_out)
        command:set_parameter("_old_duration",       clip.duration)
        command:set_parameter("_old_sequence_start", clip.sequence_start)

        Clip.update_bounds(args.clip_id,
            new_vals.sequence_start_frame,
            new_vals.duration_frames,
            new_vals.source_in_frame,
            new_vals.source_out_frame)

        report_single_row_mutation(command, args.sequence_id, args.clip_id)
        log.event("OverwriteTrimEdge: clip=%s edge=%s delta=%d",
            args.clip_id, args.edge, args.delta_frames)
        return { success = true }
    end

    undoers["OverwriteTrimEdge"] = function(command)
        local args = command:get_all_parameters()
        require("models.clip").update_bounds(args.clip_id,
            args._old_sequence_start,
            args._old_duration,
            args._old_source_in,
            args._old_source_out)
        report_single_row_mutation(command, args.sequence_id, args.clip_id)
        return true
    end

    return {
        executor = executors["OverwriteTrimEdge"],
        undoer   = undoers["OverwriteTrimEdge"],
        spec     = SPEC,
    }
end

return M
