-- Inspector public API facade.
--
-- THREE public functions. No init/ensure_search_row/set_header_text/
-- set_batch_enabled/get_filter/set_filter/save_field_value/save_all_fields/
-- apply_multi_edit/_G.inspector_*. Rule 2.15, 2.17, FR-027, FR-031.

local mount_module       = require("ui.inspector.mount")
local selection_binding  = require("ui.inspector.selection_binding")

local M = {}

local ui_state = nil

function M.mount(container_widget)
    assert(container_widget, "ui.inspector.mount: container_widget required")
    assert(ui_state == nil, "ui.inspector.mount: already mounted (only one Inspector per process)")
    ui_state = mount_module.mount(container_widget)
end

function M.update_selection(items, source_panel_id)
    assert(ui_state, "ui.inspector.update_selection: not mounted")
    selection_binding.update_selection(items or {}, source_panel_id or "", ui_state)
end

function M.get_focus_widgets()
    assert(ui_state, "ui.inspector.get_focus_widgets: not mounted")
    -- Primary interactive widget only — matches project_browser's {tree} and
    -- source_monitor's {get_widget()} patterns. focus_widgets[1] is the target
    -- for cross-window focus_panel() steals AND the starting point for a Tab
    -- navigation cycle into this panel. search_input is a QLineEdit (accepts
    -- keyboard input); scroll_area is not. Including scroll_area here would
    -- land cross-window focus on a widget that can't type.
    local w = ui_state.search_input
    assert(w, "ui.inspector.get_focus_widgets: search_input not constructed")
    assert(type(w) == "userdata",
        string.format("ui.inspector.get_focus_widgets: search_input is %s, expected userdata",
            type(w)))
    return { w }
end

return M
