--- Insert command (Feature 013, rewrite per T040).
--
-- Places a master (or nested) sequence as a clip reference onto a non-master
-- edit sequence's track. Writes 1 or 2 V9 clips rows (V and/or A — not
-- per-channel; channel overrides live in media_refs_channel_state and
-- clip_channel_override, resolved at playback). If 2 rows land, they share
-- a clip_links.link_group_id. fps_mismatch_policy is frozen on each row at
-- Insert time from the explicit arg / owner sequence override / project
-- default chain (data-model.md §Decisions — structural at Insert).
--
-- Collision strategy: ripple. Target tracks' clips at or past the insertion
-- frame shift forward by the new clip's owner-timebase duration. Other
-- tracks are untouched (differs from Overwrite which occludes).
--
-- Shared scaffolding lives in _place_shared.lua. This module owns only the
-- ripple-vs-occlude decision and its undo capture.
--
-- SQL isolation: all DB access goes through models.
--
-- @file insert.lua

local M = {}

local Clip          = require("models.clip")
local Sequence      = require("models.sequence")
local place_shared  = require("core.commands._place_shared")
local log           = require("core.logger").for_area("commands")

-- M.execute — pure-logic entry point. Args and return shape documented
-- alongside the orchestrator body below.
function M.execute(args)
    -- timeline_start_frame is optional at the SPEC layer because the
    -- editor's user-mode Insert is "insert at playhead." When omitted,
    -- resolve from the owner sequence's authoritative playhead_position.
    -- Loud-fail if neither is available — no silent default to 0
    -- (rule 2.13).
    if args.timeline_start_frame == nil then
        local owner = assert(Sequence.find(args.sequence_id), string.format(
            "Insert: sequence %s not found (cannot resolve playhead fallback)",
            tostring(args.sequence_id)))
        assert(type(owner.playhead_position) == "number", string.format(
            "Insert: timeline_start_frame omitted and sequence %s has no "
            .. "playhead_position to fall back on", tostring(args.sequence_id)))
        args.timeline_start_frame = owner.playhead_position
    end

    local plan = place_shared.plan_placement(args)
    -- Carry preset_ids through redo so created_clip_ids stays stable.
    plan.preset_ids = args.created_clip_ids

    -- Ripple target tracks BEFORE inserting so the new clip doesn't collide.
    local rippled = {}
    for _, track_id in pairs(plan.targets) do
        local ids = Clip.ripple_track_forward(
            track_id, plan.start_frame, plan.owner_duration)
        if #ids > 0 then
            rippled[track_id] = {
                shift = plan.owner_duration,
                from_frame = plan.start_frame,
                clip_ids = ids,
            }
        end
    end

    local written = place_shared.write_clips(plan)

    log.event("Insert: owner=%s nested=%s policy=%s duration=%d clips=%d",
        plan.owner.id, plan.nested.id, plan.policy,
        plan.owner_duration, #written.created_clip_ids)

    return {
        created_clip_ids    = written.created_clip_ids,
        video_clip_id       = written.video_clip_id,
        audio_clip_id       = written.audio_clip_id,
        link_group_id       = written.link_group_id,
        duration_frames     = plan.owner_duration,
        fps_mismatch_policy = plan.policy,
        rippled             = rippled,
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
        -- No silent default-to-0 (rule 2.13).
        timeline_start_frame  = { kind = "number" },
        target_video_track_id = { kind = "string" },
        target_audio_track_id = { kind = "string" },
        fps_mismatch_policy   = { kind = "string" },
        clip_name             = { kind = "string" },
        audio_drop_mode       = { kind = "string", one_of = { "composite", "expanded" } },
        advance_playhead      = { kind = "boolean" },
    },
    persisted = {
        created_clip_ids       = { kind = "table" },
        created_link_group_id  = { kind = "string" },
        rippled_capture        = { kind = "table" },
        duration_frames        = { kind = "number" },
        fps_mismatch_policy    = { kind = "string" },
        prior_playhead         = { kind = "number" },
    },
}

