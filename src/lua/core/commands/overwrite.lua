--- Overwrite command - overwrites clips at playhead position
--
-- Responsibilities:
-- - Insert video and audio clips at specified position
-- - Delete/trim any clips that would be occluded
-- - Support undo/redo with clip ID preservation
--
-- @file overwrite.lua

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

local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },
        clip_id = {},
        clip_name = {},
        dry_run = { kind = "boolean" },
        duration = {},
        duration_value = {},
        master_clip_id = {},
        media_id = { required = true },
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
        executed_mutations = {},
    },
}

local function get_timeline_state()
    local ok, mod = pcall(require, 'ui.timeline.timeline_state')
    return ok and mod or nil
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Overwrite"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing Overwrite command")
        end

        -- Resolve parameters from UI context if not provided
        local media_id = clip_edit_helper.resolve_media_id_from_ui(args.media_id, command)
        local track_id = args.track_id

        -- Resolve sequence_id
        local sequence_id = clip_edit_helper.resolve_sequence_id(args, track_id, command)
        if not sequence_id or sequence_id == "" then
            set_last_error("Overwrite: missing sequence_id (unable to resolve from track_id or timeline_state)")
            return false, "Overwrite: missing sequence_id"
        end

        -- Resolve track_id
        local track_err
        track_id, track_err = clip_edit_helper.resolve_track_id(track_id, sequence_id, command)
        if not track_id then
            set_last_error("Overwrite: " .. (track_err or "failed to resolve track"))
            return false, "Overwrite: " .. (track_err or "failed to resolve track")
        end

        -- Resolve overwrite_time from playhead
        local overwrite_time = clip_edit_helper.resolve_edit_time(args.overwrite_time, command, "overwrite_time")

        -- Get sequence FPS
        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)

        -- Load master clip if specified
        local master_clip_id = args.master_clip_id
        local master_clip = nil
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id)
            if not master_clip then
                print(string.format("WARNING: Overwrite: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
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
            local msg = "Overwrite: no media selected - select a clip in the project browser first"
            set_last_error(msg)
            return false, msg
        end
        if not track_id or track_id == "" then
            local msg = "Overwrite: no track available - sequence must have at least one video track"
            set_last_error(msg)
            return false, msg
        end

        if not project_id or project_id == "" then
            set_last_error("Overwrite: missing project_id")
            return false, "Overwrite: missing project_id"
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
            set_last_error("Overwrite: " .. timing_err)
            return false, "Overwrite: " .. timing_err
        end

        -- Get overwrite time as Rational
        local overwrite_time_rat = rational_helpers.require_rational_in_rate(overwrite_time, seq_fps_num, seq_fps_den, "overwrite_time")

        -- Validate timing
        if not overwrite_time_rat or timing.duration_rat.frames <= 0 or not timing.source_out_rat then
            local msg = string.format("Overwrite: invalid timing params (time=%s dur=%s out=%s)",
                tostring(overwrite_time_rat), tostring(timing.duration_rat), tostring(timing.source_out_rat))
            set_last_error(msg)
            return false, msg
        end

        -- Resolve clip name
        local clip_name = clip_edit_helper.resolve_clip_name(args, master_clip, media, "Overwrite Clip")

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
            assert(index == 0, "Overwrite: unexpected video track index")
            return {id = track_id}
        end

        local function insert_clip(_, payload, target_track, pos)
            local overwrite_pos = assert(pos, "Overwrite: missing overwrite position")
            local insert_track_id = assert(target_track and target_track.id, "Overwrite: missing target track id")

            -- Resolve occlusions (delete/trim overlapping clips)
            local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_occlusions(db, {
                track_id = insert_track_id,
                timeline_start = overwrite_pos,
                duration = payload.duration,
                exclude_clip_id = nil
            })
            assert(ok_occ, string.format("Overwrite: resolve_occlusions failed: %s", tostring(err_occ)))

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
                timeline_start = overwrite_pos,
                duration = payload.duration,
                source_in = payload.source_in,
                source_out = payload.source_out,
                enabled = true,
                offline = master_clip and master_clip.offline,
                fps_numerator = media_fps_num,
                fps_denominator = media_fps_den,
            }
            local clip_to_insert = Clip.create(payload.clip_name or "Overwrite Clip", payload.media_id, clip_opts)

            if payload.role == "video" then
                command:set_parameter("clip_id", clip_to_insert.id)
            end

            table.insert(planned_mutations, clip_mutator.plan_insert(clip_to_insert))

            local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
            assert(ok_apply, "Failed to apply clip_mutator actions: " .. tostring(apply_err))

            -- Record mutations for undo
            for _, mut in ipairs(planned_mutations) do
                if mut.type == "delete" then
                    command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
                elseif mut.type == "update" then
                    local updated = Clip.load_optional(mut.clip_id)
                    if updated then
                        local payload_update = {
                            clip_id = updated.id,
                            track_id = updated.track_id,
                            track_sequence_id = updated.owner_sequence_id or sequence_id,
                            start_value = updated.timeline_start and updated.timeline_start.frames,
                            duration_value = updated.duration and updated.duration.frames,
                            source_in_value = updated.source_in and updated.source_in.frames,
                            source_out_value = updated.source_out and updated.source_out.frames,
                            fps_numerator = updated.fps_numerator,
                            fps_denominator = updated.fps_denominator,
                            enabled = updated.enabled
                        }
                        command_helper.add_update_mutation(command, payload_update.track_sequence_id or sequence_id, payload_update)
                    end
                elseif mut.type == "insert" then
                    local insert_payload = command_helper.clip_insert_payload(clip_to_insert, sequence_id)
                    if insert_payload then
                        command_helper.add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
                    end
                end
                table.insert(all_executed_mutations, mut)
            end

            command:set_parameter("executed_mutations", all_executed_mutations)

            if #copied_properties > 0 then
                command_helper.delete_properties_for_clip(clip_to_insert.id)
                if not command_helper.insert_properties_for_clip(clip_to_insert.id, copied_properties) then
                    print(string.format("WARNING: Overwrite: Failed to copy properties from master clip %s", tostring(master_clip_id)))
                end
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
            insert_pos = overwrite_time_rat
        })

        -- Advance playhead to end of inserted clip (default true for UI-invoked commands)
        local advance_playhead = args.advance_playhead
        if advance_playhead == nil then
            advance_playhead = true  -- Default to advancing playhead for interactive use
        end
        local timeline_state = get_timeline_state()
        if advance_playhead and timeline_state then
            timeline_state.set_playhead_position(overwrite_time_rat + timing.duration_rat)
        end

        print(string.format("✅ Overwrote at %s (id: %s)",
            tostring(overwrite_time_rat), tostring(args.clip_id)))
        return true
    end

    command_undoers["Overwrite"] = function(command)
        local args = command:get_all_parameters()
        print("Undoing Overwrite command")
        local executed_mutations = args.executed_mutations or {}

        if not executed_mutations or #executed_mutations == 0 then
            set_last_error("UndoOverwrite: No executed mutations to undo.")
            return false
        end

        local started, begin_err = db:begin_transaction()
        if not started then
            print("ERROR: UndoOverwrite: Failed to begin transaction: " .. tostring(begin_err))
            return false
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, args.sequence_id)
        if not ok then
            db:rollback_transaction(started)
            print("ERROR: UndoOverwrite: Failed to revert mutations: " .. tostring(err))
            return false
        end

        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            return false, "Failed to commit undo transaction: " .. tostring(commit_err)
        end

        print("✅ Undo Overwrite: Reverted all changes")
        return true
    end
    command_executors["UndoOverwrite"] = command_undoers["Overwrite"]

    return {
        executor = command_executors["Overwrite"],
        undoer = command_undoers["Overwrite"],
        spec = SPEC,
    }
end

return M
