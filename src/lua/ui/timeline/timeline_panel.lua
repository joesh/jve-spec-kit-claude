-- Timeline Panel - Proper widget composition
-- Creates a complete timeline UI with separate header and content widgets

local timeline = require("ui.timeline.timeline")

local M = {}

-- Store reference to inspector view for selection updates
local inspector_view = nil

function M.set_inspector(view)
    inspector_view = view
end

function M.create()
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    local content_layout = qt_constants.LAYOUT.CREATE_HBOX()

    -- Get dimensions from timeline module (single source of truth)
    local ruler_height = timeline.dimensions.ruler_height
    local track_height = timeline.dimensions.track_height
    local track_header_width = timeline.dimensions.track_header_width

    -- Create container for absolutely positioned headers
    local headers_container = qt_constants.WIDGET.CREATE()
    qt_constants.PROPERTIES.SET_STYLE(headers_container, string.format([[
        QWidget {
            min-width: %dpx;
            max-width: %dpx;
        }
    ]], track_header_width, track_header_width))

    -- Add ruler spacer at top with absolute positioning
    local ruler_spacer = qt_constants.WIDGET.CREATE()
    qt_constants.WIDGET.SET_PARENT(ruler_spacer, headers_container)
    qt_constants.PROPERTIES.SET_STYLE(ruler_spacer, "QWidget { background: #2a2a2a; }")
    qt_constants.PROPERTIES.SET_GEOMETRY(ruler_spacer, 0, 0, track_header_width, ruler_height)

    -- Add track name labels with absolute positioning at exact Y coordinates
    local track_names = {"Video 1", "Audio 1", "Video 2"}
    local y = ruler_height

    for i, track_name in ipairs(track_names) do
        local header_label = qt_constants.WIDGET.CREATE_LABEL(track_name)
        qt_constants.WIDGET.SET_PARENT(header_label, headers_container)
        qt_constants.PROPERTIES.SET_STYLE(header_label, [[
            QLabel {
                background: #333333;
                color: #cccccc;
                padding-left: 10px;
            }
        ]])
        qt_constants.PROPERTIES.SET_GEOMETRY(header_label, 0, y, track_header_width, track_height)
        y = y + track_height
    end

    local timeline_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, headers_container)
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, timeline_widget)

    -- Create a wrapper widget for the horizontal layout
    local content_container = qt_constants.WIDGET.CREATE()
    qt_constants.LAYOUT.SET_ON_WIDGET(content_container, content_layout)
    qt_constants.LAYOUT.ADD_WIDGET(layout, content_container)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    timeline.init(timeline_widget, {
        track_header_width = 0
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