local function build_insert_mutation_entry(clip_id)
    local row = Clip.load_v13_row(clip_id)
    assert(row, "Insert: could not re-read inserted clip " .. tostring(clip_id))
    -- Carry the source-side timebase from the clip's nested sequence so
    -- timeline_state's rate field gets populated. Without this, callers
    -- that read clip.rate (batch_ripple_edit's fetch_base_clip etc.)
    -- crash with 'missing rate metadata' on freshly-inserted clips.
    local nested = Sequence.load(row.nested_sequence_id)
    local fps_num = nested and nested.frame_rate and nested.frame_rate.fps_numerator
    local fps_den = nested and nested.frame_rate and nested.frame_rate.fps_denominator
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
        fps_numerator         = fps_num,
        fps_denominator       = fps_den,
        name                  = row.name,
        enabled               = row.enabled,
        volume                = row.volume,
        playhead_frame        = row.playhead_frame,
    }
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Insert: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        local result = result_or_err

        command:set_parameter("created_clip_ids",      result.created_clip_ids)
        command:set_parameter("created_link_group_id", result.link_group_id or "")
        command:set_parameter("rippled_capture",       result.rippled)
        command:set_parameter("duration_frames",       result.duration_frames)
        command:set_parameter("fps_mismatch_policy",   result.fps_mismatch_policy)

        local bucket = {
            sequence_id = args.sequence_id,
            inserts = {},
            updates = {},
            deletes = {},
            bulk_shifts = {},
        }
        for _, cid in ipairs(result.created_clip_ids) do
            bucket.inserts[#bucket.inserts + 1] = build_insert_mutation_entry(cid)
        end
        for track_id, rip in pairs(result.rippled) do
            bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
                track_id     = track_id,
                shift_frames = rip.shift,
                start_frame  = rip.from_frame,
            }
        end
        command:set_parameter("__timeline_mutations", bucket)

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        -- advance_playhead: editor-mode side effect — after a successful
        -- placement, advance the sequence's playhead by the placed clip's
        -- owner-frame duration, persist, and emit playhead_changed.
        -- Captured to args.prior_playhead for undo restore.
        if args.advance_playhead then
            local owner = assert(Sequence.load(args.sequence_id),
                "Insert: sequence " .. tostring(args.sequence_id) .. " not found post-execute")
            command:set_parameter("prior_playhead", owner.playhead_position)
            local new_playhead = result.start_frame + result.duration_frames
            owner:set_playhead(new_playhead)
            assert(owner:save(), "Insert: sequence save failed after advance_playhead")
            Signals.emit("playhead_changed", args.sequence_id, new_playhead)
        end

        return true
    end

    command_undoers["Insert"] = function(command)
        local args = command:get_all_parameters()
        local created_ids   = args.created_clip_ids or {}
        local link_group_id = args.created_link_group_id
        local rippled       = args.rippled_capture or {}

        -- clip_links rows cascade on clip delete via ON DELETE CASCADE;
        -- link_group_id stays in undo state for redo reinstatement.
        local _unused_here = link_group_id  -- luacheck: ignore 211

        Clip.delete_by_ids(created_ids)

        for _, rip in pairs(rippled) do
            if rip.clip_ids and #rip.clip_ids > 0 then
                Clip.shift_many_by(rip.clip_ids, -rip.shift)
            end
        end

        -- Emit __timeline_mutations so command_manager's post-DB hook
        -- can sync timeline_state's cache to the undo-restored state.
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
            for track_id, rip in pairs(rippled) do
                if rip.shift and rip.shift ~= 0 then
                    bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
                        track_id     = track_id,
                        shift_frames = -rip.shift,
                        start_frame  = (rip.from_frame or 0) + rip.shift,
                    }
                end
            end
            command:set_parameter("__timeline_mutations", bucket)
        end

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        -- Restore playhead if we advanced it.
        if args.advance_playhead and type(args.prior_playhead) == "number" then
            local owner = assert(Sequence.load(args.sequence_id),
                "Insert.undo: sequence " .. tostring(args.sequence_id) .. " not found")
            owner:set_playhead(args.prior_playhead)
            assert(owner:save(), "Insert.undo: sequence save failed")
            Signals.emit("playhead_changed", args.sequence_id, args.prior_playhead)
        end

        return true
    end

    return {
        executor = command_executors["Insert"],
        undoer   = command_undoers["Insert"],
        spec     = SPEC,
    }
end

return M
