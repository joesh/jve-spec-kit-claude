--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~239 LOC
-- Volatility: unknown
--
-- @file insert.lua
local M = {}
local Clip = require('models.clip')
local Media = require('models.media')
local Track = require('models.track')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local uuid = require("uuid")
local rational_helpers = require("core.command_rational_helpers")
local insert_selected_clip_into_timeline = require("core.clip_insertion")
local logger = require("core.logger")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end
local clip_mutator = require('core.clip_mutator')


local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },
        clip_id = {},
        clip_name = { kind = "string" },
        dry_run = { kind = "boolean" },
        duration = {},
        duration_value = {},
        insert_time = { default = 0 },
        master_clip_id = {},
        media_id = { required = true },
        project_id = { required = true },
        sequence_id = {},
        source_in = {},
        source_in_value = {},
        source_out = {},
        source_out_value = {},
        track_id = {},
    },
    persisted = {
        executed_mutations = {},
    },

}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            logger.debug("insert", "Executing Insert command")
        end

        local media_id = args.media_id
        local track_id = args.track_id

        -- If media_id not provided, gather from UI state (project browser selection)
        if not media_id or media_id == "" then
            local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
            if ui_state_ok then
                local project_browser = ui_state.get_project_browser and ui_state.get_project_browser()
                if project_browser and project_browser.get_selected_master_clip then
                    local selected_clip = project_browser.get_selected_master_clip()
                    if selected_clip and selected_clip.media_id then
                        media_id = selected_clip.media_id
                        command:set_parameter("media_id", media_id)
                    end
                end
            end

            assert(media_id and media_id ~= "",
                "Insert command: media_id required but not provided and no media selected in project browser")
        end

        -- Resolve owning sequence (timeline coordinate space).
        local sequence_id = command_helper.resolve_sequence_for_track(args.sequence_id, track_id)
        assert(sequence_id and sequence_id ~= "",
            string.format("Insert command: sequence_id required (track_id=%s)", tostring(track_id)))
        command:set_parameter("sequence_id", sequence_id)
        if not args.__snapshot_sequence_ids then
            command:set_parameter("__snapshot_sequence_ids", {sequence_id})
        end

        -- If track_id not provided, use first video track in sequence
        if not track_id or track_id == "" then
            local video_tracks = Track.find_by_sequence(sequence_id, "VIDEO")
            assert(#video_tracks > 0, string.format(
                "Insert command: no VIDEO tracks found in sequence_id=%s (sequence has no video tracks)",
                tostring(sequence_id)
            ))
            track_id = video_tracks[1].id
            command:set_parameter("track_id", track_id)
        end

        -- If insert_time not provided or 0, use playhead position from timeline state
        if (not args.insert_time or args.insert_time == 0) and timeline_state then
            local playhead_pos = timeline_state.get_playhead_position and timeline_state.get_playhead_position()
            if playhead_pos then
                command:set_parameter("insert_time", playhead_pos)
            end
        end

        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)


        local duration_raw = args.duration_value or args.duration
        local source_in_raw = args.source_in_value or args.source_in
        local source_out_raw = args.source_out_value or args.source_out
        
        local master_clip_id = args.master_clip_id

        local project_id = command.project_id or args.project_id

        local master_clip = nil
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id)
            assert(master_clip, string.format(
                "Insert command: master_clip_id=%s not found in database (no fallback - fix caller)",
                tostring(master_clip_id)
            ))
        end

        local copied_properties = {}

        -- Timeline coordinate (sequence rate).
        local insert_time_rat = rational_helpers.require_rational_in_rate(args.insert_time, seq_fps_num, seq_fps_den, "insert_time")

        -- Source coordinate + clip metadata (media/master rate).
        local media_fps_num, media_fps_den
        if master_clip then
            media_fps_num, media_fps_den = rational_helpers.require_master_clip_rate(master_clip)
        elseif media_id and media_id ~= "" then
            media_fps_num, media_fps_den = rational_helpers.require_media_rate(db, media_id)
        else
            -- Fallback when no media context exists.
            media_fps_num, media_fps_den = seq_fps_num, seq_fps_den
        end

        local source_in_rat = rational_helpers.optional_rational_in_rate(source_in_raw, media_fps_num, media_fps_den)
        local source_out_rat = rational_helpers.optional_rational_in_rate(source_out_raw, media_fps_num, media_fps_den)
        local duration_frames = nil
        do
            local duration_rat = rational_helpers.optional_rational_in_rate(duration_raw, seq_fps_num, seq_fps_den)
            if duration_rat and duration_rat.frames and duration_rat.frames > 0 then
                duration_frames = duration_rat.frames
            end
        end

        if master_clip then
            project_id = project_id or master_clip.project_id
            if (not media_id or media_id == "") and master_clip.media_id then
                media_id = master_clip.media_id
            end
            
            if not source_in_rat then
                source_in_rat = master_clip.source_in or Rational.new(0, media_fps_num, media_fps_den)
            end
            if (not duration_frames or duration_frames <= 0) and master_clip.duration and master_clip.duration.frames and master_clip.duration.frames > 0 then
                duration_frames = master_clip.duration.frames
            end
            if not source_out_rat and (not duration_frames or duration_frames <= 0) and master_clip.source_out then
                source_out_rat = master_clip.source_out
            end

            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        if not media_id or media_id == "" or not track_id or track_id == "" then
            local msg = string.format("Insert: missing required ids (media_id=%s track_id=%s)", tostring(media_id), tostring(track_id))
            set_last_error(msg)
            return false, msg
        end

        if not project_id or project_id == "" then
            local msg = "Insert: missing project_id (command.project_id/parameter/master_clip.project_id all empty)"
            set_last_error(msg)
            return false, msg
        end
        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        if not source_in_rat then
            source_in_rat = Rational.new(0, media_fps_num, media_fps_den)
        end

        -- Load media for duration and audio channel info
        local media = nil
        if media_id and media_id ~= "" then
            media = Media.load(media_id)
        end

        -- If no duration yet and we have media, get duration from it
        if (not duration_frames or duration_frames <= 0) and media then
            if media.duration and media.duration.frames and media.duration.frames > 0 then
                duration_frames = media.duration.frames
            end
        end

        if source_out_rat and (not duration_frames or duration_frames <= 0) then
            duration_frames = source_out_rat.frames - source_in_rat.frames
        end
        if not source_out_rat and duration_frames and duration_frames > 0 then
            source_out_rat = Rational.new(source_in_rat.frames + duration_frames, media_fps_num, media_fps_den)
        end
        if not duration_frames or duration_frames <= 0 then
            local msg = string.format("Insert: invalid duration_frames=%s", tostring(duration_frames))
            set_last_error(msg)
            return false, msg
        end
        local duration_rat = Rational.new(duration_frames, seq_fps_num, seq_fps_den)

        if not insert_time_rat or duration_rat.frames <= 0 or not source_out_rat then
            local msg = string.format("Insert: invalid timing params (time=%s dur=%s out=%s)",
                tostring(insert_time_rat), tostring(duration_rat), tostring(source_out_rat))
            set_last_error(msg)
            return false, msg
        end

        local clip_name = args.clip_name or (master_clip and master_clip.name) or "Inserted Clip"

        -- Determine audio channel count from media
        local audio_channels = 0
        if media and media.audio_channels then
            audio_channels = media.audio_channels
        end

        local clip_payload = {
            role = "video",
            media_id = media_id,
            master_clip_id = master_clip_id,
            project_id = project_id,
            duration = duration_rat,
            source_in = source_in_rat,
            source_out = source_out_rat,
            clip_name = clip_name,
            clip_id = args.clip_id
        }

        local selected_clip = {
            video = clip_payload
        }

        function selected_clip:has_video()
            return true
        end

        function selected_clip:has_audio()
            return audio_channels > 0
        end

        function selected_clip:audio_channel_count()
            return audio_channels
        end

        function selected_clip:audio(ch)
            assert(ch >= 0 and ch < audio_channels, "Insert: invalid audio channel index " .. tostring(ch))
            return {
                role = "audio",
                media_id = media_id,
                master_clip_id = master_clip_id,
                project_id = project_id,
                duration = duration_rat,
                source_in = source_in_rat,
                source_out = source_out_rat,
                clip_name = clip_name .. " (Audio)",
                channel = ch
            }
        end

        local function target_video_track(_, index)
            assert(index == 0, "Insert: unexpected video track index")
            return {id = track_id}
        end

        -- Get or create audio tracks for audio clip insertion
        local audio_tracks = {}
        if timeline_state and timeline_state.get_audio_tracks then
            audio_tracks = timeline_state.get_audio_tracks() or {}
        else
            -- Fallback: query database for audio tracks
            audio_tracks = Track.find_by_sequence(sequence_id, "AUDIO") or {}
        end

        local function target_audio_track(_, index)
            assert(index >= 0, "Insert: invalid audio track index " .. tostring(index))
            if index < #audio_tracks then
                return audio_tracks[index + 1]  -- Lua is 1-indexed
            end
            -- Need to create audio track - first refresh the track list from DB
            -- (handles redo case where tracks exist but weren't in our initial list)
            local fresh_tracks = Track.find_by_sequence(sequence_id, "AUDIO") or {}
            if #fresh_tracks > #audio_tracks then
                audio_tracks = fresh_tracks
                if index < #audio_tracks then
                    return audio_tracks[index + 1]
                end
            end
            -- Still need to create - find the max existing track index
            local max_index = 0
            for _, t in ipairs(audio_tracks) do
                if t.track_index and t.track_index > max_index then
                    max_index = t.track_index
                end
            end
            local new_index = max_index + 1 + (index - #audio_tracks)
            local track_name = string.format("A%d", new_index)
            local new_track = Track.create_audio(track_name, sequence_id, {index = new_index})
            assert(new_track:save(), "Insert: failed to create audio track")
            audio_tracks[#audio_tracks + 1] = new_track
            return new_track
        end

        -- Accumulate mutations across all clip insertions (video + audio)
        local all_executed_mutations = {}

        local function insert_clip(_, payload, target_track, pos)
            local insert_time = assert(pos, "Insert: missing insert position")
            local insert_track_id = assert(target_track and target_track.id, "Insert: missing target track id")
            local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_ripple(db, {
                track_id = insert_track_id,
                insert_time = insert_time,
                shift_amount = payload.duration
            })
            assert(ok_occ, string.format("Insert: resolve_ripple failed: %s", tostring(err_occ)))

            local clip_opts = {
                id = payload.clip_id or uuid.generate(),
                project_id = payload.project_id,
                track_id = insert_track_id,
                owner_sequence_id = sequence_id,
                parent_clip_id = payload.master_clip_id,
                source_sequence_id = master_clip and master_clip.source_sequence_id,
                timeline_start = insert_time,
                duration = payload.duration,
                source_in = payload.source_in,
                source_out = payload.source_out,
                enabled = true,
                offline = master_clip and master_clip.offline,
                fps_numerator = media_fps_num,
                fps_denominator = media_fps_den,
            }
            local clip_to_insert = Clip.create(payload.clip_name or "Inserted Clip", payload.media_id, clip_opts)
            -- Only set clip_id for video (primary) clip - audio clips are linked
            if payload.role == "video" then
                command:set_parameter("clip_id", clip_to_insert.id)
            end
            table.insert(planned_mutations, clip_mutator.plan_insert(clip_to_insert))

            local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
            assert(ok_apply, "Failed to apply clip_mutator actions: " .. tostring(apply_err))

            -- Accumulate mutations for undo (don't overwrite)
            for _, mut in ipairs(planned_mutations) do
                table.insert(all_executed_mutations, mut)
            end
            command:set_parameter("executed_mutations", all_executed_mutations)

            if #copied_properties > 0 then
                command_helper.delete_properties_for_clip(clip_to_insert.id)
                local props_ok = command_helper.insert_properties_for_clip(clip_to_insert.id, copied_properties)
                assert(props_ok, string.format(
                    "Insert command: failed to copy properties from master_clip_id=%s to clip_id=%s",
                    tostring(master_clip_id), tostring(clip_to_insert.id)
                ))
            end

            return {id = clip_to_insert.id, role = payload.role, time_offset = 0}
        end

        local sequence = {
            target_video_track = target_video_track,
            target_audio_track = target_audio_track,
            insert_clip = insert_clip
        }

        insert_selected_clip_into_timeline({
            selected_clip = selected_clip,
            sequence = sequence,
            insert_pos = insert_time_rat
        })


        if args.advance_playhead and timeline_state then
            timeline_state.set_playhead_position(insert_time_rat + duration_rat)
        end

        logger.debug("insert", string.format("Inserted clip at %s (id: %s)",
            tostring(insert_time_rat), tostring(args.clip_id)))
        return true
    end

    command_undoers["Insert"] = function(command)
        local args = command:get_all_parameters()
        logger.debug("insert", "Undoing Insert command")

        assert(args.executed_mutations and #args.executed_mutations > 0,
            "UndoInsert: No executed mutations to undo (corrupted command state)")

        local started, begin_err = db:begin_transaction()
        assert(started, string.format("UndoInsert: Failed to begin transaction: %s", tostring(begin_err)))

        local ok, err = command_helper.revert_mutations(db, args.executed_mutations, command, args.sequence_id)
        if not ok then
            db:rollback_transaction(started)
            assert(false, string.format("UndoInsert: Failed to revert mutations: %s", tostring(err)))
        end

        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            assert(false, string.format("UndoInsert: Failed to commit transaction: %s", tostring(commit_err)))
        end

        logger.debug("insert", "Undo Insert: Reverted all changes")
        return true
    end

    command_executors["UndoInsert"] = command_undoers["Insert"]
    command_undoers["UndoInsert"] = command_undoers["Insert"]

    return {
        executor = command_executors["Insert"],
        undoer = command_undoers["Insert"],
        spec = SPEC,
    }
end

return M
