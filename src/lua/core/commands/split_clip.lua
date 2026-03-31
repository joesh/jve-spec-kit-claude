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
local ClipLink = require("models.clip_link")
local command_helper = require("core.command_helper")
local log = require("core.logger").for_area("commands")


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
        original_link_group_id = {},  -- Set by executor if clip was linked
        original_source_in = {},  -- Set by executor
        original_source_out = {},  -- Set by executor
        original_timeline_start = {},  -- Set by executor
        project_id = { required = true },
    },

}

function M.register(command_executors, command_undoers, db, set_last_error)
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

        local timeline_start = original_clip.timeline_start
        assert(type(timeline_start) == "number", "SplitClip: Clip timeline_start must be integer")

        -- Split value must be integer frames
        local split_frame = args.split_value
        assert(type(split_frame) == "number", "SplitClip: split_value must be integer frames")

        local duration = original_clip.duration
        assert(type(duration) == "number", "SplitClip: Clip duration must be integer")

        local clip_end = timeline_start + duration

        if split_frame <= timeline_start or split_frame >= clip_end then
            print(string.format("WARNING: SplitClip: split_value %d is outside clip bounds [%d, %d]",
                split_frame, timeline_start, clip_end))
            return false
        end

        local mutation_sequence = original_clip.owner_sequence_id or original_clip.track_sequence_id
        if (not mutation_sequence or mutation_sequence == "") and original_clip.track_id then
            mutation_sequence = command_helper.resolve_sequence_for_track(args.sequence_id, original_clip.track_id)
        end
        if mutation_sequence and (not args.sequence_id or args.sequence_id == "") then
            command:set_parameter("sequence_id", mutation_sequence)
        end

        command:set_parameters({
            ["track_id"] = original_clip.track_id,
            ["original_timeline_start"] = timeline_start,
            ["original_duration"] = duration,
            ["original_source_in"] = original_clip.source_in,
            ["original_source_out"] = original_clip.source_out,
        })

        local first_duration = split_frame - timeline_start
        local second_duration = duration - first_duration
        local source_in = original_clip.source_in
        assert(type(source_in) == "number", "SplitClip: source_in must be integer")
        local source_split_point = source_in + first_duration

        local second_clip = Clip.create(original_clip.name, original_clip.media_id, {
            project_id = original_clip.project_id,
            track_id = original_clip.track_id,
            owner_sequence_id = original_clip.owner_sequence_id,
            master_clip_id = original_clip.master_clip_id,
            timeline_start = split_frame,
            duration = second_duration,
            source_in = source_split_point,
            source_out = original_clip.source_out,
            enabled = original_clip.enabled,
            offline = original_clip.offline,
            fps_numerator = original_clip.rate.fps_numerator,
            fps_denominator = original_clip.rate.fps_denominator,
            -- Preserve per-clip metadata on both halves
            volume = original_clip.volume,
        })

        if args.second_clip_id then
            second_clip.id = args.second_clip_id
        end

        if args.dry_run then
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

        -- Store link info for the Split wrapper to use when creating new link groups
        -- SplitClip does NOT add to link groups - the Split wrapper handles that
        local link_group_id = ClipLink.get_link_group_id(clip_id, db)
        if link_group_id then
            local link_group = ClipLink.get_link_group(clip_id, db)
            for _, link_info in ipairs(link_group or {}) do
                if link_info.clip_id == clip_id then
                    command:set_parameter("original_link_group_id", link_group_id)
                    command:set_parameter("original_link_role", link_info.role)
                    break
                end
            end
        end

        print(string.format("Split clip %s at frame %d into clips %s and %s",
            clip_id, split_frame, original_clip.id, second_clip.id))

        return {
            success = true,
            second_clip_id = second_clip.id,
            original_link_group_id = link_group_id,
            original_link_role = command:get_parameter("original_link_role"),
        }
    end

    local function perform_split_clip_undo(command)
        print("Executing UndoSplitClip command")

        local args = command:get_all_parameters()

        local original_timeline_start = args.original_timeline_start
        local original_duration = args.original_duration
        local original_source_in = args.original_source_in
        local original_source_out = args.original_source_out

        -- All stored coords must be integers
        assert(type(original_timeline_start) == "number", "UndoSplitClip: original_timeline_start must be integer")
        assert(type(original_duration) == "number", "UndoSplitClip: original_duration must be integer")
        assert(type(original_source_in) == "number", "UndoSplitClip: original_source_in must be integer")
        assert(type(original_source_out) == "number", "UndoSplitClip: original_source_out must be integer")

        local original_clip = Clip.load(args.clip_id)
        if not original_clip then
            print(string.format("WARNING: UndoSplitClip: Original clip not found: %s", args.clip_id))
            return false
        end

        local second_clip = Clip.load(args.second_clip_id)
        if second_clip then
            -- Unlink before deleting (Split wrapper may have linked the second halves)
            ClipLink.unlink_clip(args.second_clip_id, db)
            if not second_clip:delete() then
                set_last_error("UndoSplitClip: Failed to delete second clip")
                return false
            end
            command_helper.add_delete_mutation(command, args.sequence_id, args.second_clip_id)
        else
            log.warn("UndoSplitClip: Second clip %s already absent, skipping delete",
                tostring(args.second_clip_id))
        end

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

        local clips_to_split, playhead = command_helper.resolve_clips_at_playhead()
        if #clips_to_split == 0 then
            log.event("Split: no clips under playhead")
            return true
        end

        local _json = require("dkjson")  -- luacheck: ignore 211 (unused, required for module init)
        local Command = require("command")

        local specs = {}
        for _, clip in ipairs(clips_to_split) do
            table.insert(specs, {
                command_type = "SplitClip",
                parameters = {
                    clip_id = clip.id,
                    split_value = playhead
                }
            })
        end

        local timeline_state = require("ui.timeline.timeline_state")
        local project_id = args.project_id or (timeline_state.get_project_id and timeline_state.get_project_id())
        if not project_id or project_id == "" then
            return {success = false, error_message = "Split: project_id unavailable"}
        end

        local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        local command_manager = require("core.command_manager")

        local success_count = 0
        local any_failed = false

        -- Track second clips by their original link group for re-linking
        local second_clips_by_link_group = {}  -- link_group_id -> [{clip_id, role}, ...]

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

                -- Track second clips for re-linking
                if result.original_link_group_id and result.second_clip_id then
                    local group_id = result.original_link_group_id
                    second_clips_by_link_group[group_id] = second_clips_by_link_group[group_id] or {}
                    table.insert(second_clips_by_link_group[group_id], {
                        clip_id = result.second_clip_id,
                        role = result.original_link_role,
                    })
                end
            else
                log.error("Split: SplitClip failed for clip %s: %s",
                    spec.parameters.clip_id, result.error_message or "unknown")
                any_failed = true
            end
        end

        if any_failed and success_count == 0 then
            return {success = false, error_message = "Split: all SplitClip commands failed"}
        end

        -- Create new link groups for second halves (mirroring original link groups)
        for link_group_id, second_clips in pairs(second_clips_by_link_group) do
            if #second_clips >= 2 then
                -- Create a new link group with the second halves
                local new_group_id, err = ClipLink.create_link_group(second_clips, db)
                if new_group_id then
                    log.event("Created new link group %s for %d second-half clips (from original group %s)",
                        new_group_id, #second_clips, link_group_id)
                else
                    log.warn("Failed to create link group for second halves: %s", err or "unknown")
                end
            end
            -- If only 1 second clip from a link group, it stays unlinked
            -- (the other linked clip wasn't split)
        end

        log.event("Split %d clip(s) at playhead", success_count)
        return true
    end

    command_undoers["Split"] = function(command)
        log.event("Undo Split: no-op (automatic undo handles nested commands)")
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
