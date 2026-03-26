--- Sift commands: Sift, ExpandSift, NarrowSift, ClearSift
--
-- Non-undoable commands wrapping sift_state + persistence.
-- Available to scripting via command_manager.execute("Sift", {...})
--
-- @file sift.lua

local sift_commands = require("core.sift_commands")
local sift_state = require("core.sift_state")

local M = {}

local SPEC_SIFT = {
    undoable = false,
    args = {
        project_id = { required = true },
        column = { required = true },
        operator = { required = true },
        value = { required = true },
    },
}

local SPEC_CLEAR_SIFT = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}

function M.register(command_executors, _, db, _)
    command_executors["Sift"] = function(command)
        local args = command:get_all_parameters()
        local clips = args.__clips
        assert(clips, "Sift: __clips required (UI layer provides clip list)")
        local query = {column = args.column, operator = args.operator, value = args.value}
        sift_commands.sift(clips, query, db, args.project_id)
        local result = sift_state.evaluate(clips)
        return {success = true, visible_count = #result.visible_ids, hidden_count = #result.hidden_ids}
    end

    command_executors["ExpandSift"] = function(command)
        local args = command:get_all_parameters()
        local clips = args.__clips
        assert(clips, "ExpandSift: __clips required")
        assert(sift_state.is_active(), "ExpandSift: no active sift")
        local query = {column = args.column, operator = args.operator, value = args.value}
        sift_commands.expand_sift(clips, query, db, args.project_id)
        local result = sift_state.evaluate(clips)
        return {success = true, visible_count = #result.visible_ids, hidden_count = #result.hidden_ids}
    end

    command_executors["NarrowSift"] = function(command)
        local args = command:get_all_parameters()
        local clips = args.__clips
        assert(clips, "NarrowSift: __clips required")
        assert(sift_state.is_active(), "NarrowSift: no active sift")
        local query = {column = args.column, operator = args.operator, value = args.value}
        sift_commands.narrow_sift(clips, query, db, args.project_id)
        local result = sift_state.evaluate(clips)
        return {success = true, visible_count = #result.visible_ids, hidden_count = #result.hidden_ids}
    end

    command_executors["ClearSift"] = function(command)
        local args = command:get_all_parameters()
        sift_commands.clear_sift(db, args.project_id)
        return {success = true}
    end

    -- Style B: multi-command registration
    return {
        ["Sift"] = {executor = command_executors["Sift"], spec = SPEC_SIFT},
        ["ExpandSift"] = {executor = command_executors["ExpandSift"], spec = SPEC_SIFT},
        ["NarrowSift"] = {executor = command_executors["NarrowSift"], spec = SPEC_SIFT},
        ["ClearSift"] = {executor = command_executors["ClearSift"], spec = SPEC_CLEAR_SIFT},
    }
end

return M
