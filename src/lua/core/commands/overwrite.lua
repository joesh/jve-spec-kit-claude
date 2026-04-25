--- Overwrite command (Feature 013, rewrite per T041).
--
-- Same placement shape as Insert (writes 1 or 2 V9 clips rows linked by
-- clip_links; fps_mismatch_policy frozen on the row; per-medium native
-- durations) — differs only in collision strategy. Existing clips on the
-- target tracks that overlap the new clip's [start, start + duration) are
-- removed, trimmed, or split — not rippled.
--
-- Occlusion cases, for each overlapping existing clip E vs the new range
-- [n_start, n_end):
--   (a) E fully inside new range              → DELETE E
--   (b) E's tail overlaps from the right      → trim E to end at n_start
--   (c) E's head overlaps from the left       → trim E to start at n_end
--   (d) E straddles new range                 → split E at both edges
-- The source bounds shift under E's own fps_mismatch_policy, so resample
-- clips trim by the fps ratio and passthrough clips trim 1:1.
--
-- SQL isolation: all DB access goes through models.
--
-- @file overwrite.lua

local M = {}

local Clip          = require("models.clip")
local place_shared  = require("core.commands._place_shared")
local log           = require("core.logger").for_area("commands")

-- Plan + apply occlusion against one target track. Delegates to the
-- shared place_shared.occlude_track (used by both Overwrite and
-- AddClipsToSequence so the four-case occlusion logic lives in one place).
local function occlude_track(track_id, owner_seq, n_start, n_end)
    return place_shared.occlude_track(track_id, owner_seq, n_start, n_end)
end


