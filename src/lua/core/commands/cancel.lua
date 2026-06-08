--- Cancel command: Escape-key logic ported to the command system.
--- Handles prioritised dismissals: Fullscreen → Dialogs → Find Bar → Timecode Entry.
---
--- @module cancel.lua
local M = {}

local log = require("core.logger").for_area("commands")

local SPEC = {
    name = "Cancel",
    description = "Prioritised action cancellation (Escape key)",
    undoable = false,
    args = {
        project_id = { required = false },
        focus_is_text_input = { required = false, kind = "boolean" }
    },
}

function M.execute(args)
    local focus_is_text_input = args.focus_is_text_input
    local cancel = require("core.cancel")
    cancel.request()
    log.detail("Cancel command: request flag set (text_input=%s)", tostring(focus_is_text_input))

    -- 1. Fullscreen
    local fv_ok, fv = pcall(require, "ui.fullscreen_viewer")
    if fv_ok and fv and fv.is_active() then
        log.detail("  → exit fullscreen")
        fv.exit()
        return true
    end

    -- 2. Floating Find Dialog
    -- pcall: find_dialog depends on dkjson (C lib), unavailable in headless tests.
    local find_ok, find_dlg = pcall(require, "ui.find_dialog")
    if find_ok and find_dlg and find_dlg.is_visible() then
        log.detail("  → dismiss floating find dialog")
        find_dlg.hide()
        return true
    end

    -- 3. Project Browser Find Bar
    local pb_ok, pb = pcall(require, "ui.project_browser")
    if pb_ok and pb and pb.find_bar and pb.find_bar.visible then
        log.detail("  → dismiss find bar")
        pb.hide_find_bar()
        return true
    end

    -- 4. Timeline Timecode Entry
    if focus_is_text_input then
        local tp_ok, timeline_panel = pcall(require, "ui.timeline.timeline_panel")
        if tp_ok and timeline_panel then
            local focus_manager = require("ui.focus_manager")
            if focus_manager.get_focused_panel() == "timeline" then
                if timeline_panel.cancel_timecode_entry() then
                    log.detail("  → cancel timecode entry")
                    return true
                end
            end
        end
    end

    -- If nothing consumed it, return false so the caller knows (though usually
    -- Escape is just swallowed).
    return false
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors.Cancel = function(command)
        return M.execute(command:get_all_parameters())
    end

    return {
        Cancel = {
            executor = command_executors.Cancel,
            spec = SPEC,
        }
    }
end

return M
