--- Blade command (Feature 013, rewrite per T045a).
--
-- Cross-track razor at a single owner-timeline frame. Splits every clip
-- on `track_ids` whose timeline range strictly contains `blade_frame`
-- (boundary-touching clips are NOT split — splitting AT a boundary is a
-- no-op).
--
-- Distinct from a single-clip Split (T045) in one important way: link
-- groups are preserved across the cut. If a set of clips that was bladed
-- belonged to the SAME original link group, the resulting RIGHT halves
-- form a NEW link group together — so an A+V pair on the timeline
-- becomes two A+V pairs after the blade. The LEFT halves keep the
-- original link group rows (their clip ids are unchanged).
--
-- This command does NOT consult selection or playhead state — those live
-- in the UI layer. Callers (the keyboard binding for Cmd+B etc.) must
-- supply sequence_id, blade_frame, and the list of armed track_ids.
--
-- Refusal modes:
--   - blade_frame at a clip's exact boundary: that clip is silently
--     skipped (no-op), per the strict-inside contract of SplitClip.
--   - any per-clip SplitClip refusal raises and the partial blade unwinds
--     via SAVEPOINT.
--
-- @file blade.lua

local M = {}

local Clip      = require("models.clip")
local ClipLink  = require("models.clip_link")
local SplitClip = require("core.commands.split_clip")
local database  = require("core.database")
local log       = require("core.logger").for_area("commands")

local SAVEPOINT = "blade_atomic"

function M.execute(args)
    assert(type(args) == "table", "Blade.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Blade: sequence_id required (rule 2.29)")
    assert(type(args.blade_frame) == "number",
        "Blade: blade_frame must be integer (owner-timeline frame)")
    assert(type(args.track_ids) == "table",
        "Blade: track_ids must be a list of track ids (armed tracks)")

    -- Phase 1 (no DB writes yet): for each armed track, find the clip
    -- whose timeline strictly contains blade_frame.
    local targets = {}
    for _, track_id in ipairs(args.track_ids) do
        assert(track_id and track_id ~= "",
            "Blade: track_ids entries must be non-empty strings")
        local clip_id = Clip.find_strictly_spanning(track_id, args.blade_frame)
        if clip_id then
            targets[#targets + 1] = {
                clip_id             = clip_id,
                track_id            = track_id,
                original_link_group = ClipLink.get_link_group_id(clip_id),
            }
        end
    end

    if #targets == 0 then
        log.event("Blade: no clips intersect frame=%d on armed tracks",
            args.blade_frame)
        return { sequence_id = args.sequence_id, splits = {} }
    end

    -- Phase 2 (atomic): run SplitClip on each target. SAVEPOINT so a
    -- mid-blade SplitClip refusal unwinds the entire blade — the blade
    -- is all-or-nothing.
    assert(database.savepoint(SAVEPOINT), "Blade: savepoint failed")
    local splits = {}
    local ok, err = pcall(function()
        for _, t in ipairs(targets) do
            local r = SplitClip.execute({
                sequence_id = args.sequence_id,
                clip_id     = t.clip_id,
                split_frame = args.blade_frame,
            })
            splits[#splits + 1] = {
                clip_id             = t.clip_id,            -- left half (id unchanged)
                second_clip_id      = r.second_clip_id,     -- right half
                track_id            = t.track_id,
                original_link_group = t.original_link_group,
            }
        end

        -- Phase 3 (still inside savepoint): for each original link group
        -- that produced ≥2 right halves, link those right halves into a
        -- NEW group. Right halves of clips that weren't linked, or whose
        -- group only contributed one right half, stay unlinked.
        local right_halves_by_group = {}
        for _, s in ipairs(splits) do
            if s.original_link_group then
                local bucket = right_halves_by_group[s.original_link_group]
                if not bucket then
                    bucket = {}
                    right_halves_by_group[s.original_link_group] = bucket
                end
                bucket[#bucket + 1] = {
                    clip_id     = s.second_clip_id,
                    -- role must be unique within a group; the source clip's
                    -- track_id is unique per cut so it serves as the role.
                    role        = s.track_id,
                    time_offset = 0,
                }
            end
        end
        for _, bucket in pairs(right_halves_by_group) do
            if #bucket >= 2 then
                local new_group, link_err = ClipLink.create_link_group(bucket)
                assert(new_group, string.format(
                    "Blade: failed to create link group for right halves: %s",
                    tostring(link_err)))
            end
        end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "Blade: release savepoint failed")

    log.event("Blade: split %d clip(s) at frame=%d", #splits, args.blade_frame)
    return {
        sequence_id = args.sequence_id,
        blade_frame = args.blade_frame,
        splits      = splits,
    }
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        blade_frame = { required = true },
        track_ids   = { required = true },
    },
    persisted = {
        prior_splits = {},  -- list of {clip_id, second_clip_id, original_link_group}
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Blade"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Blade: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_splits", result_or_err.splits)

        -- Emit aggregate __timeline_mutations: each split is left UPDATE +
        -- right INSERT. Mirrors Insert's emission shape.
        do
            local bucket = {
                sequence_id = args.sequence_id,
                inserts = {},
                updates = {},
                deletes = {},
                bulk_shifts = {},
            }
            local function entry_for(cid)
                local row = Clip.load_v13_row(cid)
                if not row then return nil end
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
                    source_out            = row.source_out_frame,
                    master_layer_track_id = row.master_layer_track_id,
                    fps_mismatch_policy   = row.fps_mismatch_policy,
                    name                  = row.name,
                    enabled               = row.enabled,
                    volume                = row.volume,
                    playhead_frame        = row.playhead_frame,
                }
            end
            for _, s in ipairs(result_or_err.splits) do
                local left = entry_for(s.clip_id)
                local right = entry_for(s.second_clip_id)
                if left then bucket.updates[#bucket.updates + 1] = left end
                if right then bucket.inserts[#bucket.inserts + 1] = right end
            end
            command:set_parameter("__timeline_mutations", bucket)
        end

        return true, { splits = result_or_err.splits }
    end

    command_undoers["Blade"] = function(command)
        local args = command:get_all_parameters()
        -- Executor sets prior_splits unconditionally (always an array).
        local prior = args.prior_splits
        -- Undo in reverse order. For each split: delete the right half
        -- (cascades clip_links rows) and grow the left half back. The
        -- original link group survives untouched on the left halves.
        assert(database.savepoint(SAVEPOINT), "Undo Blade: savepoint failed")
        local ok, err = pcall(function()
            for i = #prior, 1, -1 do
                local s = prior[i]
                local left  = Clip.load_v13_row(s.clip_id)
                local right = Clip.load_v13_row(s.second_clip_id)
                assert(left and right,
                    "Undo Blade: half clip missing — was the DB mutated outside the undo group?")
                local restored_duration   = left.duration_frames + right.duration_frames
                local restored_source_out = right.source_out_frame
                Clip.delete_one(s.second_clip_id)
                Clip.update_bounds(s.clip_id,
                    left.sequence_start_frame, restored_duration,
                    left.source_in_frame, restored_source_out)
            end
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT),
            "Undo Blade: release savepoint failed")
        return true
    end

    return {
        executor = command_executors["Blade"],
        undoer   = command_undoers["Blade"],
        spec     = SPEC,
    }
end

return M
