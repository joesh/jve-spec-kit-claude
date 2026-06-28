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
                sequence_start = { kind = "number", default = 0 },
                duration = { kind = "number" },
                source_in = { kind = "number", default = 0 },
                source_out = { kind = "number" },
            },
        },
        copied_properties = { kind = "table" },
        name = { kind = "string" },
        new_master_id = { required = true, kind = "string" },
        project_id = { required = true, kind = "string" },
    }
}
function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local media_id = args.clip_snapshot.media_id
        local project_id = args.project_id
        local target_bin_id = args.bin_id
        local new_master_id = args.new_master_id

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
        local has_video = media:is_video()
        local has_audio = (media.audio_channels or 0) > 0  -- lint-allow: R010 media.audio_channels is schema DEFAULT 0 (nullable for video-only)

        -- Video-only media → no audio rate. Schema permits NULL on
        -- audio_sample_rate for masters specifically; pass nil through.
        local sample_rate = has_audio and media.audio_sample_rate or nil
        if has_audio then
            assert(type(sample_rate) == "number" and sample_rate > 0,
                string.format("DuplicateMasterClip: media %s has audio_channels=%d "
                    .. "but missing/invalid audio_sample_rate (rule 2.13)",
                    tostring(media_id), media.audio_channels))
        end
        local duration_samples = 0
        if has_audio and duration_frames > 0 then
            duration_samples = math.floor(
                duration_frames * sample_rate * fps_den / fps_num + 0.5)
        end

        -- Audio-only media → nil width/height (schema permits NULL on
        -- masters). For video media a positive size is required.
        local width  = has_video and media.width  or nil
        local height = has_video and media.height or nil
        if has_video then
            assert(type(width) == "number" and width > 0
                and type(height) == "number" and height > 0,
                string.format("DuplicateMasterClip: media %s is video but missing width/height",
                    tostring(media_id)))
        end

        local video_start_tc_frame = has_video and media:get_start_tc() or nil
        local audio_start_tc_samples = has_audio and media:get_audio_start_tc() or nil

        local seq = Sequence.create(clip_name, project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            width, height, {
                id                       = new_master_id,
                kind                     = "master",
                -- 018 FR-004: masters carry NULL audio_sample_rate (per-
                -- media_ref rate; a master can hold heterogeneous rates).
                audio_sample_rate        = nil,
                start_timecode_frame     = video_start_tc_frame,
                video_start_tc_frame     = video_start_tc_frame,
                audio_start_tc_samples   = audio_start_tc_samples,
            })
        assert(seq:save(), "DuplicateMasterClip: failed to save master sequence")

        -- MR placement convention (matches Sequence.ensure_master:737-815):
        --   V MR : source_in = timeline_start = video_tc (master.fps frames);
        --          source range covers [video_tc, video_tc + dur_frames).
        --   A MR : timeline_start in master.fps frames — video_tc for V+A
        --          masters (master.fps == video.fps), audio_tc for audio-
        --          only (master.fps == sample_rate). duration_frames in
        --          master.fps frames (V duration for V+A; samples for
        --          audio-only since master.fps==sr). source_in/_out stay
        --          in file-natural samples.
        -- Pre-fix DuplicateMasterClip wrote zeros for both timeline_start
        -- and source_in, and duration_samples for the A MR's
        -- duration_frames — a pre-unification leftover that broke non-
        -- zero-TC duplicates (V played from frame 0 instead of TC, audio
        -- virtual clip 1920× misplaced/sized).
        -- Mirror ensure_master:678-687: V files MUST carry a V TC origin,
        -- A files MUST carry an A TC origin. No `or 0` fallback — that
        -- would silently land the duplicate at frame 0 when the original
        -- sits at a real TC.
        if has_video then
            assert(video_start_tc_frame ~= nil, string.format(
                "DuplicateMasterClip: media %s has video but no video TC "
                .. "origin (start_tc_value missing from metadata)",
                tostring(media_id)))
        end
        if has_audio then
            assert(audio_start_tc_samples ~= nil, string.format(
                "DuplicateMasterClip: media %s has audio but no audio TC "
                .. "origin (start_tc_audio_samples missing from metadata)",
                tostring(media_id)))
        end
        local v_tc = video_start_tc_frame
        local a_tc = audio_start_tc_samples
        local a_placement_start = has_video and v_tc or a_tc
        local a_placement_dur   = has_video and duration_frames or duration_samples

        if has_video then
            local vtrack = Track.create_video("Video 1", seq.id, { index = 1 })
            assert(vtrack:save(), "DuplicateMasterClip: failed to save video track")
            MediaRef.create({
                project_id           = project_id,
                owner_sequence_id    = seq.id,
                track_id             = vtrack.id,
                media_id             = media_id,
                source_in_frame      = v_tc,
                source_out_frame     = v_tc + duration_frames,
                sequence_start_frame = v_tc,
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
                -- Embedded (in-file) audio channels: "Embedded N", matching
                -- master_builder.add_audio_streams. Synced recorder channels
                -- are nameless + derive their iXML name elsewhere.
                local atrack = Track.create_audio(
                    Track.embedded_audio_label(ch), seq.id, { index = ch })
                assert(atrack:save(), "DuplicateMasterClip: failed to save audio track")
                MediaRef.create({
                    project_id           = project_id,
                    owner_sequence_id    = seq.id,
                    track_id             = atrack.id,
                    media_id             = media_id,
                    source_in_frame      = a_tc,
                    source_out_frame     = a_tc + duration_samples,
                    sequence_start_frame = a_placement_start,
                    duration_frames      = a_placement_dur,
                    -- One clip per stream: this track reads file channel ch-1.
                    source_channel       = ch - 1,
                    audio_sample_rate    = media.audio_sample_rate,
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
        local new_master_id = args.new_master_id
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