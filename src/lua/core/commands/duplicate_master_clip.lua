local M = {}
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        bin_id = { kind = "string", empty_as_nil = true },
        clip_snapshot = {
            required = true,
            kind = "table",
            fields = {
                media_id = { required = true, kind = "string" },
                fps_numerator = { required = true, kind = "number" },
                fps_denominator = { required = true, kind = "number" },
                timeline_start = { kind = "number", default = 0 },
                duration = { kind = "number" },
                source_in = { kind = "number", default = 0 },
                source_out = { kind = "number" },
            },
        },
        copied_properties = { kind = "table" },
        name = { kind = "string" },
        new_clip_id = { required = true, kind = "string" },
        project_id = { required = true, kind = "string" },
    }
}
function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local media_id = args.clip_snapshot.media_id
        local project_id = args.project_id
        local target_bin_id = args.bin_id
        local new_master_id = args.new_clip_id  -- arg name kept for menu compatibility

        local clip_name = args.name or args.clip_snapshot.name or "Master Clip Copy"

        -- V13: a "duplicated master clip" is a fresh master sequence row
        -- pointing at the same media. Reuse Sequence.ensure_master logic
        -- but force a unique sequence id (so the original and the copy
        -- coexist) — there's no built-in 'duplicate' helper, so build the
        -- master inline mirroring ensure_master's structure.
        local Sequence = require("models.sequence")
        local Track    = require("models.track")
        local MediaRef = require("models.media_ref")
        local Media    = require("models.media")

        local media = Media.load(media_id)
        assert(media, string.format(
            "DuplicateMasterClip: Media %s not found", tostring(media_id)))

        local fps_num = media.frame_rate.fps_numerator
        local fps_den = media.frame_rate.fps_denominator
        local duration_frames = media.duration
        local has_video = media.width > 0
        local has_audio = (media.audio_channels or 0) > 0

        local sample_rate = has_audio and media.audio_sample_rate or 48000
        local duration_samples = 0
        if has_audio and duration_frames > 0 then
            duration_samples = math.floor(
                duration_frames * sample_rate * fps_den / fps_num + 0.5)
        end

        local width  = has_video and media.width  or 1920
        local height = has_video and media.height or 1080

        local video_start_tc_frame = has_video and media:get_start_tc() or nil
        local audio_start_tc_samples = has_audio and media:get_audio_start_tc() or nil

        local seq = Sequence.create(clip_name, project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            width, height, {
                id                       = new_master_id,
                kind                     = "master",
                audio_rate               = sample_rate,
                start_timecode_frame     = video_start_tc_frame or 0,
                playhead_frame           = video_start_tc_frame or 0,
                video_start_tc_frame     = video_start_tc_frame,
                audio_start_tc_samples   = audio_start_tc_samples,
            })
        assert(seq:save(), "DuplicateMasterClip: failed to save master sequence")

        if has_video then
            local vtrack = Track.create_video("Video 1", seq.id, { index = 1 })
            assert(vtrack:save(), "DuplicateMasterClip: failed to save video track")
            MediaRef.create({
                project_id           = project_id,
                owner_sequence_id    = seq.id,
                track_id             = vtrack.id,
                media_id             = media_id,
                source_in_frame      = 0,
                source_out_frame     = duration_frames,
                timeline_start_frame = 0,
                duration_frames      = duration_frames,
                enabled              = true,
                volume               = 1.0,
                playhead_frame       = 0,
                created_at           = os.time(),
                modified_at          = os.time(),
            })
            Sequence.update(seq.id, { default_video_layer_track_id = vtrack.id })
        end

        if has_audio then
            for ch = 1, media.audio_channels do
                local atrack = Track.create_audio(
                    string.format("Audio %d", ch), seq.id, { index = ch })
                assert(atrack:save(), "DuplicateMasterClip: failed to save audio track")
                MediaRef.create({
                    project_id           = project_id,
                    owner_sequence_id    = seq.id,
                    track_id             = atrack.id,
                    media_id             = media_id,
                    source_in_frame      = 0,
                    source_out_frame     = duration_samples,
                    timeline_start_frame = 0,
                    duration_frames      = duration_samples,
                    enabled              = true,
                    volume               = 1.0,
                    playhead_frame       = 0,
                    created_at           = os.time(),
                    modified_at          = os.time(),
                })
            end
        end

        if type(args.copied_properties) == "table" and #args.copied_properties > 0 then
            command_helper.delete_properties_for_clip(new_master_id)
            command_helper.insert_properties_for_clip(new_master_id, args.copied_properties)
        end

        if target_bin_id then
            local tag_service = require("core.tag_service")
            tag_service.add_to_bin(project_id, { new_master_id }, target_bin_id, "master_clip")
        end

        return true
    end

    command_undoers["DuplicateMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local new_master_id = args.new_clip_id
        local Sequence = require("models.sequence")

        -- Tear down properties first (no FK cascade), then the master
        -- sequence row (CASCADE drops media_refs, tracks, and any
        -- nested clips referencing this id — there shouldn't be any
        -- on a fresh duplicate, but the cascade covers the case).
        command_helper.delete_properties_for_clip(new_master_id)
        local seq = Sequence.load(new_master_id)
        if seq then
            Sequence.delete_one(new_master_id)
        end

        return true
    end

    return {
        executor = command_executors["DuplicateMasterClip"],
        undoer = command_undoers["DuplicateMasterClip"],
        spec = SPEC,
    }
end

return M