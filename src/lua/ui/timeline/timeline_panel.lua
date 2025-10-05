-- Timeline Panel - Proper widget composition
-- Creates a complete timeline UI with separate header and content widgets

local timeline = require("ui.timeline.timeline")

local M = {}

-- Store reference to inspector view for selection updates
local inspector_view = nil
local project_browser_ref = nil

function M.set_inspector(view)
    inspector_view = view
end

function M.set_project_browser(browser)
    project_browser_ref = browser
    timeline.set_project_browser(browser)
end

function M.create()
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()

    -- Create timeline widget (handles all rendering including headers)
    local timeline_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    qt_constants.LAYOUT.ADD_WIDGET(layout, timeline_widget)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Initialize timeline with normal track header width
    timeline.init(timeline_widget, {
        track_header_width = timeline.dimensions.track_header_width
    })

    -- Wire up selection callback to inspector
    timeline.set_on_selection_changed(function(selected_clips)
        if inspector_view and inspector_view.update_selection then
            inspector_view.update_selection(selected_clips)
        end

        -- Log selection for debugging
        if #selected_clips == 1 then
            print("Selected clip: " .. selected_clips[1].name .. " (" .. selected_clips[1].id .. ")")
        elseif #selected_clips > 1 then
            print("Selected " .. #selected_clips .. " clips")
        else
            print("No clips selected")
        end
    end)

    return container
end

return M
