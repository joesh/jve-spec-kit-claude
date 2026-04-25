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

function M.execute(args)
    assert(type(args) == "table",
        "GrowMasterMedium.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local medium = args.medium
    assert(medium == "video" or medium == "audio", string.format(
        "GrowMasterMedium: medium must be 'video' or 'audio'; got %s",
        tostring(medium)))
    -- First-landing scope.
    assert(medium == "audio", string.format(
        "GrowMasterMedium: first-landing scope supports medium='audio' "
        .. "only. medium='video' (add another angle / video stream to a "
        .. "master) is a follow-up — refusing rather than half-implementing."))
    local track_spec = args.track_spec
    assert(type(track_spec) == "table",
        "GrowMasterMedium: track_spec table required")
    local media_id = track_spec.media_id
    assert(type(media_id) == "string" and media_id ~= "",
        "GrowMasterMedium: track_spec.media_id required (rule 2.13)")

    local master = Sequence.find(sequence_id)
    assert(master, string.format(
        "GrowMasterMedium: sequence %s not found", sequence_id))
    assert(master.kind == "master", string.format(
        "GrowMasterMedium: sequence %s is kind='%s'; this command is valid "
        .. "only on master sequences.",
        sequence_id, tostring(master.kind)))

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

    -- ----- (1) Add the new master track + media_ref. ----------------------

    local existing_a_tracks = Track.find_by_sequence(sequence_id, "AUDIO") or {}
    local next_index = 1
    for _, t in ipairs(existing_a_tracks) do
        if t.track_index >= next_index then next_index = t.track_index + 1 end
    end

    local new_track_id = args.new_track_id or uuid.generate()
    local newt = Track.create_audio(
        string.format("Audio %d", next_index),
        sequence_id,
        { id = new_track_id, index = next_index })
    assert(newt:save(),
        "GrowMasterMedium: failed to save new master audio track")

    -- Compute the new media_ref's range. Audio media_refs use samples
    -- as their source unit AND as their timeline_start unit (per the
    -- per-track-natural convention used by ensure_master / CT-R5).
    local new_media_ref_id = args.new_media_ref_id or uuid.generate()
    local duration_samples = media.duration   -- media's native unit
    -- For an audio media file, media.duration is in samples (the schema
    -- documents duration_frames in native units; for audio media that's
    -- samples).
    local now = os.time()
    MediaRef.create({
        id                   = new_media_ref_id,
        project_id           = master.project_id,
        owner_sequence_id    = sequence_id,
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
        sequence_id, new_track_id, media_id, sample_rate, duration_samples)

    -- ----- (2) Companion clips for every existing clip referencing master.

    local referencing = Clip.find_referencing_nested(sequence_id)
    local companions = {}
    local touched_parents = {}

    for _, c in ipairs(referencing) do
        -- Each clip's track tells us its current medium. We add a
        -- companion ONLY for V clips that lack an A companion in their
        -- link group. (Audio clips are skipped in the audio-add path.)
        local c_track = Track.load(c.track_id)
        if not c_track then
            error(string.format(
                "GrowMasterMedium: clip %s track %s not found",
                c.id, tostring(c.track_id)))
        end
        if c_track.track_type == "VIDEO" then
            local lg = ClipLink.get_link_group_id(c.id)
            local already_has_audio = nil
            if lg then
                already_has_audio = ClipLink.find_in_link_group_on_medium
                    and ClipLink.find_in_link_group_on_medium(lg,
                        c.owner_sequence_id, "AUDIO")
            end
            if not already_has_audio then
                -- Find the parent's matching A track (first A track in
                -- the parent sequence, first-landing).
                local parent_a_tracks = Track.find_by_sequence(
                    c.owner_sequence_id, "AUDIO") or {}
                assert(#parent_a_tracks > 0, string.format(
                    "GrowMasterMedium: parent sequence %s has no A track "
                    .. "to host the companion for clip %s. Auto-creating "
                    .. "parent tracks is deferred — refusing rather than "
                    .. "expanding silently.",
                    c.owner_sequence_id, c.id))
                local dst_a_track_id = parent_a_tracks[1].id

                -- Companion clip's source range in samples.
                local dur_samples = audio_samples_for_video_duration(
                    c.duration_frames,
                    master.fps_numerator, master.fps_denominator,
                    sample_rate)
                local companion_id = uuid.generate()
                Clip.create({
                    id                    = companion_id,
                    project_id            = c.project_id,
                    owner_sequence_id     = c.owner_sequence_id,
                    track_id              = dst_a_track_id,
                    nested_sequence_id    = sequence_id,
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

                -- Link the pair.
                local final_lg
                if lg then
                    -- Existing link group — append the companion.
                    ClipLink.link_two_clips(c.id, companion_id)
                    final_lg = lg
                else
                    -- Create a new link group with both clips.
                    final_lg = ClipLink.create_link_group({
                        { clip_id = c.id,           role = "video", time_offset = 0 },
                        { clip_id = companion_id,   role = "audio", time_offset = 0 },
                    })
                    assert(final_lg and final_lg ~= "",
                        "GrowMasterMedium: clip_link.create_link_group "
                        .. "returned empty id")
                end

                companions[#companions + 1] = {
                    parent_clip_id      = c.id,
                    companion_clip_id   = companion_id,
                    link_group_id       = final_lg,
                    track_id            = dst_a_track_id,
                    owner_sequence_id   = c.owner_sequence_id,
                    pre_existing_lg     = lg ~= nil,
                }
                touched_parents[c.owner_sequence_id] = true
            end
        end
    end

    log.event("GrowMasterMedium: created %d companion clip(s)", #companions)

    -- ----- (3) Signals. ---------------------------------------------------

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)
    for parent_id, _ in pairs(touched_parents) do
        Signals.emit("sequence_content_changed", parent_id)
    end

    return {
        sequence_id        = sequence_id,
        new_track_id       = new_track_id,
        new_media_ref_id   = new_media_ref_id,
        companions         = companions,
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
        new_track_id     = "",
        new_media_ref_id = "",
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
