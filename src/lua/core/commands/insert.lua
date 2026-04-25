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
local place_shared  = require("core.commands._place_shared")
local log           = require("core.logger").for_area("commands")

-- M.execute — pure-logic entry point. Args and return shape documented
-- alongside the orchestrator body below.
function M.execute(args)
    local plan = place_shared.plan_placement(args)

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
        audio_drop_mode       = {},   -- 'composite' (default) or 'expanded'
    },
    persisted = {
        created_clip_ids       = {},
        created_link_group_id  = "",
        rippled_capture        = {},
        duration_frames        = 0,
        fps_mismatch_policy    = "",
    },
}

local function build_insert_mutation_entry(clip_id)
    local row = Clip.load_v13_row(clip_id)
    assert(row, "Insert: could not re-read inserted clip " .. tostring(clip_id))
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

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = command_executors["Insert"],
        undoer   = command_undoers["Insert"],
        spec     = SPEC,
    }
end

return M
