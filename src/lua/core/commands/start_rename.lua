--- StartRename: initiate inline rename on the selected browser item.
-- Non-undoable (just enters edit mode). The actual rename happens via RenameItem.
-- @file start_rename.lua
local M = {}

function M.register()
    return {
        executor = function()
            local pb = require("ui.project_browser")
            assert(pb.start_inline_rename,
                "StartRename: project_browser.start_inline_rename missing")
            local started = pb.start_inline_rename()
            assert(started, "StartRename: no item selected or edit mode failed")
            return true
        end,
        spec = { undoable = false, args = {} },
    }
end

return M
