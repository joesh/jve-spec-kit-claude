--- Overwrite command - wrapper for AddClipsToSequence(edit_type="overwrite")
--
-- Responsibilities:
-- - Load masterclip sequence and resolve stream timing
-- - Delegate to AddClipsToSequence for actual overwrite
--
-- Invariants:
-- - Requires master_clip_id (masterclip sequence ID)
-- - Timing comes from stream clips in native units (frames for video, samples for audio)
--
-- @file overwrite.lua

local M = {}

local Sequence = require('models.sequence')
local Media = require('models.media')
local rational_helpers = require('core.command_rational_helpers')
local clip_edit_helper = require('core.clip_edit_helper')
local logger = require('core.logger')

local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },
        clip_id = {},
        clip_name = {},
        dry_run = { kind = "boolean" },
        duration = {},
        duration_value = {},
        master_clip_id = {},  -- Masterclip sequence ID
        media_id = {},
        overwrite_time = {},
        project_id = { required = true },
        sequence_id = {},
        source_in = {},
        source_in_value = {},
        source_out = {},
        source_out_value = {},
        track_id = {},
    },
    persisted = {
        -- Delegate storage to AddClipsToSequence
    },
}

local function get_timeline_state()
    local ok, mod = pcall(require, 'ui.timeline.timeline_state')
    return ok and mod or nil
end

