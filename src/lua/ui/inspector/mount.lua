-- Inspector scaffold builder.
--
-- Called once by init.mount(). Builds the panel tree, pre-builds both
-- schemas' sections, installs the `content_changed` / `project_changed`
-- listeners. After this returns, ui_state is fully wired and
-- update_selection() is meaningful.
--
-- Functions read like an algorithm per rule 2.5 — each step is a named
-- helper below.

local ui_constants        = require("core.ui_constants")
local qt_constants        = require("core.qt_constants")
local qt_signals          = require("core.qt_signals")
local schema              = require("ui.inspector.schema")
local selection_binding   = require("ui.inspector.selection_binding")
local change_listeners    = require("ui.inspector.change_listeners")
local timeline_state      = require("ui.timeline.timeline_state")
local frame_utils         = require("core.frame_utils")
local log                 = require("core.logger").for_area("ui")

local M = {}

local C = ui_constants.COLORS
local F = ui_constants.FONTS

local function style_header_label()
    return string.format([[
        QLabel {
            background: %s;
            color: %s;
            padding: 10px;
            font-size: %s;
            font-weight: bold;
        }
    ]], C.INSPECTOR_HEADER_BG, C.WHITE_TEXT_COLOR, F.HEADER_FONT_SIZE)
end

local function style_content_widget()
    return string.format([[ QWidget { background: %s; } ]], C.INSPECTOR_CONTENT_BG)
end

local function style_error_banner()
    return string.format([[
        QLabel {
            background: %s;
            color: %s;
            padding: 6px 10px;
            font-size: %s;
            border-top: 1px solid %s;
            border-bottom: 1px solid %s;
        }
    ]], C.INSPECTOR_HEADER_BG, C.FIELD_ERROR_BORDER, F.DEFAULT_FONT_SIZE,
        C.FIELD_ERROR_BORDER, C.FIELD_ERROR_BORDER)
end

local function get_frame_rate()
    assert(timeline_state and timeline_state.get_sequence_frame_rate,
        "inspector.mount: timeline_state.get_sequence_frame_rate unavailable")
    local rate = timeline_state.get_sequence_frame_rate()
    assert(rate, "inspector.mount: no sequence frame rate available")
    return rate
end

local function build_mark_summary()
    if not (timeline_state and timeline_state.get_mark_in) then return nil end
    local mark_in  = timeline_state.get_mark_in()
    local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
    local rate = get_frame_rate()
    local in_text  = mark_in  and frame_utils.format_timecode(mark_in, rate)       or "--"
    local out_text = mark_out and frame_utils.format_timecode(mark_out - 1, rate)  or "--"
    local dur_text = "--"
    if mark_in and mark_out and mark_out >= mark_in then
        dur_text = frame_utils.format_timecode(mark_out - mark_in, rate)
    end
    return string.format("In: %s  Out: %s  Dur: %s", in_text, out_text, dur_text)
end

