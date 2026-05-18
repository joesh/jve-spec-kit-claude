--- AddClipToTrack — place a single media clip onto a specific track (FR-021d).
--
-- Places a clip referencing the given media_id onto the specified track.
-- Finds or creates a master sequence for the media via Sequence.ensure_master,
-- then inserts a clip row on the owner sequence.
--
-- undoable = false: the clip row is cascade-deleted when the track is removed
-- (e.g., by undoing an Insert that auto-created the track). Undo of AddClipToTrack
-- itself is not needed because the track lifetime governs the clip lifetime.
--
-- @file add_clip_to_track.lua

local M = {}

local Clip     = require("models.clip")
local Media    = require("models.media")
local Project  = require("models.project")
local Sequence = require("models.sequence")
local Track    = require("models.track")
local log      = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        sequence_id          = { required = true },
        project_id           = { required = true },
        track_id             = { required = true },
        media_id             = { required = true },
        sequence_start_frame = { required = true, kind = "number" },
        duration_frames      = { required = true, kind = "number" },
        source_in_frame      = { required = true, kind = "number" },
    },
    persisted = {},
}

local function load_and_validate_track(args)
    local track = Track.load(args.track_id)
    assert(track, string.format(
        "AddClipToTrack: track '%s' not found", tostring(args.track_id)))
    assert(track.sequence_id == args.sequence_id, string.format(
        "AddClipToTrack: track '%s' belongs to sequence '%s', not '%s'",
        args.track_id, tostring(track.sequence_id), tostring(args.sequence_id)))
    return track
end

local function load_project_policy(project_id)
    local project = Project.load(project_id)
    assert(project, string.format(
        "AddClipToTrack: project '%s' not found", tostring(project_id)))
    return project.fps_mismatch_policy
end

local function place_clip(args, track, master_seq_id, media_name, fps_mismatch_policy)
    local source_out = args.source_in_frame + args.duration_frames
    -- 018 FR-013: kind-aware subframe defaults (AUDIO → 0,0 frame-aligned;
    -- VIDEO → nil,nil per INV-3).
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type(track.track_type)
    return Clip.create({
        project_id           = args.project_id,
        owner_sequence_id    = args.sequence_id,
        sequence_id          = master_seq_id,
        track_id             = args.track_id,
        name                 = media_name,
        sequence_start_frame = args.sequence_start_frame,
        duration_frames      = args.duration_frames,
        source_in_frame      = args.source_in_frame,
        source_out_frame     = source_out,
        source_in_subframe   = sub_in,
        source_out_subframe  = sub_out,
        fps_mismatch_policy  = fps_mismatch_policy,
        enabled              = true,
        volume               = 1.0,
        playhead_frame       = args.source_in_frame,
    })
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTrack"] = function(command)
        local args = command:get_all_parameters()

        local track = load_and_validate_track(args)

        local media = Media.load(args.media_id)
        assert(media, string.format(
            "AddClipToTrack: media '%s' not found", tostring(args.media_id)))

        local fps_mismatch_policy = load_project_policy(args.project_id)

        local master_seq_id = Sequence.ensure_master(args.media_id, args.project_id)
        assert(master_seq_id, string.format(
            "AddClipToTrack: ensure_master returned nil for media_id='%s'",
            tostring(args.media_id)))

        local clip_id = place_clip(args, track, master_seq_id, media.name, fps_mismatch_policy)
        log.event("AddClipToTrack: clip=%s on track=%s media=%s",
            clip_id, args.track_id, args.media_id)
        return true
    end

    return {
        executor = command_executors["AddClipToTrack"],
        spec     = SPEC,
    }
end

return M
