local M = {}

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
            print("ERROR: AddClip: CreateClip command not found")
            return false
        end
    end

    return {
        executor = command_executors["AddClip"]
    }
end

return M
