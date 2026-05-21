--- OverwriteTrimEdge — peer of RippleTrimEdge. Mutates ONE clip row's
--- source range. Growth into occupied space ABSORBS the neighbor clips
--- in the path (the "overwrite" semantics — same primitive that Insert /
--- Overwrite / Paste use to carve space on a track). Shrinking leaves a
--- gap; downstream is never rippled. Per spec 019 FR-014, FR-015, FR-015b.
---
--- Right-edge trim:
---   source_out_frame += delta
---   duration_frames += delta
---   sequence_start_frame unchanged
---   downstream eaten by ClipMutator.resolve_occlusions when growing.
---
--- Left-edge trim:
---   source_in_frame += delta
---   duration_frames -= delta
---   sequence_start_frame += delta  (the placement shifts to absorb the trim)
---   upstream eaten by ClipMutator.resolve_occlusions when growing.
---
--- Asserts on every precondition violation (FR-015): missing clip,
--- edge ∉ {"left","right"}, delta_frames == 0, resulting range out of
--- the clip's source-sequence content extent. No silent clamps.
---
--- Own undo entry — the planned mutations (focus update + neighbor
--- absorption) are stored on the command and reverted via
--- command_helper.revert_mutations, the same shape Paste / LiftRange /
--- ExtractRange use.
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
        -- Mutation plan (focus update + absorbed neighbors) captured at
        -- execute time so the undoer can revert via revert_mutations.
        _executed_mutations = {},
    },
}

--- Compute the four new columns from the edge + delta. The Clip model
--- (see `models/clip.lua` build_clip_from_load_row) exposes the columns
--- WITHOUT the `_frame` suffix; the DB column names retain it.
---
--- Direction-aware (forward clip: source_in < source_out; reverse clip:
--- source_in > source_out). Source-bound arithmetic
--- (`source_in + delta`, `source_out + delta`) is direction-agnostic —
--- delta is in source frames either way. Duration and sequence_start
--- deltas use a `sign` derived from clip direction so reverse clips
--- behave correctly (extending source_in higher GROWS the clip).
--- Duration delegates to `Clip.compute_trim_duration` for canonical
--- duration math; sequence_start picks up the same sign here.
local function compute_trim(clip, edge, delta)
    local Clip = require("models.clip")
    local new_duration = Clip.compute_trim_duration(clip, edge, delta)
    local sign = (clip.source_out > clip.source_in) and 1 or -1
    if edge == "right" then
        return {
            source_in_frame      = clip.source_in,
            source_out_frame     = clip.source_out + delta,
            duration_frames      = new_duration,
            sequence_start_frame = clip.sequence_start,  -- right edge: head pinned
        }
    end
    -- edge == "left" — validated by caller. Tail pinned: head moves by
    -- the timeline-frame equivalent of delta, with direction sign applied.
    return {
        source_in_frame      = clip.source_in + delta,
        source_out_frame     = clip.source_out,
        duration_frames      = new_duration,
        sequence_start_frame = clip.sequence_start + sign * delta,
    }
end

--- Report planner mutations to the timeline_mutations bucket via the
--- canonical helper, then emit sequence_content_changed so the UI
--- refreshes off the same signal.
local function report_mutations(command, sequence_id, mutations)
    require("core.command_helper").report_planner_mutations(
        command, sequence_id, mutations)
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

function M.register(executors, undoers, db, _set_last_error)
    executors["OverwriteTrimEdge"] = function(command)
        local args = command:get_all_parameters()
        local Clip          = require("models.clip")
        local clip_mutator  = require("core.clip_mutator")
        local command_helper = require("core.command_helper")
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

        -- Carve space for the new clip span via the canonical occlusion
        -- resolver — the same primitive Insert / Overwrite / Paste use.
        -- Neighbors fully covered by the new span are deleted; clipped
        -- ones are trimmed at head or tail. The focus clip is excluded
        -- via exclude_clip_id; resolve_occlusions evaluates other clips
        -- on the same track against the NEW span [start, start+duration).
        local ok, err, neighbor_mutations = clip_mutator.resolve_occlusions(db, {
            track_id         = clip.track_id,
            sequence_start   = new_vals.sequence_start_frame,
            duration         = new_vals.duration_frames,
            exclude_clip_id  = clip.id,
        })
        assert(ok, string.format(
            "OverwriteTrimEdge: resolve_occlusions failed for clip %s on track %s: %s",
            tostring(clip.id), tostring(clip.track_id), tostring(err)))

        -- plan_update for the focus clip itself. The mutator expects the
        -- model-field shape (no `_frame` suffix); apply_update_revert
        -- additionally requires `frame_rate` + `volume` on `previous` (see
        -- require_clip_frame_rate). Pass the loaded clip through as the
        -- `original` snapshot — it already carries every column read by
        -- the revert path — and clone it with the four mutated fields
        -- overridden for the post-trim `row`.
        local original_row = clip
        local new_row = {}
        for k, v in pairs(clip) do new_row[k] = v end
        new_row.sequence_start = new_vals.sequence_start_frame
        new_row.duration       = new_vals.duration_frames
        new_row.source_in      = new_vals.source_in_frame
        new_row.source_out     = new_vals.source_out_frame

        local all_mutations = {}
        for _, m in ipairs(neighbor_mutations) do
            all_mutations[#all_mutations + 1] = m
        end
        all_mutations[#all_mutations + 1] = clip_mutator.plan_update(new_row, original_row)

        local ok_apply, apply_err = command_helper.apply_mutations(db, all_mutations)
        assert(ok_apply, string.format(
            "OverwriteTrimEdge: apply_mutations failed for clip %s: %s",
            tostring(clip.id), tostring(apply_err)))

        -- Persist the executed plan so the undoer can revert via the same
        -- canonical helper (revert_mutations) — mirrors Paste / LiftRange.
        command:set_parameter("_executed_mutations", all_mutations)
        report_mutations(command, args.sequence_id, all_mutations)
        log.event("OverwriteTrimEdge: clip=%s edge=%s delta=%d (mutations=%d)",
            args.clip_id, args.edge, args.delta_frames, #all_mutations)
        return { success = true }
    end

    undoers["OverwriteTrimEdge"] = function(command)
        local args = command:get_all_parameters()
        local command_helper = require("core.command_helper")
        local executed = assert(args._executed_mutations, string.format(
            "OverwriteTrimEdge.undo: _executed_mutations missing — executor "
            .. "must have stored the plan before returning success (clip=%s)",
            tostring(args.clip_id)))
        local ok, err = command_helper.revert_mutations(
            db, executed, command, args.sequence_id)
        assert(ok, string.format(
            "OverwriteTrimEdge.undo: revert_mutations failed: %s", tostring(err)))
        require("core.signals").emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = executors["OverwriteTrimEdge"],
        undoer   = undoers["OverwriteTrimEdge"],
        spec     = SPEC,
    }
end

return M
