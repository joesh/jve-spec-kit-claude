--- Find commands: Find, FindNext, FindPrevious, ClearFind
--
-- Non-undoable commands wrapping find_state module.
-- Available to scripting via command_manager.execute("Find", {...})
--
-- @file find_clips.lua

local find_state = require("core.find_state")
local sift_state = require("core.sift_state")

local M = {}

local SPEC_FIND = {
    undoable = false,
    args = {
        project_id = { required = true },
        column = { required = true },
        operator = { required = true },
        value = { required = true },
        scope = {},           -- "all" (default), "visible"
        context = {},         -- "browser" (default), "timeline"
        sequence_id = {},     -- required for timeline context
    },
}

local SPEC_FIND_NEXT = {
    undoable = false,
    args = {
        project_id = { required = true },
        direction = {},       -- "forward" (default), "backward"
    },
}

local SPEC_CLEAR_FIND = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}

function M.register(command_executors, command_undoers, _, _)
    command_executors["Find"] = function(command)
        local args = command:get_all_parameters()
        local query = {
            column = args.column,
            operator = args.operator,
            value = args.value,
        }

        -- Get clips from context
        -- In full integration, browser/timeline provide clips
        -- For now, clips must be passed via __clips ephemeral param
        local clips = args.__clips
        assert(clips, "Find: __clips required (UI layer provides clip list)")

        -- Scope filtering
        local opts = {}
        if args.scope == "visible" and sift_state.is_active() then
            local eval = sift_state.evaluate(clips)
            local hidden = {}
            for _, id in ipairs(eval.hidden_ids) do hidden[id] = true end
            opts.hidden_ids = hidden
        end

        -- Sort by timeline_start_frame for timeline context
        if args.context == "timeline" then
            table.sort(clips, function(a, b)
                return (a.timeline_start_frame or 0) < (b.timeline_start_frame or 0)
            end)
        end

        find_state.execute(clips, query, opts)

        return {
            success = true,
            match_count = find_state.get_match_count(),
            match_ids = find_state.get_matches(),
            current_match = find_state.get_current_match(),
        }
    end

    command_executors["FindNext"] = function(command)
        local args = command:get_all_parameters()
        if not find_state.is_active() then
            return {success = false, error_message = "No active find session"}
        end
        if args.direction == "backward" then
            find_state.previous()
        else
            find_state.next()
        end
        return {
            success = true,
            current_match = find_state.get_current_match(),
            current_index = find_state.get_current_index(),
        }
    end

    command_executors["FindPrevious"] = function(command)
        command:set_parameter("direction", "backward")
        return command_executors["FindNext"](command)
    end

    command_executors["ClearFind"] = function(_)
        local prev = find_state.get_previous_selection()
        find_state.clear()
        return {success = true, previous_selection = prev}
    end

    -- FindReplace: non-undoable stub — UI layer opens dialog
    command_executors["FindReplace"] = function(_)
        return {success = true, action = "open_dialog"}
    end

    -- Style B: multi-command registration
    return {
        ["Find"] = {executor = command_executors["Find"], spec = SPEC_FIND},
        ["FindNext"] = {executor = command_executors["FindNext"], spec = SPEC_FIND_NEXT},
        ["FindPrevious"] = {executor = command_executors["FindPrevious"], spec = SPEC_FIND_NEXT},
        ["ClearFind"] = {executor = command_executors["ClearFind"], spec = SPEC_CLEAR_FIND},
        ["FindReplace"] = {executor = command_executors["FindReplace"], spec = SPEC_CLEAR_FIND},
    }
end

return M
