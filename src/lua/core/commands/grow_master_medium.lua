--- GrowMasterMedium command (Feature 013, T064a).
---
--- Per FR-007 + Acceptance Scenario 7 / commands.md §GrowMasterMedium:
---   Args: { sequence_id, medium ∈ {'video','audio'}, track_spec }
---     sequence_id MUST reference a kind='master' sequence (rule 2.29).
---     track_spec.media_id is required (the media file the new track's
---     media_ref points at).
---
--- Mutation:
---   1. INSERT a new track on the master + a media_ref pointing at
---      track_spec.media_id covering the file's full duration.
---   2. For every clips row that already references this master AND
---      lacks a companion in its link group on the new medium: INSERT
---      a companion clip on the appropriate track of the parent's
---      sequence, mirroring timeline_start/duration, link the pair via
---      clip_links (creating a link group if neither side had one).
---   3. Emit sequence_content_changed on the master AND on every
---      parent sequence touched.
---
--- First-landing scope:
---   * medium='audio' only (the dominant case: sync audio to a video-
---     only master). Adding video to audio-only is a follow-up.
---   * Parent sequences must have at least one A track for the new
---     medium. Auto-creating parent tracks is deferred.
---
--- Undo capture: full before-state — new track id, new media_ref id,
--- companion clip ids, link-group additions/creations.
---
--- @file grow_master_medium.lua

local M = {}

local Clip      = require("models.clip")
local ClipLink  = require("models.clip_link")
local Media     = require("models.media")
local MediaRef  = require("models.media_ref")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local uuid      = require("uuid")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "GrowMasterMedium: '%s' is required (rule 2.29)", name))
    return v
end

-- For the audio-add case: source range in samples = duration_samples.
-- The parent's existing video clip has duration_frames in master's
-- video timebase; the companion A clip's source range covers samples
-- 0..(duration_frames * audio_rate / fps).
local function audio_samples_for_video_duration(duration_frames,
                                                fps_num, fps_den, sample_rate)
    return math.floor(duration_frames * sample_rate * fps_den / fps_num + 0.5)
end

-- Conversely for the video-add case: video frames covered by an audio
-- clip's duration. (Not used in first-landing audio-only path; placeholder
-- for symmetry when medium='video' lands.)
local function video_frames_for_audio_duration(duration_samples,
                                               fps_num, fps_den, sample_rate)
    return math.floor(duration_samples * fps_num / (sample_rate * fps_den) + 0.5)
end

-- Validate args + first-landing scope (medium='audio' only). Returns
-- sequence_id, media_id, track_spec.
local function validate_grow_args(args)
    assert(type(args) == "table",
        "GrowMasterMedium.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local medium = args.medium
    assert(medium == "video" or medium == "audio", string.format(
        "GrowMasterMedium: medium must be 'video' or 'audio'; got %s",
        tostring(medium)))
    assert(medium == "audio",
        "GrowMasterMedium: first-landing scope supports medium='audio' "
        .. "only. medium='video' (add another angle / video stream to a "
        .. "master) is a follow-up — refusing rather than half-implementing.")
    local track_spec = args.track_spec
    assert(type(track_spec) == "table",
        "GrowMasterMedium: track_spec table required")
    local media_id = track_spec.media_id
    assert(type(media_id) == "string" and media_id ~= "",
        "GrowMasterMedium: track_spec.media_id required (rule 2.13)")
    return sequence_id, media_id, track_spec
end

-- Load + validate the master sequence and the media row. Returns master,
-- media, sample_rate.
local function load_master_and_media(sequence_id, media_id, track_spec)
    local master = Sequence.find(sequence_id)
    assert(master, string.format(
        "GrowMasterMedium: sequence %s not found", sequence_id))
    assert(master.kind == "master", string.format(
        "GrowMasterMedium: sequence %s is kind='%s'; this command is valid "
        .. "only on master sequences.", sequence_id, tostring(master.kind)))
    local media = Media.load(media_id)
    assert(media, string.format(
        "GrowMasterMedium: media %s not found", media_id))
    local sample_rate = track_spec.sample_rate or media.audio_sample_rate
    assert(sample_rate and sample_rate > 0, string.format(
        "GrowMasterMedium: sample_rate required (track_spec.sample_rate "
        .. "or media.audio_sample_rate); media=%s", media_id))
    assert(media.audio_channels and media.audio_channels > 0, string.format(
        "GrowMasterMedium: media %s has no audio (audio_channels=%s); "
        .. "cannot add to master as audio source.",
        media_id, tostring(media.audio_channels)))
    return master, media, sample_rate
end

-- Append a new audio track to the master + a media_ref covering the
-- file's full duration. Returns new_track_id, new_media_ref_id.
local function add_master_audio_stream(master, media_id, media, sample_rate, opts)
    local existing = Track.find_by_sequence(master.id, "AUDIO") or {}
    local next_index = 1
    for _, t in ipairs(existing) do
        if t.track_index >= next_index then next_index = t.track_index + 1 end
    end
    local new_track_id = opts.new_track_id or uuid.generate()
    local newt = Track.create_audio(string.format("Audio %d", next_index),
        master.id, { id = new_track_id, index = next_index })
    assert(newt:save(),
        "GrowMasterMedium: failed to save new master audio track")

    local new_media_ref_id = opts.new_media_ref_id or uuid.generate()
    local now = os.time()
    -- For audio media, media.duration is in samples (native unit).
    local duration_samples = media.duration
    MediaRef.create({
        id                   = new_media_ref_id,
        project_id           = master.project_id,
        owner_sequence_id    = master.id,
        track_id             = new_track_id,
        media_id             = media_id,
        source_in_frame      = 0,
        source_out_frame     = duration_samples,
        timeline_start_frame = 0,
        duration_frames      = duration_samples,
        enabled              = true,
        volume               = 1.0,
        playhead_frame       = 0,
        created_at           = now,
        modified_at          = now,
    })
    log.event("GrowMasterMedium: master=%s gained A track=%s "
        .. "(media=%s sample_rate=%d duration_samples=%d)",
        master.id, new_track_id, media_id, sample_rate, duration_samples)
    return new_track_id, new_media_ref_id
end

-- For one V clip referencing the grown master, build an audio-companion
-- clip on the parent's first A track + link them. Returns the companion
-- record, or nil when the clip already has an audio peer in its link
-- group (skip case).
local function build_companion_for_video_clip(c, master, sample_rate)
    local lg = ClipLink.get_link_group_id(c.id)
    if lg and ClipLink.find_in_link_group_on_medium and
        ClipLink.find_in_link_group_on_medium(lg, c.owner_sequence_id, "AUDIO")
    then
        return nil
    end
    local parent_a_tracks = Track.find_by_sequence(c.owner_sequence_id, "AUDIO") or {}
    assert(#parent_a_tracks > 0, string.format(
        "GrowMasterMedium: parent sequence %s has no A track to host the "
        .. "companion for clip %s. Auto-creating parent tracks is deferred "
        .. "— refusing rather than expanding silently.",
        c.owner_sequence_id, c.id))
    local dst_a_track_id = parent_a_tracks[1].id
    local dur_samples = audio_samples_for_video_duration(
        c.duration_frames,
        master.fps_numerator, master.fps_denominator, sample_rate)
    local companion_id = uuid.generate()
    Clip.create({
        id                    = companion_id,
        project_id            = c.project_id,
        owner_sequence_id     = c.owner_sequence_id,
        track_id              = dst_a_track_id,
        nested_sequence_id    = master.id,
        name                  = (c.name or "Clip") .. " (audio)",
        timeline_start_frame  = c.timeline_start_frame,
        duration_frames       = c.duration_frames,
        source_in_frame       = 0,
        source_out_frame      = dur_samples,
        master_layer_track_id = nil,
        fps_mismatch_policy   = c.fps_mismatch_policy,
        enabled               = true,
        volume                = 1.0,
        playhead_frame        = 0,
    })

    local final_lg
    if lg then
        ClipLink.link_two_clips(c.id, companion_id)
        final_lg = lg
    else
        final_lg = ClipLink.create_link_group({
            { clip_id = c.id,         role = "video", time_offset = 0 },
            { clip_id = companion_id, role = "audio", time_offset = 0 },
        })
        assert(final_lg and final_lg ~= "",
            "GrowMasterMedium: clip_link.create_link_group returned empty id")
    end
    return {
        parent_clip_id    = c.id,
        companion_clip_id = companion_id,
        link_group_id     = final_lg,
        track_id          = dst_a_track_id,
        owner_sequence_id = c.owner_sequence_id,
        pre_existing_lg   = lg ~= nil,
    }