function M.register(command_executors, command_undoers, db, set_last_error)
    local command_manager = require('core.command_manager')

    command_executors["Overwrite"] = function(command)
        local args = command:get_all_parameters()
        local this_func_label = "Overwrite"

        if args.dry_run then
            return true
        end

        logger.debug("overwrite", "Executing Overwrite command (via AddClipsToSequence)")

        local track_id = args.track_id

        -- Resolve sequence_id
        local sequence_id = clip_edit_helper.resolve_sequence_id(args, track_id, command)
        assert(sequence_id and sequence_id ~= "",
            string.format("Overwrite command: sequence_id required (track_id=%s)", tostring(track_id)))

        -- Resolve track_id
        local track_err
        track_id, track_err = clip_edit_helper.resolve_track_id(track_id, sequence_id, command)
        assert(track_id, string.format("Overwrite command: %s", track_err or "failed to resolve track"))

        -- Resolve overwrite_time from playhead
        local overwrite_time = clip_edit_helper.resolve_edit_time(args.overwrite_time, command, "overwrite_time")

        -- Load masterclip sequence - REQUIRED
        local master_clip_id = args.master_clip_id
        assert(master_clip_id and master_clip_id ~= "",
            "Overwrite command: master_clip_id is required")
        local source_sequence = Sequence.load(master_clip_id)
        assert(source_sequence, string.format(
            "Overwrite command: masterclip %s not found", master_clip_id))
        assert(source_sequence:is_masterclip(), string.format(
            "Overwrite command: sequence %s is not a masterclip (kind=%s)",
            master_clip_id, tostring(source_sequence.kind)))

        -- Get project_id from masterclip sequence
        local project_id = command.project_id or args.project_id or source_sequence.project_id
        assert(project_id and project_id ~= "", "Overwrite: missing project_id")
        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        -- Get media_id from video or audio stream clip
        local video_stream = source_sequence:video_stream()
        local audio_streams = source_sequence:audio_streams()
        local media_id = (video_stream and video_stream.media_id) or (audio_streams[1] and audio_streams[1].media_id)
        assert(media_id and media_id ~= "", string.format(
            "Overwrite command: masterclip %s has no media_id in streams", master_clip_id))

        -- Load media for audio channel info
        local media = Media.load(media_id)

        -- Resolve timing from stream clips in their native units
        local timing_overrides = {
            source_in = args.source_in_value or args.source_in,
            source_out = args.source_out_value or args.source_out,
            duration = args.duration_value or args.duration,
        }

        -- Get video timing if video stream exists (may be nil for audio-only)
        local video_timing = clip_edit_helper.resolve_video_stream_timing(source_sequence, timing_overrides)

        -- Get audio timing if audio stream exists (may be nil for video-only)
        local audio_timing = clip_edit_helper.resolve_audio_stream_timing(source_sequence, timing_overrides)

        -- Must have at least one stream
        assert(video_timing or audio_timing, string.format(
            "Overwrite command: masterclip %s has no video or audio streams", master_clip_id))

        -- overwrite_time must be integer
        assert(overwrite_time == nil or type(overwrite_time) == "number", "Overwrite: overwrite_time must be integer")

        -- Resolve clip name
        local clip_name = clip_edit_helper.resolve_clip_name_for_sequence(args, source_sequence, media)

        -- Determine audio channels
        local audio_channels = (media and media.audio_channels) or 0

        -- Build clips for the group
        local clips = {}
        local group_duration

        -- Get timeline frame rate for duration conversion
        -- clip.duration must be in TIMELINE frames (sequence timebase), not source units
        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)

        -- Video clip (if video stream exists)
        if video_timing then
            -- Convert video duration (source frames) to timeline frames
            local video_fps = video_timing.fps_numerator / video_timing.fps_denominator
            local timeline_fps = seq_fps_num / seq_fps_den
            local video_duration_timeline = math.floor(video_timing.duration * timeline_fps / video_fps + 0.5)

            table.insert(clips, {
                role = "video",
                media_id = media_id,
                master_clip_id = master_clip_id,
                project_id = project_id,
                name = clip_name,
                source_in = video_timing.source_in,
                source_out = video_timing.source_out,
                duration = video_duration_timeline,  -- Timeline frames, not source frames
                fps_numerator = video_timing.fps_numerator,
                fps_denominator = video_timing.fps_denominator,
                target_track_id = track_id,
                clip_id = args.clip_id,  -- Preserve clip_id if specified
            })
            group_duration = video_duration_timeline
        end

        -- Audio clips (if audio stream exists)
        if audio_channels > 0 and audio_timing then
            -- Convert audio duration (samples) to timeline frames
            local sample_rate = audio_timing.fps_numerator
            local timeline_fps = seq_fps_num / seq_fps_den
            local audio_duration_timeline = math.floor(audio_timing.duration * timeline_fps / sample_rate + 0.5)

            local audio_track_resolver = clip_edit_helper.create_audio_track_resolver(sequence_id)
            for ch = 0, audio_channels - 1 do
                local audio_track = audio_track_resolver(nil, ch)
                table.insert(clips, {
                    role = "audio",
                    channel = ch,
                    media_id = media_id,
                    master_clip_id = master_clip_id,
                    project_id = project_id,
                    name = clip_name .. " (Audio)",
                    source_in = audio_timing.source_in,
                    source_out = audio_timing.source_out,
                    duration = audio_duration_timeline,  -- Timeline frames, not samples
                    fps_numerator = audio_timing.fps_numerator,
                    fps_denominator = audio_timing.fps_denominator,
                    target_track_id = audio_track.id,
                })
            end
            -- For audio-only, use the converted timeline duration
            if not group_duration then
                group_duration = audio_duration_timeline
            end
        end

        assert(#clips > 0, string.format(
            "Overwrite command: no clips to insert for masterclip %s", master_clip_id))

        -- Build group
        local groups = {
            {
                clips = clips,
                duration = group_duration,
                master_clip_id = master_clip_id,
            }
        }

        -- Advance playhead to end of clip (default true for UI-invoked commands)
        local advance_playhead = args.advance_playhead
        if advance_playhead == nil then
            advance_playhead = true
        end

        -- Execute AddClipsToSequence (will be automatically grouped with parent command)
        local result, nested_cmd = command_manager.execute("AddClipsToSequence", {
            groups = groups,
            position = overwrite_time,
            sequence_id = sequence_id,
            project_id = project_id,
            edit_type = "overwrite",
            arrangement = "serial",
            advance_playhead = advance_playhead,
        })

        if not result or not result.success then
            local msg = result and result.error_message or "AddClipsToSequence failed"
            set_last_error("Overwrite: " .. msg)
            return false, "Overwrite: " .. msg
        end

        -- Store clip_id and mutations for backward compatibility (tests expect these)
        if nested_cmd and nested_cmd.get_parameter then
            local created_clip_ids = nested_cmd:get_parameter("created_clip_ids")
            if created_clip_ids and #created_clip_ids > 0 then
                command:set_parameter("clip_id", created_clip_ids[1])
            end
            -- Forward executed_mutations for tests that inspect them
            local executed_mutations = nested_cmd:get_parameter("executed_mutations")
            if executed_mutations then
                command:set_parameter("executed_mutations", executed_mutations)
            end
            -- Forward __timeline_mutations for UI cache updates
            local timeline_mutations = nested_cmd:get_parameter("__timeline_mutations")
            if timeline_mutations then
                command:set_parameter("__timeline_mutations", timeline_mutations)
            end
        end

        logger.debug("overwrite", string.format("Overwrote at frame %d", overwrite_time or 0))
        return true
    end

    -- Undo is handled by the nested AddClipsToSequence command via undo group
    command_undoers["Overwrite"] = function(command)
        return true
    end

    return {
        executor = command_executors["Overwrite"],
        undoer = command_undoers["Overwrite"],
        spec = SPEC,
    }
end

return M
