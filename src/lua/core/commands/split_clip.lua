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
-- Size: ~183 LOC
-- Volatility: unknown
--
-- @file split_clip.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local logger = require("core.logger")


local SPEC = {
    args = {
        clip_id = { required = true },
        dry_run = { kind = "boolean" },
        second_clip_id = {},  -- Set by executor
        sequence_id = { required = true },
        split_time = {},
        split_value = {},
        track_id = {},
    },
    persisted = {
        original_duration = {},  -- Set by executor
        original_source_in = {},  -- Set by executor
        original_source_out = {},  -- Set by executor
        original_timeline_start = {},  -- Set by executor
        project_id = { required = true },
    },

}

function M.register(command_executors, command_undoers, db, set_last_error)
    local function to_rational(val, context_clip)
        if type(val) == "table" and val.frames then return val end
        local rate = context_clip and context_clip.rate
        if not rate or not rate.fps_numerator or not rate.fps_denominator then
            error("SplitClip: missing frame rate for Rational conversion", 2)
        end
        if val == nil then
            error("SplitClip: missing Rational value for conversion", 2)
        end
        return Rational.new(val, rate.fps_numerator, rate.fps_denominator)
    end

    command_executors["SplitClip"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing SplitClip command")
        end

        local clip_id = args.clip_id


        if not args.dry_run then
            print(string.format("  clip_id: %s", tostring(clip_id)))
            print(string.format("  split_value: %s", tostring(args.split_value)))
        end

        local original_clip = Clip.load(clip_id)
        if not original_clip or original_clip.id == "" then
            print(string.format("WARNING: SplitClip: Clip not found: %s", clip_id))
            return false
        end

        local start_rat = original_clip.timeline_start
        if not start_rat then
            error("SplitClip: Clip missing timeline_start (Rational)", 2)
        end

        -- Split values are in timeline (owning sequence) frames.
        local split_rat = Rational.hydrate(args.split_value, start_rat.fps_numerator, start_rat.fps_denominator)
        
        if not split_rat or not split_rat.frames then
            error("SplitClip: Invalid split_value (missing frames)")
        end

        -- Strict Model Access
        local dur_rat = original_clip.duration
        if not dur_rat then error("SplitClip: Clip missing duration (Rational)") end
        
        local end_rat = start_rat + dur_rat

        if split_rat <= start_rat or split_rat >= end_rat then
            print(string.format("WARNING: SplitClip: split_value %s is outside clip bounds [%s, %s]",
                tostring(split_rat), tostring(start_rat), tostring(end_rat)))
            return false
        end

        local mutation_sequence = original_clip.owner_sequence_id or original_clip.track_sequence_id
        if (not mutation_sequence or mutation_sequence == "") and original_clip.track_id then
            mutation_sequence = command_helper.resolve_sequence_for_track(args.sequence_id, original_clip.track_id)
        end
        if mutation_sequence and (not args.sequence_id or args.sequence_id == "") then
            command:set_parameter("sequence_id", mutation_sequence)
        end
        if mutation_sequence and not args.__snapshot_sequence_ids then
            command:set_parameter("__snapshot_sequence_ids", {mutation_sequence})
        end

        command:set_parameters({
            ["track_id"] = original_clip.track_id,
            ["original_timeline_start"] = start_rat,
            ["original_duration"] = dur_rat,
            ["original_source_in"] = original_clip.source_in,
            ["original_source_out"] = original_clip.source_out,
        })
        local first_duration = split_rat - start_rat
        local second_duration = dur_rat - first_duration
        local source_in_rat = original_clip.source_in or to_rational(original_clip.source_in_value or 0, original_clip)
        local source_split_point = source_in_rat + first_duration


        
        local second_clip = Clip.create(original_clip.name, original_clip.media_id, {
            project_id = original_clip.project_id,
            track_id = original_clip.track_id,
            parent_clip_id = original_clip.parent_clip_id,
            owner_sequence_id = original_clip.owner_sequence_id,
            source_sequence_id = original_clip.source_sequence_id,
            timeline_start = split_rat,
            duration = second_duration,
            source_in = source_split_point,
            source_out = original_clip.source_out,
            enabled = original_clip.enabled,
            offline = original_clip.offline,
            fps_numerator = original_clip.rate.fps_numerator, -- Explicitly pass rate
            fps_denominator = original_clip.rate.fps_denominator, -- Explicitly pass rate
        })
        
        if args.second_clip_id then
            second_clip.id = args.second_clip_id
        end

        if args.dry_run then
            -- Return simple preview
            return true, {
                first_clip = { clip_id = original_clip.id },
                second_clip = { clip_id = second_clip.id }
            }
        end

        original_clip.duration = first_duration
        original_clip.source_out = source_split_point

        if not original_clip:save() then
            set_last_error("SplitClip: Failed to save modified original clip")
            return false
        end

        local first_update = command_helper.clip_update_payload(original_clip, mutation_sequence)
        if first_update then
            command_helper.add_update_mutation(command, first_update.track_sequence_id or mutation_sequence, first_update)
        end

        if not second_clip:save() then
            set_last_error("SplitClip: Failed to save new clip")
            return false
        end

        local second_insert = command_helper.clip_insert_payload(second_clip, mutation_sequence)
        if second_insert then
            command_helper.add_insert_mutation(command, second_insert.track_sequence_id or mutation_sequence, second_insert)
        end

        command:set_parameter("second_clip_id", second_clip.id)

        print(string.format("Split clip %s at time %s into clips %s and %s",
            clip_id, tostring(split_rat), original_clip.id, second_clip.id))
        return true
    end

    local function perform_split_clip_undo(command)
        print("Executing UndoSplitClip command")

        local args = command:get_all_parameters()

        local original_timeline_start = args.original_timeline_start
        local original_duration = args.original_duration
        local original_source_in = args.original_source_in
        local original_source_out = args.original_source_out



        -- Re-hydrate Rationals if they came back as tables/numbers
        local function restore_rat(val)
            if type(val) == "table" and val.frames then
                return Rational.new(val.frames, val.fps_numerator, val.fps_denominator)
            end
            return val
        end
        original_timeline_start = restore_rat(original_timeline_start)
        original_duration = restore_rat(original_duration)
        original_source_in = restore_rat(original_source_in)
        original_source_out = restore_rat(original_source_out)

        local original_clip = Clip.load(args.clip_id)
        if not original_clip then
            print(string.format("WARNING: UndoSplitClip: Original clip not found: %s", args.clip_id))
            return false
        end

        local second_clip = Clip.load(args.second_clip_id)
        if not second_clip then
            set_last_error(string.format("UndoSplitClip: Second clip not found: %s", tostring(args.second_clip_id)))
            return false
        end

        if not second_clip:delete() then
            set_last_error("UndoSplitClip: Failed to delete second clip")
            return false
        end
        command_helper.add_delete_mutation(command, args.sequence_id, args.second_clip_id)

        original_clip.timeline_start = original_timeline_start
        original_clip.duration = original_duration
        original_clip.source_in = original_source_in
        original_clip.source_out = original_source_out

        if not original_clip:save() then
            set_last_error("UndoSplitClip: Failed to save original clip")
            return false
        end

        local restore_update = command_helper.clip_update_payload(original_clip, args.sequence_id)
        if restore_update then
            command_helper.add_update_mutation(command, restore_update.track_sequence_id or args.sequence_id, restore_update)
        end

        print(string.format("Undid split: restored clip %s and deleted clip %s",
            args.clip_id, args.second_clip_id))
        return true
    end

    command_undoers["SplitClip"] = perform_split_clip_undo
    command_executors["UndoSplitClip"] = perform_split_clip_undo

    -- Interactive Split command (gathers context from timeline)
    command_executors["Split"] = function(command)
        local args = command:get_all_parameters()

        -- Get timeline state to gather interactive parameters
        local timeline_state_ok, timeline_state = pcall(require, "ui.timeline.timeline_state")
        if not timeline_state_ok or not timeline_state then
            return {success = false, error_message = "Split: timeline state unavailable"}
        end

        local playhead_value = timeline_state.get_playhead_position and timeline_state.get_playhead_position()
        if not playhead_value then
            return {success = false, error_message = "Split: playhead position unavailable"}
        end

        local Rational = require("core.rational")
        local json = require("dkjson")
        local Command = require("command")

        local rate = timeline_state.get_sequence_frame_rate and timeline_state.get_sequence_frame_rate()
        if not rate or not rate.fps_numerator or not rate.fps_denominator then
            return {success = false, error_message = "Split: sequence frame rate unavailable"}
        end

        local playhead_rt = Rational.hydrate(playhead_value, rate.fps_numerator, rate.fps_denominator)
        if not playhead_rt then
            return {success = false, error_message = "Split: could not hydrate playhead position"}
        end

        -- Get all clips under the playhead
        local clips_at_playhead = timeline_state.get_clips_at_time and timeline_state.get_clips_at_time(playhead_rt) or {}

        if #clips_at_playhead == 0 then
            local all_clips = timeline_state.get_clips and timeline_state.get_clips() or {}
            return {success = false, error_message = string.format(
                "Split: no clips under playhead (playhead=%s frames, total=%d)",
                tostring(playhead_rt.frames), #all_clips)}
        end

        -- Check if there's a selection that overlaps with clips at playhead
        local selected_clips = timeline_state.get_selected_clips and timeline_state.get_selected_clips() or {}
        local clips_to_split

        if #selected_clips > 0 then
            -- Build lookup of selected clip IDs
            local selected_ids = {}
            for _, sel in ipairs(selected_clips) do
                if sel and sel.id then
                    selected_ids[sel.id] = true
                end
            end
            -- Filter clips at playhead to only those that are selected
            local selected_at_playhead = {}
            for _, clip in ipairs(clips_at_playhead) do
                if selected_ids[clip.id] then
                    table.insert(selected_at_playhead, clip)
                end
            end
            -- If any selected clips are under playhead, split only those
            -- Otherwise, ignore selection and split all clips under playhead
            if #selected_at_playhead > 0 then
                clips_to_split = selected_at_playhead
            else
                clips_to_split = clips_at_playhead
            end
        else
            -- No selection: use all clips under playhead
            clips_to_split = clips_at_playhead
        end

        local specs = {}
        for _, clip in ipairs(clips_to_split) do
            table.insert(specs, {
                command_type = "SplitClip",
                parameters = {
                    clip_id = clip.id,
                    split_value = playhead_rt
                }
            })
        end

        local project_id = args.project_id or (timeline_state.get_project_id and timeline_state.get_project_id())
        if not project_id or project_id == "" then
            return {success = false, error_message = "Split: project_id unavailable"}
        end

        local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        local command_manager = require("core.command_manager")

        -- No explicit undo grouping needed - command_manager.execute() automatically
        -- groups nested commands with their parent via undo_group_id

        local success_count = 0
        local any_failed = false

        for _, spec in ipairs(specs) do
            local split_cmd = Command.create("SplitClip", project_id)
            split_cmd:set_parameter("clip_id", spec.parameters.clip_id)
            split_cmd:set_parameter("split_value", spec.parameters.split_value)
            if active_sequence_id then
                split_cmd:set_parameter("sequence_id", active_sequence_id)
            end

            local result = command_manager.execute(split_cmd)
            if result.success then
                success_count = success_count + 1
            else
                logger.error("split", string.format("Split: SplitClip failed for clip %s: %s",
                    spec.parameters.clip_id, result.error_message or "unknown"))
                any_failed = true
            end
        end

        if any_failed and success_count == 0 then
            return {success = false, error_message = "Split: all SplitClip commands failed"}
        end

        logger.debug("split", string.format("Split %d clip(s) at playhead", success_count))
        return true
    end

    -- Split undoer: delegate to SplitClip undoers (automatic via undo_group)
    -- The Split command doesn't need a custom undoer - when undo() is called,
    -- it will find the last command (a SplitClip) which shares Split's undo_group_id,
    -- and undo_group will undo all SplitClips plus Split together.
    --
    -- However, if Split itself is the last command (no clips to split), we need an undoer.
    command_undoers["Split"] = function(command)
        -- Split with no nested SplitClip commands is a no-op, nothing to undo
        logger.debug("split", "Undo Split: no-op (automatic undo handles nested commands)")
        return true
    end

    return {
        ["SplitClip"] = {
            executor = command_executors["SplitClip"],
            undoer = command_undoers["SplitClip"],
            spec = SPEC,
        },
        ["Split"] = {
            executor = command_executors["Split"],
            undoer = command_undoers["Split"],
            spec = {args = {project_id = {required = true}, sequence_id = {}}},
        },
    }
end

return M
