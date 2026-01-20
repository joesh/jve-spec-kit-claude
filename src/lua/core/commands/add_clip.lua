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
-- Size: ~24 LOC
-- Volatility: unknown
--
-- @file add_clip.lua
local M = {}


local SPEC = {
    args = {
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    -- This command is just an alias for CreateClip
    command_executors["AddClip"] = function(command)
        print("Executing AddClip command")
        -- Ensure CreateClip is registered/available
        local CreateClip = command_executors["CreateClip"]
        if not CreateClip then
             -- Try to load it if not present (though typically registered before)
             local create_clip_module = require("core.commands.create_clip")
             if create_clip_module and create_clip_module.register then
                 create_clip_module.register(command_executors, command_undoers, db, set_last_error)
                 CreateClip = command_executors["CreateClip"]
             end
        end
        
        if CreateClip then
            return CreateClip(command)
        else
            set_last_error("AddClip: CreateClip command not found")
            return false
        end
    end

    return {
        executor = command_executors["AddClip"],
        spec = SPEC,
    }
end

return M