function M.execute(args)
    local plan = place_shared.plan_placement(args)
    local n_start = plan.start_frame
    local n_end   = plan.start_frame + plan.owner_duration

    -- Occlude BEFORE inserting the new rows so their INSERT doesn't collide
    -- with the clip we're about to trim/remove.
    local occluded = {}
    for _, track_id in pairs(plan.targets) do
        occluded[track_id] = occlude_track(
            track_id, plan.owner, n_start, n_end)
    end

    local written = place_shared.write_clips(plan)

    log.event("Overwrite: owner=%s nested=%s policy=%s duration=%d clips=%d",
        plan.owner.id, plan.nested.id, plan.policy,
        plan.owner_duration, #written.created_clip_ids)

    return {
        created_clip_ids    = written.created_clip_ids,
        video_clip_id       = written.video_clip_id,
        audio_clip_id       = written.audio_clip_id,
        link_group_id       = written.link_group_id,
        duration_frames     = plan.owner_duration,
        fps_mismatch_policy = plan.policy,
        occluded            = occluded,
    }
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring.
-- ---------------------------------------------------------------------------

local SPEC = {
    args = {
        sequence_id           = { required = true },
        nested_sequence_id    = { required = true },
        timeline_start_frame  = { required = true },
        target_video_track_id = {},
        target_audio_track_id = {},
        fps_mismatch_policy   = {},
        clip_name             = {},
        -- V8 compat: accepted-but-ignored params for tests / older callers.
        advance_playhead      = {},
        source_in             = {},
        source_out            = {},
        duration              = {},
    },
    persisted = {
        created_clip_ids       = {},
        created_link_group_id  = "",
        occluded_capture       = {},
        duration_frames        = 0,
        fps_mismatch_policy    = "",
    },
}

local function build_insert_mutation_entry(clip_id)
    local row = Clip.load_v13_row(clip_id)
    assert(row, "Overwrite: could not re-read clip " .. tostring(clip_id))
    return {
        id                    = row.id,
        owner_sequence_id     = row.owner_sequence_id,
        track_sequence_id     = row.owner_sequence_id,
        track_id              = row.track_id,
        nested_sequence_id    = row.nested_sequence_id,
        start_value           = row.timeline_start_frame,
        timeline_start        = row.timeline_start_frame,
        duration_value        = row.duration_frames,
        duration              = row.duration_frames,
        source_in             = row.source_in_frame,
        source_out            = row.source_out_frame,
        master_layer_track_id = row.master_layer_track_id,
        fps_mismatch_policy   = row.fps_mismatch_policy,
        name                  = row.name,
        enabled               = row.enabled,
        volume                = row.volume,
        playhead_frame        = row.playhead_frame,
    }
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Overwrite"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Overwrite: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        local result = result_or_err

        command:set_parameter("created_clip_ids",      result.created_clip_ids)
        command:set_parameter("created_link_group_id", result.link_group_id or "")
        command:set_parameter("occluded_capture",      result.occluded)
        command:set_parameter("duration_frames",       result.duration_frames)
        command:set_parameter("fps_mismatch_policy",   result.fps_mismatch_policy)

        local bucket = {
            sequence_id = args.sequence_id,
            inserts = {},
            updates = {},
            deletes = {},
        }
        for _, cid in ipairs(result.created_clip_ids) do
            bucket.inserts[#bucket.inserts + 1] = build_insert_mutation_entry(cid)
        end
        for _, cap in pairs(result.occluded) do
            for _, prev in ipairs(cap.deleted) do
                bucket.deletes[#bucket.deletes + 1] = {
                    clip_id        = prev.id,
                    track_id       = prev.track_id,
                    timeline_start = prev.timeline_start_frame,
                    duration       = prev.duration_frames,
                }
            end
            for _, tr in ipairs(cap.trimmed) do
                local fresh = Clip.load_v13_row(tr.id)
                bucket.updates[#bucket.updates + 1] = {
                    clip_id          = tr.id,
                    start_value      = fresh.timeline_start_frame,
                    duration_value   = fresh.duration_frames,
                    source_in_value  = fresh.source_in_frame,
                    source_out_value = fresh.source_out_frame,
                }
            end
            for _, new_id in ipairs(cap.split_new_ids) do
                bucket.inserts[#bucket.inserts + 1] =
                    build_insert_mutation_entry(new_id)
            end
        end
        command:set_parameter("__timeline_mutations", bucket)

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    command_undoers["Overwrite"] = function(command)
        local args = command:get_all_parameters()
        local created_ids   = args.created_clip_ids or {}
        local link_group_id = args.created_link_group_id
        local occluded      = args.occluded_capture or {}
        local _unused_here = link_group_id  -- luacheck: ignore 211

        -- Drop the new clips + any split-right-halves.
        Clip.delete_by_ids(created_ids)
        for _, cap in pairs(occluded) do
            Clip.delete_by_ids(cap.split_new_ids or {})
        end

        -- Restore trimmed clips to their prior bounds.
        for _, cap in pairs(occluded) do
            for _, tr in ipairs(cap.trimmed or {}) do
                Clip.update_bounds(tr.id,
                    tr.prior.timeline_start_frame,
                    tr.prior.duration_frames,
                    tr.prior.source_in_frame,
                    tr.prior.source_out_frame)
            end
        end

        -- Re-insert fully-deleted clips. Uses Clip.create's V13 path with
        -- the original id so link-group / override rows referencing the
        -- clip id remain valid (but link_group on the deleted row did
        -- already cascade — re-link is a future enhancement if needed).
        for _, cap in pairs(occluded) do
            for _, d in ipairs(cap.deleted or {}) do
                Clip.create({
                    id                    = d.id,
                    project_id            = d.project_id,
                    owner_sequence_id     = d.owner_sequence_id,
                    track_id              = d.track_id,
                    nested_sequence_id    = d.nested_sequence_id,
                    name                  = d.name,
                    timeline_start_frame  = d.timeline_start_frame,
                    duration_frames       = d.duration_frames,
                    source_in_frame       = d.source_in_frame,
                    source_out_frame      = d.source_out_frame,
                    master_layer_track_id = d.master_layer_track_id,
                    fps_mismatch_policy   = d.fps_mismatch_policy,
                    enabled               = d.enabled,
                    volume                = d.volume,
                    mark_in_frame         = d.mark_in_frame,
                    mark_out_frame        = d.mark_out_frame,
                    playhead_frame        = d.playhead_frame,
                })
            end
        end

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = command_executors["Overwrite"],
        undoer   = command_undoers["Overwrite"],
        spec     = SPEC,
    }
end

return M