local function build_root_layout(container)
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    assert(layout, "inspector.mount: CREATE_VBOX returned nil")
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)
    qt_constants.LAYOUT.SET_MARGINS(layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_SPACING(layout, 6)
    qt_constants.GEOMETRY.SET_SIZE_POLICY(container, "Preferred", "Expanding")
    return layout
end

local function build_search_row(root_layout)
    local search_input = qt_constants.WIDGET.CREATE_LINE_EDIT("Search properties...")
    assert(search_input, "inspector.mount: CREATE_LINE_EDIT for search returned nil")
    qt_constants.GEOMETRY.SET_SIZE_POLICY(search_input, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(root_layout, search_input)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(root_layout, search_input, 0)
    return search_input
end

local function build_header_label(root_layout)
    local header = qt_constants.WIDGET.CREATE_LABEL("No editable selection")
    assert(header, "inspector.mount: CREATE_LABEL for header returned nil")
    qt_constants.PROPERTIES.SET_STYLE(header, style_header_label())
    qt_constants.GEOMETRY.SET_SIZE_POLICY(header, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(root_layout, header)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(root_layout, header, 0)
    return header
end

local function build_scroll_area(root_layout)
    local scroll_area = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    assert(scroll_area, "inspector.mount: CREATE_SCROLL_AREA returned nil")
    local content_widget = qt_constants.WIDGET.CREATE()
    assert(content_widget, "inspector.mount: CREATE content widget returned nil")
    qt_constants.PROPERTIES.SET_STYLE(content_widget, style_content_widget())
    local content_layout = qt_constants.LAYOUT.CREATE_VBOX()
    assert(content_layout, "inspector.mount: CREATE_VBOX for content returned nil")
    qt_constants.LAYOUT.SET_MARGINS(content_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(content_widget, content_layout)
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(scroll_area, content_widget)
    qt_constants.LAYOUT.ADD_WIDGET(root_layout, scroll_area)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(root_layout, scroll_area, 1)
    return scroll_area, content_widget, content_layout
end

-- Error banner: shown when any field is in parse-error state. Lives in the
-- root layout (below the header, above the scroll area) so it's always
-- visible regardless of scroll position.
local function build_error_banner(root_layout)
    local banner = qt_constants.WIDGET.CREATE_LABEL("")
    assert(banner, "inspector.mount: CREATE_LABEL for error banner returned nil")
    qt_constants.PROPERTIES.SET_STYLE(banner, style_error_banner())
    qt_constants.GEOMETRY.SET_SIZE_POLICY(banner, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(root_layout, banner)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(root_layout, banner, 0)
    qt_constants.DISPLAY.SET_VISIBLE(banner, false)
    return banner
end

-- Bottom bar: holds Apply + Reset buttons, attached to the ROOT layout
-- (outside the scroll area) so buttons stay pinned to the bottom of the
-- Inspector panel regardless of scroll position. Per Joe's UX rule.
--
-- Buttons are Qt native QPushButton — no custom stylesheet. They inherit
-- the application's Qt style (Fusion dark here), giving them the same
-- look as buttons in any Qt dialog. Applying a QSS override forces us to
-- reimplement every state (hover / pressed / disabled / focus ring), and
-- diverges from native dialog conventions.
local function build_bottom_bar(root_layout, ui_state)
    local bar = qt_constants.WIDGET.CREATE()
    assert(bar, "inspector.mount: CREATE for bottom bar returned nil")
    local hbox = qt_constants.LAYOUT.CREATE_HBOX()
    assert(hbox, "inspector.mount: CREATE_HBOX for bottom bar returned nil")
    qt_constants.LAYOUT.SET_ON_WIDGET(bar, hbox)
    qt_constants.LAYOUT.SET_MARGINS(hbox, 8, 6, 8, 8)
    qt_constants.LAYOUT.SET_SPACING(hbox, 8)

    -- Reset on the left, Apply on the right. Spacer between pushes Apply
    -- to the trailing edge, matching macOS dialog conventions.
    local reset = qt_constants.WIDGET.CREATE_BUTTON("Reset")
    assert(reset, "inspector.mount: CREATE_BUTTON(Reset) returned nil")
    qt_constants.LAYOUT.ADD_WIDGET(hbox, reset)

    qt_constants.LAYOUT.ADD_STRETCH(hbox, 1)

    local apply = qt_constants.WIDGET.CREATE_BUTTON("Apply Changes")
    assert(apply, "inspector.mount: CREATE_BUTTON(Apply) returned nil")
    qt_constants.LAYOUT.ADD_WIDGET(hbox, apply)

    qt_constants.LAYOUT.ADD_WIDGET(root_layout, bar)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(root_layout, bar, 0)
    qt_constants.DISPLAY.SET_VISIBLE(bar, false)  -- hidden until multi-edit

    local apply_conn = qt_signals.connect(apply, "clicked", function()
        selection_binding.apply_multi_edit(ui_state)
    end)
    assert(apply_conn, "inspector.mount: failed to connect Apply clicked signal")

    local reset_conn = qt_signals.connect(reset, "clicked", function()
        selection_binding.reset_pending(ui_state)
    end)
    assert(reset_conn, "inspector.mount: failed to connect Reset clicked signal")

    return { container = bar, apply = apply, reset = reset }
end

-- Show/hide the error banner based on whether any field has an error.
-- Called by field_widget's on_error callback.
local function update_error_banner(ui_state, entry, err_message)
    if not ui_state.error_banner then return end
    if err_message then
        ui_state._field_errors = ui_state._field_errors or {}
        ui_state._field_errors[entry.field_key] = err_message
    elseif ui_state._field_errors then
        ui_state._field_errors[entry.field_key] = nil
    end

    -- Surface the first non-nil error. Multiple errors collapse to one
    -- line; user fixes them one at a time.
    local first_key, first_msg
    if ui_state._field_errors then
        for k, msg in pairs(ui_state._field_errors) do
            if msg then first_key, first_msg = k, msg; break end
        end
    end
    if first_msg then
        local label_text = string.format("%s: %s", first_key, first_msg)
        qt_constants.PROPERTIES.SET_TEXT(ui_state.error_banner, label_text)
        qt_constants.DISPLAY.SET_VISIBLE(ui_state.error_banner, true)
    else
        qt_constants.DISPLAY.SET_VISIBLE(ui_state.error_banner, false)
    end
    -- Force layout recalc on the Inspector root. Without this the banner
    -- sometimes fails to visually appear when toggled from hidden→shown
    -- (collapsible_section does the same dance at its own toggle sites).
    -- qt_update_widget is a bound global; absent in headless Lua tests.
    -- luacheck: globals qt_update_widget
    if qt_update_widget and ui_state.root then
        qt_update_widget(ui_state.root)
    end
end

local function prebuild_schemas(ui_state, content_layout)
    local on_commit = function(entry, value)
        if ui_state.mode == "single" then
            selection_binding.commit_single_field(ui_state, entry, value)
        elseif ui_state.mode == "multi_edit" then
            selection_binding._update_apply_button(ui_state)
        end
    end
    local on_error = function(entry, err_message)
        update_error_banner(ui_state, entry, err_message)
    end
    -- Expose on_error on ui_state so commit paths (in selection_binding)
    -- can surface DB-write failures to the error banner — not just parse
    -- failures detected during typing.
    ui_state.on_error = on_error
    local callbacks = {
        frame_rate          = get_frame_rate,
        on_commit           = on_commit,
        on_error            = on_error,
        on_section_toggled  = function(_schema_id, _name, _expanded)
            -- persistent_widget already persists inside schema.lua.
            -- Hook reserved for future analytics.
        end,
    }
    ui_state.schema_views = {
        clip     = schema.build("clip",     content_layout, callbacks),
        sequence = schema.build("sequence", content_layout, callbacks),
    }
    qt_constants.LAYOUT.ADD_STRETCH(content_layout, 1)
end

local function wire_search_filter(ui_state)
    local handler_name = "inspector_search_handler"
    _G[handler_name] = function()
        local text = qt_constants.PROPERTIES.GET_TEXT(ui_state.search_input) or ""
        ui_state.filter_query = text
        if ui_state.active_schema_view then
            schema.apply_filter(ui_state.active_schema_view, text)
        end
    end
    qt_set_line_edit_text_changed_handler(ui_state.search_input, handler_name)  -- luacheck: globals qt_set_line_edit_text_changed_handler
end

--- Build the entire Inspector scaffold inside `container`. Returns the
--- populated `ui_state` table; the caller (init.lua) stores it.
function M.mount(container)
    assert(container, "inspector.mount: container is nil")

    local root_layout = build_root_layout(container)
    local search_input = build_search_row(root_layout)
    local header_label = build_header_label(root_layout)
    local error_banner = build_error_banner(root_layout)
    local scroll_area, content_widget, content_layout = build_scroll_area(root_layout)

    local ui_state = {
        root              = container,
        root_layout       = root_layout,
        search_input      = search_input,
        header_label      = header_label,
        error_banner      = error_banner,
        scroll_area       = scroll_area,
        content_widget    = content_widget,
        content_layout    = content_layout,
        apply_button      = nil,
        reset_button      = nil,
        bottom_bar        = nil,
        schema_views      = nil,
        schema            = schema,
        active_schema_view = nil,
        active_schema_id  = nil,
        active_inspectables = {},
        mode              = "empty",
        filter_query      = "",
        prev_item_ids     = {},
        prev_schemas_present = {},
        build_mark_summary = build_mark_summary,
        base_header       = nil,
        _field_errors     = {},
    }

    -- Schemas go into the scroll area's content layout.
    prebuild_schemas(ui_state, content_layout)

    -- Bottom bar (Apply + Reset) lives OUTSIDE the scroll area, pinned to
    -- the bottom of the panel regardless of scroll position.
    local bottom = build_bottom_bar(root_layout, ui_state)
    ui_state.bottom_bar   = bottom.container
    ui_state.apply_button = bottom.apply
    ui_state.reset_button = bottom.reset

    wire_search_filter(ui_state)

    ui_state._listener_disposers = change_listeners.install(ui_state)

    qt_constants.DISPLAY.SHOW(content_widget)

    log.event("inspector.mount: scaffold built; schemas=%d",
        (ui_state.schema_views.clip and 1 or 0) + (ui_state.schema_views.sequence and 1 or 0))

    return ui_state
end

return M
