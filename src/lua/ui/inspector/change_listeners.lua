-- Inspector change listeners.
--
-- Single-channel pull-on-notify (MVC rule 3.0). Only Signals.connect is
-- used — no timeline_state.add_listener subscription, no direct
-- imperative push paths. Rule 2.20 audit T054 greps for this.
--
-- Handlers:
--   project_changed(new_project_id)  — clear Inspector state (FR-017)
--   content_changed(sequence_id)     — pull current inspectables and refresh
--                                      non-dirty fields (FR-016, FR-016a)

local Signals = require("core.signals")
local qt_constants = require("core.qt_constants")
local selection_binding = require("ui.inspector.selection_binding")
local log = require("core.logger").for_area("ui")

local M = {}

local function on_project_changed(ui_state)
    return function(_new_project_id)
        if ui_state.active_schema_view then
            ui_state.schema.deactivate(ui_state.active_schema_view)
        end
        ui_state.active_schema_view  = nil
        ui_state.active_schema_id    = nil
        ui_state.active_inspectables = {}
        ui_state.mode                = "empty"
        ui_state.prev_item_ids       = {}
        ui_state.prev_schemas_present = {}
        if ui_state.header_label then
            qt_constants.PROPERTIES.SET_TEXT(ui_state.header_label, "No editable selection")
        end
        if ui_state.apply_button then
            qt_constants.DISPLAY.SET_VISIBLE(ui_state.apply_button, false)
        end
        log.event("inspector: project_changed — state cleared")
    end
end

local function on_content_changed(ui_state)
    return function(sequence_id)
        if not sequence_id or sequence_id == "" then return end
        if not ui_state.active_schema_view then return end
        if #ui_state.active_inspectables == 0 then return end

        -- Match on any inspectable whose .sequence_id == signal arg.
        local match = false
        for _, insp in ipairs(ui_state.active_inspectables) do
            if insp.sequence_id == sequence_id then match = true; break end
        end
        if not match then return end

        -- Refresh the inspectables' DB cache.
        for _, insp in ipairs(ui_state.active_inspectables) do
            if insp.refresh then insp:refresh() end
        end

        -- Re-read non-dirty fields only. Dirty fields keep user's in-flight
        -- text (FR-016a).
        selection_binding._refresh_only_clean_fields(
            ui_state.active_schema_view,
            ui_state.active_inspectables,
            #ui_state.active_inspectables
        )
    end
end

--- Install both handlers. Returns a disposers table for test teardown.
function M.install(ui_state)
    assert(ui_state, "change_listeners.install: ui_state required")
    local pc_id = Signals.connect("project_changed", on_project_changed(ui_state), 45)
    assert(pc_id, "change_listeners: failed to connect project_changed")
    local cc_id = Signals.connect("content_changed", on_content_changed(ui_state), 60)
    assert(cc_id, "change_listeners: failed to connect content_changed")

    return {
        project_changed_id = pc_id,
        content_changed_id = cc_id,
    }
end

function M.uninstall(disposers)
    if not disposers then return end
    if disposers.project_changed_id then
        Signals.disconnect(disposers.project_changed_id)
    end
    if disposers.content_changed_id then
        Signals.disconnect(disposers.content_changed_id)
    end
end

return M
