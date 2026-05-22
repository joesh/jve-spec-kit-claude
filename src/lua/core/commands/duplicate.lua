--- Duplicate command (Feature 013, T047).
--
-- Creates a new clips row that mirrors an existing clip, shifted by
-- delta_frames on the owner timeline and optionally onto a different
-- track in the same owner sequence.
--
-- Per commands.md §Duplicate, the duplicate carries:
--   - the original's source window (source_in_frame, source_out_frame)
--   - the original's duration_frames (no policy conversion — the
--     window already lives in the nested timebase, identically valid
--     on both rows)
--   - master_layer_track_id, fps_mismatch_policy
--   - enabled, volume
--   - all clip_channel_override rows
-- and shifts:
--   - sequence_start_frame += delta_frames
-- onto target_track_id (must be a track in the same owner sequence).
--
-- The duplicate gets a fresh uuid; original is untouched.
--
-- Refuses: any constraint violation (e.g., target_track_id absent or in
-- a different sequence; delta=0 onto the same track which would overlap).
-- INSERT failures unwind via SAVEPOINT — DB unchanged on refusal.
--
-- This command does NOT add the duplicate to the original's link group.
-- Link-group propagation across multi-clip Duplicate (block duplicate of
-- A+V pairs) lives with the higher-level "DuplicateClips" workflow,
-- analogous to how Blade handles link groups for Split.
--
-- @file duplicate.lua

local M = {}

local Clip     = require("models.clip")
local database = require("core.database")
local uuid     = require("uuid")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "duplicate_atomic"

function M.execute(args)
    assert(type(args) == "table", "Duplicate.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Duplicate: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "Duplicate: clip_id required")
    assert(args.target_track_id and args.target_track_id ~= "",
        "Duplicate: target_track_id required")
    assert(type(args.delta_frames) == "number",
        "Duplicate: delta_frames must be integer")

    local clip = Clip.load_v13_row(args.clip_id)
    assert(clip, string.format("Duplicate: clip %s not found", args.clip_id))
    assert(clip.owner_sequence_id == args.sequence_id, string.format(
        "Duplicate: clip %s owner=%s != sequence_id=%s",
        args.clip_id, clip.owner_sequence_id, args.sequence_id))

    local new_sequence_start = clip.sequence_start_frame + args.delta_frames
    assert(new_sequence_start >= 0, string.format(
        "Duplicate: new sequence_start_frame=%d < 0 (delta=%d, was=%d)",
        new_sequence_start, args.delta_frames, clip.sequence_start_frame))

    local new_id = args.new_clip_id or uuid.generate()

    -- Atomic: insert new row, then copy overrides. Either failure unwinds
    -- (the schema's video-overlap trigger raises before write on collision).
    assert(database.savepoint(SAVEPOINT), "Duplicate: savepoint failed")
    local ok, err = pcall(function()
        Clip._create_v13_row({
            id                    = new_id,
            project_id            = clip.project_id,
            owner_sequence_id     = clip.owner_sequence_id,
            track_id              = args.target_track_id,
            sequence_id    = clip.sequence_id,
            name                  = clip.name,
            sequence_start_frame  = new_sequence_start,
            duration_frames       = clip.duration_frames,
            source_in_frame       = clip.source_in_frame,
            source_out_frame      = clip.source_out_frame,
            master_layer_track_id = clip.master_layer_track_id,
            fps_mismatch_policy   = clip.fps_mismatch_policy,
            enabled               = clip.enabled,
            volume                = clip.volume,
            mark_in_frame         = clip.mark_in_frame,
            mark_out_frame        = clip.mark_out_frame,
            playhead_frame        = clip.playhead_frame,
        })
        Clip.copy_channel_overrides(args.clip_id, new_id)
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "Duplicate: release savepoint failed")

    log.event("Duplicate clip=%s -> %s delta=%d target_track=%s",
        args.clip_id, new_id, args.delta_frames, args.target_track_id)

    return {
        clip_id      = args.clip_id,
        new_clip_id  = new_id,
        delta_frames = args.delta_frames,
    }
end

local SPEC = {
    args = {
        sequence_id     = { required = true },
        clip_id         = { required = true },
        target_track_id = { required = true },
        delta_frames    = { required = true },
        new_clip_id     = {},  -- caller-supplied uuid (optional)
    },
    persisted = {
        new_clip_id = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Duplicate"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Duplicate: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("new_clip_id", result_or_err.new_clip_id)
        local new = Clip.load_v13_row(result_or_err.new_clip_id)
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts = { {
                clip_id              = new.id,
                track_id             = new.track_id,
                sequence_start_value = new.sequence_start_frame,
                duration_value       = new.duration_frames,
                source_in_value      = new.source_in_frame,
                source_out_value     = new.source_out_frame,
            } },
            deletes = {}, updates = {},
        })
        return true, { new_clip_id = result_or_err.new_clip_id }
    end

    command_undoers["Duplicate"] = function(command)
        local args = command:get_all_parameters()
        local new_id = args.new_clip_id
        assert(new_id and new_id ~= "",
            "Undo Duplicate: new_clip_id missing")
        -- DELETE FROM clips cascades clip_channel_override and clip_links.
        Clip.delete_one(new_id)
        return true
    end

    return {
        executor = command_executors["Duplicate"],
        undoer   = command_undoers["Duplicate"],
        spec     = SPEC,
    }
end

return M
