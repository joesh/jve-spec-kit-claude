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
local Sequence      = require("models.sequence")
local place_shared  = require("core.commands._place_shared")
local log           = require("core.logger").for_area("commands")

-- Plan + apply occlusion against one target track. Delegates to the
-- shared place_shared.occlude_track (used by both Overwrite and
-- AddClipsToSequence so the four-case occlusion logic lives in one place).
local function occlude_track(track_id, owner_seq, n_start, n_end)
    return place_shared.occlude_track(track_id, owner_seq, n_start, n_end)
end


function M.execute(args)
    -- timeline_start_frame omitted ⇒ resolve from sequence.playhead_position.
    -- See insert.lua for rationale (rule 2.13 — no silent default-to-0).
    if args.timeline_start_frame == nil then
        local owner = assert(Sequence.find(args.sequence_id), string.format(
            "Overwrite: sequence %s not found (cannot resolve playhead fallback)",
            tostring(args.sequence_id)))
        assert(type(owner.playhead_position) == "number", string.format(
            "Overwrite: timeline_start_frame omitted and sequence %s has no "
            .. "playhead_position to fall back on", tostring(args.sequence_id)))
        args.timeline_start_frame = owner.playhead_position
    end

    -- 015 F2: ensure identity patches exist for every source track in the
    -- nested sequence. Same rationale as Insert.execute — patches are the
    -- sole routing mechanism; pre-patch identity behavior is preserved.
    require("models.patch").ensure_identity_for_source(
        args.sequence_id, args.nested_sequence_id)

    local plan = place_shared.plan_placement(args)
    -- Carry preset_ids through redo so created_clip_ids stays stable.
    plan.preset_ids = args.created_clip_ids
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
        start_frame         = plan.start_frame,
    }
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring.
-- ---------------------------------------------------------------------------

local SPEC = {
    args = {
        sequence_id           = { required = true,  kind = "string" },
        nested_sequence_id    = { required = true,  kind = "string" },
        -- timeline_start_frame omitted ⇒ resolve from sequence.playhead_position.
        timeline_start_frame  = { kind = "number" },
        target_video_track_id = { kind = "string" },
        target_audio_track_id = { kind = "string" },
        fps_mismatch_policy   = { kind = "string" },
        clip_name             = { kind = "string" },
        advance_playhead      = { kind = "boolean" },
    },
    persisted = {
        created_clip_ids       = { kind = "table" },
        created_link_group_id  = { kind = "string" },
        occluded_capture       = { kind = "table" },
        duration_frames        = { kind = "number" },
        fps_mismatch_policy    = { kind = "string" },
        prior_playhead         = { kind = "number" },
        executed_mutations     = { kind = "table" },
    },
}

