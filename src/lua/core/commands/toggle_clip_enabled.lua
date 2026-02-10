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
-- Size: ~113 LOC
-- Volatility: unknown
--
-- @file toggle_clip_enabled.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local timeline_state = require('ui.timeline.timeline_state')


local SPEC = {
    args = {
        -- Provide either clip_ids or clip_toggles.
        --
        -- clip_ids: convenience input. Executor derives clip_toggles (with before/after) and
        --           persists them onto the command for replay/undo.
        -- If neither provided, executor derives from timeline selection.
        clip_ids = { kind = "table" },
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    },
    persisted = {
        -- Derived output (and accepted as an input for replay): list of {clip_id, enabled_before, enabled_after}.
        clip_toggles = { kind = "table" },
    },
    -- Note: requires_any removed - executor derives clip_ids from selection if not provided
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local function record_clip_enabled_mutation(command, clip, args)
        if not clip then
            return
        end
        local mutation_sequence = (args and args.sequence_id) or clip.owner_sequence_id or clip.track_sequence_id
        local update_payload = command_helper.clip_update_payload(clip, mutation_sequence)
        if update_payload then
            command_helper.add_update_mutation(command, update_payload.track_sequence_id or mutation_sequence, update_payload)
        end
    end

    command_executors["ToggleClipEnabled"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing ToggleClipEnabled command")
        end

        local active_sequence_id = command_helper.resolve_active_sequence_id(args.sequence_id, timeline_state)
        if active_sequence_id and active_sequence_id ~= args.sequence_id then
            command:set_parameter("sequence_id", active_sequence_id)
        end

        local toggles = args.clip_toggles
        if not toggles or #toggles == 0 then
            local clip_ids = args.clip_ids

            if not clip_ids or #clip_ids == 0 then
                local selected_clips = timeline_state.get_selected_clips() or {}
                clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    if clip and clip.id then
                        table.insert(clip_ids, clip.id)
                    end
                end
            end

            if not clip_ids or #clip_ids == 0 then
                print("ToggleClipEnabled: No clips selected")
                return false
            end

            toggles = {}
            for _, clip_id in ipairs(clip_ids) do
                local clip = Clip.load_optional(clip_id)
                if clip then
                    local enabled_before = clip.enabled ~= false
                    table.insert(toggles, {
                        clip_id = clip_id,
                        enabled_before = enabled_before,
                        enabled_after = not enabled_before,
                    })
                else
                    print(string.format("WARNING: ToggleClipEnabled: Clip %s not found", tostring(clip_id)))
                end
            end

            if #toggles == 0 then
                print("ToggleClipEnabled: No valid clips to toggle")
                return false
            end

            command:set_parameter("clip_toggles", toggles)
        end

        if args.dry_run then
            return true, {clip_toggles = toggles}
        end

        command:set_parameter("__skip_sequence_replay", true)

        local toggled = 0
        for _, toggle in ipairs(toggles) do
            local clip = Clip.load_optional(toggle.clip_id)
            if clip then
                clip.enabled = toggle.enabled_after and true or false
                if clip:save({skip_occlusion = true}) then
                    record_clip_enabled_mutation(command, clip, args)
                    toggled = toggled + 1
                else
                    print(string.format("ERROR: ToggleClipEnabled: Failed to save clip %s", tostring(toggle.clip_id)))
                    return false
                end
            else
                print(string.format("WARNING: ToggleClipEnabled: Clip %s missing during execution", tostring(toggle.clip_id)))
            end
        end

        print(string.format("✅ Toggled enabled state for %d clip(s)", toggled))
        return toggled > 0
    end

    command_undoers["ToggleClipEnabled"] = function(command)
        local args = command:get_all_parameters()

        if not args.clip_toggles or #args.clip_toggles == 0 then
            return true
        end

        local restored = 0
        for _, toggle in ipairs(args.clip_toggles) do
            local clip = Clip.load_optional(toggle.clip_id)
            if clip then
                clip.enabled = toggle.enabled_before and true or false
                if clip:save({skip_occlusion = true}) then
                    record_clip_enabled_mutation(command, clip, args)
                    restored = restored + 1
                else
                    print(string.format("WARNING: ToggleClipEnabled undo: Failed to restore clip %s", tostring(toggle.clip_id)))
                end
            end
        end

        -- Flush logic is typically in command_manager, but some undoers called it explicitly.
        -- We assume mutations are picked up from command by manager.

        print(string.format("✅ Undo ToggleClipEnabled: Restored %d clip(s)", restored))
        return true
    end

    return {
        executor = command_executors["ToggleClipEnabled"],
        undoer = command_undoers["ToggleClipEnabled"],
        spec = SPEC,
    }
end

return M
