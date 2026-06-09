--- Cancel command: Escape-key logic ported to the command system.
--- Handles prioritised dismissals: Fullscreen → Dialogs → Find Bar → Timecode Entry.
---
--- @module cancel.lua
local M = {}

local log = require("core.logger").for_area("commands")

-- Cancel is only meaningfully active when there's a dismissable surface.
-- The `when` predicate (consulted by keyboard_shortcut_registry at keypress
-- time) gates Escape on that condition — when nothing is dismissable, the
-- binding is inactive and Escape falls through to Qt for native handling.
local function fullscreen_active()
    local ok, fv = pcall(require, "ui.fullscreen_viewer")
    return ok and fv and fv.is_active()
end

local function find_dialog_visible()
    -- pcall: find_dialog depends on dkjson (C lib), unavailable in headless tests.
    local ok, fd = pcall(require, "ui.find_dialog")
    return ok and fd and fd.is_visible()
end

local function find_bar_visible()
    local ok, pb = pcall(require, "ui.project_browser")
    return ok and pb and pb.find_bar and pb.find_bar.visible
end

local function timeline_tc_entry_focused()
    local ok, tp = pcall(require, "ui.timeline.timeline_panel")
    if not (ok and tp) then return false end
    local focus_manager = require("ui.focus_manager")
    return focus_manager.get_focused_panel() == "timeline"
end

local SPEC = {
    name = "Cancel",
    description = "Prioritised action cancellation (Escape key)",
    undoable = false,
    args = {
        project_id = { required = false },
        focus_is_text_input = { required = false, kind = "boolean" }
    },
    -- Gate evaluated at keypress with the same params execute() will see.
    -- TC entry cancellation is the only branch that depends on a runtime
    -- param (focus_is_text_input) — it only fires when the focused widget
    -- is a text input AND the timeline panel is focused. Without text-input
    -- focus, an Escape with timeline focused must fall through to Qt.
    when = function(params)
        return fullscreen_active()
            or find_dialog_visible()
            or find_bar_visible()
            or (params and params.focus_is_text_input and timeline_tc_entry_focused())
    end,
}

function M.execute(args)
    local focus_is_text_input = args.focus_is_text_input
    local cancel = require("core.cancel")
    cancel.request()
    log.detail("Cancel command: request flag set (text_input=%s)", tostring(focus_is_text_input))

    if fullscreen_active() then
        log.detail("  → exit fullscreen")
        require("ui.fullscreen_viewer").exit()
        return true
    end

    if find_dialog_visible() then
        log.detail("  → dismiss floating find dialog")
        require("ui.find_dialog").hide()
        return true
    end

    if find_bar_visible() then
        log.detail("  → dismiss find bar")
        require("ui.project_browser").hide_find_bar()
        return true
    end

    if focus_is_text_input and timeline_tc_entry_focused() then
        local timeline_panel = require("ui.timeline.timeline_panel")
        if timeline_panel.cancel_timecode_entry() then
            log.detail("  → cancel timecode entry")
            return true
        end
    end

    -- when() said active; reaching here means the surface vanished between
    -- the gate evaluation and execute (rare race — dialog dismissed by
    -- another input in the same tick). Consume rather than fall through:
    -- the binding was claimed at match time.
    log.warn("Cancel: when() said active but no dismissable surface at execute")
    return true
end

-- Exported so tests (and other introspection callers) can reach the SPEC
-- — in particular SPEC.when — without duplicating the predicate.
M.SPEC = SPEC

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