-- Flat executed_mutations list — see insert.lua for contract rationale.
-- Overwrite has no ripple, so update entries come only from trimmed
-- left/right halves of occluded clips.
local function build_executed_mutations(result)
    local muts = {}
    -- result.occluded always carries every track key; each value's
    -- deleted/trimmed/split_new_ids fields are always arrays (see
    -- occlude_track in _place_shared.lua). No fallbacks needed.
    for _, cap in pairs(result.occluded) do
        for _, prev in ipairs(cap.deleted) do
            muts[#muts + 1] = { type = "delete", clip_id = prev.id }
        end
        for _, tr in ipairs(cap.trimmed) do
            muts[#muts + 1] = { type = "update", clip_id = tr.id }
        end
        for _, new_id in ipairs(cap.split_new_ids) do
            muts[#muts + 1] = { type = "insert", clip_id = new_id }
        end
    end
    for _, cid in ipairs(result.created_clip_ids) do
        muts[#muts + 1] = { type = "insert", clip_id = cid }
    end
    return muts
end

local function build_insert_mutation_entry(clip_id)
    -- Clip.load (not load_v13_row) so the in-memory mutation carries the
    -- joined frame_rate from the nested sequence row. Consumers that
    -- read clip.frame_rate (clipboard_actions.copy_mark_range,
    -- batch_ripple_edit's fetch_base_clip) require it.
    local clip = Clip.load(clip_id)
    assert(clip, "Overwrite: could not re-read clip " .. tostring(clip_id))
    return {
        id                    = clip.id,
        owner_sequence_id     = clip.owner_sequence_id,
        track_sequence_id     = clip.owner_sequence_id,
        track_id              = clip.track_id,
        nested_sequence_id    = clip.nested_sequence_id,
        start_value           = clip.timeline_start,
        timeline_start        = clip.timeline_start,
        duration_value        = clip.duration,
        duration              = clip.duration,
        source_in             = clip.source_in,
        source_out            = clip.source_out,
        master_layer_track_id = clip.master_layer_track_id,
        fps_mismatch_policy   = clip.fps_mismatch_policy,
        frame_rate            = clip.frame_rate,
        name                  = clip.name,
        enabled               = clip.enabled,
        volume                = clip.volume,
        playhead_frame        = clip.playhead_frame,
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
        command:set_parameter("executed_mutations",    build_executed_mutations(result))

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

        -- advance_playhead: see insert.lua for the contract. Capture prior,
        -- set new, persist, emit.
        if args.advance_playhead then
            local owner = assert(Sequence.load(args.sequence_id),
                "Overwrite: sequence " .. tostring(args.sequence_id) .. " not found post-execute")
            command:set_parameter("prior_playhead", owner.playhead_position)
            local new_playhead = result.start_frame + result.duration_frames
            owner:set_playhead(new_playhead)
            assert(owner:save(), "Overwrite: sequence save failed after advance_playhead")
            Signals.emit("playhead_changed", args.sequence_id, new_playhead)
        end

        return true
    end

    command_undoers["Overwrite"] = function(command)
        local args = command:get_all_parameters()
        -- Executor sets these unconditionally; carve sub-captures always
        -- carry split_new_ids/trimmed/deleted arrays (see occlude_track).
        local created_ids = args.created_clip_ids
        local occluded    = args.occluded_capture
        -- args.created_link_group_id is preserved on the command for redo;
        -- the undoer doesn't need to read it (clip_links cascade on
        -- clip delete).

        -- Drop the new clips + any split-right-halves.
        Clip.delete_by_ids(created_ids)
        for _, cap in pairs(occluded) do
            Clip.delete_by_ids(cap.split_new_ids)
        end

        -- Restore trimmed clips to their prior bounds.
        for _, cap in pairs(occluded) do
            for _, tr in ipairs(cap.trimmed) do
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
            for _, d in ipairs(cap.deleted) do
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

        -- Emit __timeline_mutations so command_manager's post-DB hook can
        -- sync timeline_state's cache to the undo-restored DB state.
        do
            local bucket = {
                sequence_id = args.sequence_id,
                inserts = {},
                updates = {},
                deletes = {},
                bulk_shifts = {},
            }
            for _, cid in ipairs(created_ids) do
                bucket.deletes[#bucket.deletes + 1] = { clip_id = cid }
            end
            for _, cap in pairs(occluded) do
                for _, snid in ipairs(cap.split_new_ids) do
                    bucket.deletes[#bucket.deletes + 1] = { clip_id = snid }
                end
                for _, tr in ipairs(cap.trimmed) do
                    local row = Clip.load_v13_row(tr.id)
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
                            source_out          = row.source_out_frame,
                            fps_mismatch_policy = row.fps_mismatch_policy,
                            name                = row.name,
                            enabled             = row.enabled,
                            volume              = row.volume,
                            playhead_frame      = row.playhead_frame,
                        }
                    end
                end
                for _, d in ipairs(cap.deleted) do
                    local entry = build_insert_mutation_entry(d.id)
                    if entry then
                        bucket.inserts[#bucket.inserts + 1] = entry
                    end
                end
            end
            command:set_parameter("__timeline_mutations", bucket)
        end

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        -- Restore playhead if we advanced it.
        if args.advance_playhead and type(args.prior_playhead) == "number" then
            local owner = assert(Sequence.load(args.sequence_id),
                "Overwrite.undo: sequence " .. tostring(args.sequence_id) .. " not found")
            owner:set_playhead(args.prior_playhead)
            assert(owner:save(), "Overwrite.undo: sequence save failed")
            Signals.emit("playhead_changed", args.sequence_id, args.prior_playhead)
        end

        return true
    end

    return {
        executor = command_executors["Overwrite"],
        undoer   = command_undoers["Overwrite"],
        spec     = SPEC,
    }
end

return M
