--- Source Viewer Mark Commands
--
-- Commands:
-- - SourceViewerSetMarkIn: set mark in at playhead (or explicit frame)
-- - SourceViewerSetMarkOut: set mark out at playhead (or explicit frame)
-- - SourceViewerGoToMarkIn: navigate playhead to mark in
-- - SourceViewerGoToMarkOut: navigate playhead to mark out
-- - SourceViewerClearMarks: clear both marks
--
-- @file source_marks.lua
local M = {}

local function get_source_view()
    local pm = require("ui.panel_manager")
    return pm.get_sequence_view("source_view")
end

local SET_MARK_IN_SPEC = {
    undoable = false,
    args = {
        frame = { kind = "number" },  -- optional: defaults to playhead
    },
}

local SET_MARK_OUT_SPEC = {
    undoable = false,
    args = {
        frame = { kind = "number" },  -- optional: defaults to playhead
    },
}

local GO_TO_MARK_IN_SPEC = {
    undoable = false,
    args = {},
}

local GO_TO_MARK_OUT_SPEC = {
    undoable = false,
    args = {},
}

local CLEAR_MARKS_SPEC = {
    undoable = false,
    args = {},
}

function M.register(executors, undoers, db)
    executors["SourceViewerSetMarkIn"] = function(command)
        local sv = get_source_view()
        if not sv:has_clip() then
            return { success = false, error_message = "SourceViewerSetMarkIn: no clip loaded" }
        end
        local args = command:get_all_parameters()
        local frame = args.frame or sv.playhead
        sv:set_mark_in(frame)
        return { success = true }
    end

    executors["SourceViewerSetMarkOut"] = function(command)
        local sv = get_source_view()
        if not sv:has_clip() then
            return { success = false, error_message = "SourceViewerSetMarkOut: no clip loaded" }
        end
        local args = command:get_all_parameters()
        local frame = args.frame or sv.playhead
        sv:set_mark_out(frame)
        return { success = true }
    end

    executors["SourceViewerGoToMarkIn"] = function(_command)
        local sv = get_source_view()
        if not sv:has_clip() then
            return { success = false, error_message = "SourceViewerGoToMarkIn: no clip loaded" }
        end
        local mark_in = sv:get_mark_in()
        if not mark_in then
            return { success = false, error_message = "SourceViewerGoToMarkIn: no mark in set" }
        end
        sv:seek_to_frame(mark_in)
        return { success = true }
    end

    executors["SourceViewerGoToMarkOut"] = function(_command)
        local sv = get_source_view()
        if not sv:has_clip() then
            return { success = false, error_message = "SourceViewerGoToMarkOut: no clip loaded" }
        end
        local mark_out = sv:get_mark_out()
        if not mark_out then
            return { success = false, error_message = "SourceViewerGoToMarkOut: no mark out set" }
        end
        sv:seek_to_frame(mark_out)
        return { success = true }
    end

    executors["SourceViewerClearMarks"] = function(_command)
        local sv = get_source_view()
        if not sv:has_clip() then
            return { success = false, error_message = "SourceViewerClearMarks: no clip loaded" }
        end
        sv:clear_marks()
        return { success = true }
    end

    return {
        ["SourceViewerSetMarkIn"] = { executor = executors["SourceViewerSetMarkIn"], spec = SET_MARK_IN_SPEC },
        ["SourceViewerSetMarkOut"] = { executor = executors["SourceViewerSetMarkOut"], spec = SET_MARK_OUT_SPEC },
        ["SourceViewerGoToMarkIn"] = { executor = executors["SourceViewerGoToMarkIn"], spec = GO_TO_MARK_IN_SPEC },
        ["SourceViewerGoToMarkOut"] = { executor = executors["SourceViewerGoToMarkOut"], spec = GO_TO_MARK_OUT_SPEC },
        ["SourceViewerClearMarks"] = { executor = executors["SourceViewerClearMarks"], spec = CLEAR_MARKS_SPEC },
    }
end

return M
