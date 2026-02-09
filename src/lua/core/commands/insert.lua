--- Insert command - thin wrapper for AddClipsToSequence(edit_type="insert")
--
-- Responsibilities:
-- - Provide backward compatibility for direct Insert command calls
-- - Gather clip info and delegate to AddClipsToSequence
--
-- Non-goals:
-- - Does not implement insertion logic (AddClipsToSequence does that)
--
-- @file insert.lua

local M = {}

local Clip = require('models.clip')
local Media = require('models.media')
local Track = require('models.track')
local rational_helpers = require('core.command_rational_helpers')
local clip_edit_helper = require('core.clip_edit_helper')
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
        -- Delegate storage to AddClipsToSequence
    },
}

local function get_timeline_state()
    local ok, mod = pcall(require, 'ui.timeline.timeline_state')
    return ok and mod or nil
end

function M.register(command_executors, command_undoers, db, set_last_error)
    local command_manager = require('core.command_manager')

    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()
        local this_func_label = "Insert"

        if args.dry_run then
            return true
        end

        logger.debug("insert", "Executing Insert command (via AddClipsToSequence)")

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

        assert(project_id and project_id ~= "", "Insert: missing project_id")
        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        -- Get media FPS
        local media_fps_num, media_fps_den = clip_edit_helper.get_media_fps(db, master_clip, media_id, seq_fps_num, seq_fps_den)

        -- Load media for duration and audio channel info
        local media = Media.load(media_id)

        -- Resolve timing parameters (all integers)
        local timing, timing_err = clip_edit_helper.resolve_timing(args, master_clip, media)
        if not timing then
            set_last_error("Insert: " .. timing_err)
            return false, "Insert: " .. timing_err
        end

        -- insert_time must be integer
        assert(insert_time == nil or type(insert_time) == "number", "Insert: insert_time must be integer")

        -- Resolve clip name
        local clip_name = clip_edit_helper.resolve_clip_name(args, master_clip, media)

        -- Determine audio channels (skip if this is a per-track call from a higher-level command)
        local audio_channels = (media and media.audio_channels) or 0

        -- Build clips for the group
        local clips = {}

        -- Video clip
        table.insert(clips, {
            role = "video",
            media_id = media_id,
            master_clip_id = master_clip_id,
            project_id = project_id,
            name = clip_name,
            source_in = timing.source_in,
            source_out = timing.source_out,
            duration = timing.duration,
            fps_numerator = media_fps_num,
            fps_denominator = media_fps_den,
            target_track_id = track_id,
            clip_id = args.clip_id,  -- Preserve clip_id if specified
        })

        -- Audio clips
        if audio_channels > 0 then
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
                    source_in = timing.source_in,
                    source_out = timing.source_out,
                    duration = timing.duration,
                    fps_numerator = media_fps_num,
                    fps_denominator = media_fps_den,
                    target_track_id = audio_track.id,
                })
            end
        end

        -- Build group
        local groups = {
            {
                clips = clips,
                duration = timing.duration,
                master_clip_id = master_clip_id,
            }
        }

        -- Advance playhead to end of inserted clip (default true for UI-invoked commands)
        local advance_playhead = args.advance_playhead
        if advance_playhead == nil then
            advance_playhead = true
        end

        -- Execute AddClipsToSequence (will be automatically grouped with parent command)
        local result, nested_cmd = command_manager.execute("AddClipsToSequence", {
            groups = groups,
            position = insert_time,
            sequence_id = sequence_id,
            project_id = project_id,
            edit_type = "insert",
            arrangement = "serial",
            advance_playhead = advance_playhead,
        })

        if not result or not result.success then
            local msg = result and result.error_message or "AddClipsToSequence failed"
            set_last_error("Insert: " .. msg)
            return false, "Insert: " .. msg
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

        logger.debug("insert", string.format("Inserted clip at frame %d", insert_time or 0))
        return true
    end

    -- Undo is handled by the nested AddClipsToSequence command via undo group
    command_undoers["Insert"] = function(command)
        return true
    end

    return {
        executor = command_executors["Insert"],
        undoer = command_undoers["Insert"],
        spec = SPEC,
    }
end

return M
