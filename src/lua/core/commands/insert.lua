--- Insert command - inserts clip at playhead, rippling downstream clips
--
-- Responsibilities:
-- - Insert video and audio clips at specified position
-- - Ripple (shift) downstream clips to make room
-- - Support undo/redo with clip ID preservation
--
-- @file insert.lua

local M = {}
local Clip = require('models.clip')
local Media = require('models.media')
local Track = require('models.track')
local Rational = require('core.rational')
local uuid = require('uuid')
local command_helper = require('core.command_helper')
local rational_helpers = require('core.command_rational_helpers')
local clip_mutator = require('core.clip_mutator')
local clip_edit_helper = require('core.clip_edit_helper')
local insert_selected_clip_into_timeline = require('core.clip_insertion')
local logger = require('core.logger')

local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },
        clip_id = {},
        clip_name = { kind = "string" },
        dry_run = { kind = "boolean" },
        duration = {},
        duration_value = {},
        insert_time = {},
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

local function get_timeline_state()
    local ok, mod = pcall(require, 'ui.timeline.timeline_state')
    return ok and mod or nil
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()
        local timeline_state = get_timeline_state()

        if not args.dry_run then
            logger.debug("insert", "Executing Insert command")
        end

        -- Resolve parameters from UI context if not provided
        local media_id = clip_edit_helper.resolve_media_id_from_ui(args.media_id, command)
        local track_id = args.track_id

        assert(media_id and media_id ~= "",
            "Insert command: media_id required but not provided and no media selected in project browser")

        -- Resolve sequence_id
        local sequence_id = clip_edit_helper.resolve_sequence_id(args, track_id, command)
        assert(sequence_id and sequence_id ~= "",
            string.format("Insert command: sequence_id required (track_id=%s)", tostring(track_id)))

        -- Resolve track_id
        local track_err
        track_id, track_err = clip_edit_helper.resolve_track_id(track_id, sequence_id, command)
        assert(track_id, string.format("Insert command: %s", track_err or "failed to resolve track"))

        -- Resolve insert_time from playhead
        local insert_time = clip_edit_helper.resolve_edit_time(args.insert_time, command, "insert_time")

        -- Get sequence FPS
        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)

        -- Load master clip if specified
        local master_clip_id = args.master_clip_id
        local master_clip = nil
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id)
            assert(master_clip, string.format(
                "Insert command: master_clip_id=%s not found in database",
                tostring(master_clip_id)
            ))
        end

        -- Get project_id
        local project_id = command.project_id or args.project_id
        if master_clip then
            project_id = project_id or master_clip.project_id
            if (not media_id or media_id == "") and master_clip.media_id then
                media_id = master_clip.media_id
            end
        end

        -- Validate required IDs
        if not media_id or media_id == "" then
            local msg = "Insert: no media selected - select a clip in the project browser first"
            set_last_error(msg)
            return false, msg
        end
        if not track_id or track_id == "" then
            local msg = "Insert: no track available - sequence must have at least one video track"
            set_last_error(msg)
            return false, msg
        end

        if not project_id or project_id == "" then
            set_last_error("Insert: missing project_id")
            return false, "Insert: missing project_id"
        end
        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        -- Get media FPS
        local media_fps_num, media_fps_den = clip_edit_helper.get_media_fps(db, master_clip, media_id, seq_fps_num, seq_fps_den)

        -- Load media for duration and audio channel info
        local media = Media.load(media_id)

        -- Resolve timing parameters
        local timing, timing_err = clip_edit_helper.resolve_timing(
            args, master_clip, media,
            seq_fps_num, seq_fps_den,
            media_fps_num, media_fps_den
        )
        if not timing then
            set_last_error("Insert: " .. timing_err)
            return false, "Insert: " .. timing_err
        end

        -- Get insert time as Rational
        local insert_time_rat = rational_helpers.require_rational_in_rate(insert_time, seq_fps_num, seq_fps_den, "insert_time")

        -- Validate timing
        if not insert_time_rat or timing.duration_rat.frames <= 0 or not timing.source_out_rat then
            local msg = string.format("Insert: invalid timing params (time=%s dur=%s out=%s)",
                tostring(insert_time_rat), tostring(timing.duration_rat), tostring(timing.source_out_rat))
            set_last_error(msg)
            return false, msg
        end

        -- Resolve clip name
        local clip_name = clip_edit_helper.resolve_clip_name(args, master_clip, media, "Inserted Clip")

        -- Get audio channel count
        local audio_channels = (media and media.audio_channels) or 0

        -- Handle copied properties from master clip
        local copied_properties = {}
        if master_clip_id and master_clip_id ~= "" then
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        -- Create selected_clip object
        local selected_clip = clip_edit_helper.create_selected_clip({
            media_id = media_id,
            master_clip_id = master_clip_id,
            project_id = project_id,
            duration_rat = timing.duration_rat,
            source_in_rat = timing.source_in_rat,
            source_out_rat = timing.source_out_rat,
            clip_name = clip_name,
            clip_id = args.clip_id,
            audio_channels = audio_channels
        })

        -- Create sequence object with track resolvers and insert callback
        local target_audio_track = clip_edit_helper.create_audio_track_resolver(sequence_id, db)

        -- Accumulate mutations across all clip insertions
        local all_executed_mutations = {}

        -- Extract clip IDs from previous execution (for redo - reuse same IDs)
        local redo_clip_ids = {}
        if args.executed_mutations then
            for _, mut in ipairs(args.executed_mutations) do
                if mut.type == "insert" and mut.clip_id then
                    table.insert(redo_clip_ids, mut.clip_id)
                end
            end
        end
        local redo_clip_index = 1

        local function target_video_track(_, index)
            assert(index == 0, "Insert: unexpected video track index")
            return {id = track_id}
        end

        local function insert_clip(_, payload, target_track, pos)
            local insert_pos = assert(pos, "Insert: missing insert position")
            local insert_track_id = assert(target_track and target_track.id, "Insert: missing target track id")

            -- Ripple downstream clips
            local ok_ripple, err_ripple, planned_mutations = clip_mutator.resolve_ripple(db, {
                track_id = insert_track_id,
                insert_time = insert_pos,
                shift_amount = payload.duration
            })
            assert(ok_ripple, string.format("Insert: resolve_ripple failed: %s", tostring(err_ripple)))

            -- Determine clip_id
            local clip_id = payload.clip_id
            if clip_id then
                if redo_clip_index <= #redo_clip_ids then
                    redo_clip_index = redo_clip_index + 1
                end
            elseif redo_clip_index <= #redo_clip_ids then
                clip_id = redo_clip_ids[redo_clip_index]
                redo_clip_index = redo_clip_index + 1
            else
                clip_id = uuid.generate()
            end

            -- Create clip
            local clip_opts = {
                id = clip_id,
                project_id = payload.project_id,
                track_id = insert_track_id,
                owner_sequence_id = sequence_id,
                parent_clip_id = payload.master_clip_id,
                source_sequence_id = master_clip and master_clip.source_sequence_id,
                timeline_start = insert_pos,
                duration = payload.duration,
                source_in = payload.source_in,
                source_out = payload.source_out,
                enabled = true,
                offline = master_clip and master_clip.offline,
                fps_numerator = media_fps_num,
                fps_denominator = media_fps_den,
            }
            local clip_to_insert = Clip.create(payload.clip_name or "Inserted Clip", payload.media_id, clip_opts)

            if payload.role == "video" then
                command:set_parameter("clip_id", clip_to_insert.id)
            end

            table.insert(planned_mutations, clip_mutator.plan_insert(clip_to_insert))

            local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
            assert(ok_apply, "Failed to apply clip_mutator actions: " .. tostring(apply_err))

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

        -- Advance playhead to end of inserted clip (default true for UI-invoked commands)
        local advance_playhead = args.advance_playhead
        if advance_playhead == nil then
            advance_playhead = true  -- Default to advancing playhead for interactive use
        end
        if advance_playhead and timeline_state then
            timeline_state.set_playhead_position(insert_time_rat + timing.duration_rat)
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