end

-- Walk every clip referencing this master. Returns companions[] and
-- touched_parents{} (sequences that got a new companion).
local function build_all_companions(master, sample_rate)
    local companions, touched = {}, {}
    for _, c in ipairs(Clip.find_referencing_nested(master.id)) do
        local c_track = Track.load(c.track_id)
        assert(c_track, string.format(
            "GrowMasterMedium: clip %s track %s not found",
            c.id, tostring(c.track_id)))
        if c_track.track_type == "VIDEO" then
            local rec = build_companion_for_video_clip(c, master, sample_rate)
            if rec then
                companions[#companions + 1] = rec
                touched[c.owner_sequence_id] = true
            end
        end
    end
    return companions, touched
end

function M.execute(args)
    local sequence_id, media_id, track_spec = validate_grow_args(args)
    local master, media, sample_rate =
        load_master_and_media(sequence_id, media_id, track_spec)

    local new_track_id, new_media_ref_id = add_master_audio_stream(
        master, media_id, media, sample_rate,
        { new_track_id = args.new_track_id,
          new_media_ref_id = args.new_media_ref_id })

    local companions, touched_parents = build_all_companions(master, sample_rate)
    log.event("GrowMasterMedium: created %d companion clip(s)", #companions)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)
    for parent_id, _ in pairs(touched_parents) do
        Signals.emit("sequence_content_changed", parent_id)
    end

    return {
        sequence_id      = sequence_id,
        new_track_id     = new_track_id,
        new_media_ref_id = new_media_ref_id,
        companions       = companions,
    }
end

function M.undo(_capture)
    error("GrowMasterMedium.undo: not yet implemented (forward-only landing "
        .. "for first-landing scope; undo is a follow-up).")
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        medium      = { required = true },
        track_spec  = { required = true },
    },
    persisted = {
        new_track_id     = { kind = "string" },
        new_media_ref_id = { kind = "string" },
        companions       = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["GrowMasterMedium"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("GrowMasterMedium: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("new_track_id",     cap.new_track_id)
        command:set_parameter("new_media_ref_id", cap.new_media_ref_id)
        command:set_parameter("companions",       cap.companions)
        return true
    end

    command_undoers["GrowMasterMedium"] = function(_command)
        error("GrowMasterMedium undo: pending follow-up.")
    end

    -- Suppress unused-warnings for symmetric helpers retained for the
    -- video-add follow-up (T060a-vid).
    local _ = video_frames_for_audio_duration

    return {
        executor = command_executors["GrowMasterMedium"],
        undoer   = command_undoers["GrowMasterMedium"],
        spec     = SPEC,
    }
end

return M
