-- Timeline Panel - Multi-view timeline architecture
-- Assembles ruler, video view, audio view, and scrollbar

local timeline_state = require("ui.timeline.timeline_state")
local timeline_view = require("ui.timeline.timeline_view")
local timeline_ruler = require("ui.timeline.timeline_ruler")
local timeline_scrollbar = require("ui.timeline.timeline_scrollbar")
local ui_constants = require("core.ui_constants")
local selection_hub = require("ui.selection_hub")
local database = require("core.database")
local command_manager = require("core.command_manager")
local inspectable_factory = require("inspectable")
local profile_scope = require("core.profile_scope")
local logger = require("core.logger")
local timecode = require("core.timecode")
local timecode_input = require("core.timecode_input")

-- luacheck: globals qt_line_edit_select_all

local M = {}

-- Constants
local DEFAULT_TRACK_HEIGHT = timeline_state.dimensions.default_track_height or ui_constants.TIMELINE.TRACK_HEIGHT or 50
local MIN_TRACK_HEIGHT = 30
local HEADER_BORDER_THICKNESS = 2
local MIN_HEADER_HEIGHT = math.max(12, MIN_TRACK_HEIGHT - HEADER_BORDER_THICKNESS)

local function clamp_track_height(height)
    return math.max(MIN_TRACK_HEIGHT, height or DEFAULT_TRACK_HEIGHT)
end

local function content_to_header(track_height)
    local clamped = clamp_track_height(track_height)
    return math.max(MIN_HEADER_HEIGHT, clamped - HEADER_BORDER_THICKNESS)
end

local function header_to_content(header_height)
    local clamped_header = math.max(MIN_HEADER_HEIGHT, header_height or content_to_header(DEFAULT_TRACK_HEIGHT))
    return clamp_track_height(clamped_header + HEADER_BORDER_THICKNESS)
end

-- Store references
local state = nil
local video_view_ref = nil
local audio_view_ref = nil
local tab_order = {}
local tab_bar_tabs_layout = nil
local tab_bar_tabs_container = nil
local recycle_bin = qt_constants.WIDGET.CREATE()
if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
    qt_constants.DISPLAY.SET_VISIBLE(recycle_bin, false)
end

local timecode_entry = {
    widget = nil,
    line_edit = nil,
    has_focus = false,
    last_text = nil,
    focus_handler_name = nil,
    editing_finished_handler_name = nil,
    listener_token = nil,
}

local colors = ui_constants.COLORS or {}
local selection_color = colors.SELECTION_BORDER_COLOR or "#e64b3d"
local inactive_text_color = colors.GENERAL_LABEL_COLOR or "#9a9a9a"
local active_text_color = selection_color
local hover_text_color = colors.WHITE_TEXT_COLOR or "#ffffff"

local function build_tab_button_style(text_color, border_color, font_weight)
    return string.format([[
        QPushButton {
            background: transparent;
            color: %s;
            border: none;
            border-bottom: 2px solid %s;
            padding: 4px 10px;
            font-weight: %s;
        }
        QPushButton:hover {
            color: %s;
        }
    ]], text_color, border_color, font_weight, hover_text_color)
end

local function build_close_button_style(text_color)
    return string.format([[
        QPushButton {
            background: transparent;
            color: %s;
            border: none;
            padding: 0 6px;
        }
        QPushButton:hover {
            color: %s;
        }
    ]], text_color, selection_color)
end
local open_tabs = {}
local tab_handler_seq = 0
local tab_command_listener = nil
local ensure_tab_for_sequence

local function register_global_handler(name, callback)
    _G[name] = function(...)
        return callback(...)
    end
    return name
end

local function clear_global_handler(name)
    if name and _G[name] ~= nil then
        _G[name] = nil
    end
end

local function get_sequence_frame_rate_for_timecode()
    local rate = state and state.get_sequence_frame_rate and state.get_sequence_frame_rate() or nil
    assert(rate and rate.fps_numerator and rate.fps_denominator, "timeline_panel: missing sequence fps metadata")
    return rate
end

local function get_formatted_playhead_timecode()
    local rate = get_sequence_frame_rate_for_timecode()
    local playhead = state.get_playhead_position()
    return timecode.to_string(playhead, rate)
end

local function set_timecode_text_if_changed(text)
    if not timecode_entry.line_edit then
        return
    end
    if timecode_entry.last_text == text then
        return
    end
    timecode_entry.last_text = text
    qt_constants.PROPERTIES.SET_TEXT(timecode_entry.line_edit, text)
end

local function refresh_timecode_display()
    if timecode_entry.has_focus then
        return
    end
    set_timecode_text_if_changed(get_formatted_playhead_timecode())
end

local function build_timecode_field_stylesheet()
    local field_bg = colors.FIELD_BACKGROUND_COLOR or "#2a2a2a"
    local field_border = colors.FIELD_BORDER_COLOR or "#444444"
    local field_text = colors.FIELD_TEXT_COLOR or "#cccccc"
    local focus_bg = colors.FIELD_FOCUS_BACKGROUND_COLOR or field_bg
    local focus_border = colors.FOCUS_BORDER_COLOR or selection_color
    local font_size = (ui_constants.FONTS and ui_constants.FONTS.HEADER_FONT_SIZE) or "14px"
    local selection_bg = selection_color
    local selection_text = colors.WHITE_TEXT_COLOR or "#ffffff"

    return string.format([[
        QLineEdit {
            background: %s;
            color: %s;
            border: 1px solid %s;
            padding: 2px 6px;
            font-size: %s;
            qproperty-alignment: AlignCenter;
            selection-background-color: %s;
            selection-color: %s;
        }
        QLineEdit:focus {
            background: %s;
            border: 1px solid %s;
        }
    ]], field_bg, field_text, field_border, font_size, selection_bg, selection_text, focus_bg, focus_border)
end

local function focus_timecode_entry()
    if not timecode_entry.line_edit then
        return false
    end
    qt_set_focus(timecode_entry.line_edit)
    assert(qt_line_edit_select_all, "Missing Qt binding: qt_line_edit_select_all")
    qt_line_edit_select_all(timecode_entry.line_edit)
    return true
end

local function focus_timeline_view()
    if M.video_widget then
        qt_set_focus(M.video_widget)
        return true
    end
    if M.audio_widget then
        qt_set_focus(M.audio_widget)
        return true
    end
    return false
end

local function apply_timecode_entry_text()
    if not timecode_entry.line_edit then
        return false
    end
    local rate = get_sequence_frame_rate_for_timecode()
    local current = state.get_playhead_position()
    local raw = qt_constants.PROPERTIES.GET_TEXT(timecode_entry.line_edit)
    local parsed, err = timecode_input.parse(raw, rate, {base_time = current})
    if not parsed then
        logger.warn("timeline_panel", string.format("Invalid timecode input: %s (%s)", tostring(raw), tostring(err)))
        set_timecode_text_if_changed(get_formatted_playhead_timecode())
        return false
    end
    state.set_playhead_position(parsed)
    set_timecode_text_if_changed(get_formatted_playhead_timecode())
    return true
end

local function install_timecode_entry_handlers()
    if not timecode_entry.line_edit then
        return
    end

    clear_global_handler(timecode_entry.focus_handler_name)
    clear_global_handler(timecode_entry.editing_finished_handler_name)

    timecode_entry.focus_handler_name = register_global_handler("__timeline_timecode_focus_handler", function(event)
        local focus_in = event and event.focus_in
        timecode_entry.has_focus = focus_in and true or false
        if not focus_in then
            refresh_timecode_display()
        end
    end)
    qt_set_focus_handler(timecode_entry.line_edit, timecode_entry.focus_handler_name)

    timecode_entry.editing_finished_handler_name = register_global_handler("__timeline_timecode_editing_finished", function()
        local ok = apply_timecode_entry_text()
        if ok then
            focus_timeline_view()
        else
            focus_timecode_entry()
        end
    end)
    qt_set_line_edit_editing_finished_handler(timecode_entry.line_edit, timecode_entry.editing_finished_handler_name)
end

local function create_timecode_header()
    local wrapper = qt_constants.WIDGET.CREATE()
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(wrapper, timeline_ruler.RULER_HEIGHT)
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(wrapper, timeline_ruler.RULER_HEIGHT)
    qt_constants.PROPERTIES.SET_MIN_WIDTH(wrapper, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(wrapper, timeline_state.dimensions.track_header_width)

    local layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 6, 4, 6, 4)

    local line_edit = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    qt_set_focus_policy(line_edit, "StrongFocus")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(line_edit, "Expanding", "Fixed")
    qt_constants.PROPERTIES.SET_STYLE(line_edit, build_timecode_field_stylesheet())

    qt_constants.LAYOUT.ADD_WIDGET(layout, line_edit)
    qt_constants.LAYOUT.SET_ON_WIDGET(wrapper, layout)

    timecode_entry.widget = wrapper
    timecode_entry.line_edit = line_edit
    timecode_entry.last_text = nil
    timecode_entry.has_focus = false

    install_timecode_entry_handlers()
    refresh_timecode_display()

    if timecode_entry.listener_token and state and state.remove_listener then
        state.remove_listener(timecode_entry.listener_token)
        timecode_entry.listener_token = nil
    end
    if state and state.add_listener then
        timecode_entry.listener_token = state.add_listener(function()
            refresh_timecode_display()
        end)
    end

    return wrapper
end

local function normalize_timeline_selection(clips)
    local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
    local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
    assert(project_id and project_id ~= "", "timeline_panel.normalize_timeline_selection: missing active project_id")
    assert(sequence_id and sequence_id ~= "", "timeline_panel.normalize_timeline_selection: missing active sequence_id")

    if not clips or #clips == 0 then
        local ok, inspectable = pcall(inspectable_factory.sequence, {
            sequence_id = sequence_id,
            project_id = project_id
        })
        if ok and inspectable then
            return {{
                item_type = "timeline_sequence",
                sequence_id = sequence_id,
                inspectable = inspectable,
                schema = inspectable:get_schema_id(),
                display_name = inspectable:get("name") or "Timeline",
                project_id = project_id
            }}
        end
        return {}
    end

    local normalized = {}
    for _, clip in ipairs(clips) do
        if clip and clip.id then
            local ok, inspectable = pcall(inspectable_factory.clip, {
                clip_id = clip.id,
                project_id = project_id,
                sequence_id = sequence_id,
                clip = clip
            })
            if ok and inspectable then
                table.insert(normalized, {
                    item_type = "timeline_clip",
                    clip = clip,
                    inspectable = inspectable,
                    schema = inspectable:get_schema_id(),
                    display_name = clip.label or clip.name or clip.id,
                    project_id = project_id,
                    sequence_id = sequence_id
                })
            end
        end
    end
    return normalized
end

local function apply_tab_style(tab, is_active)
    if not tab or not tab.button or not qt_constants.PROPERTIES.SET_STYLE then
        return
    end
    local text_color = is_active and active_text_color or inactive_text_color
    local border_color = is_active and selection_color or "transparent"
    local font_weight = is_active and "bold" or "normal"
    qt_constants.PROPERTIES.SET_STYLE(tab.button, build_tab_button_style(text_color, border_color, font_weight))
    if tab.close_button and qt_constants.PROPERTIES.SET_STYLE then
        qt_constants.PROPERTIES.SET_STYLE(tab.close_button, build_close_button_style(text_color))
    end
end
function M.set_inspector(_)
    -- Inspector updates are routed through selection_hub in layout wiring.
end

function M.get_state()
    return timeline_state  -- Return the module, not the local state variable
end

function M.focus_timecode_entry()
    return focus_timecode_entry()
end

function M.focus_timeline_view()
    return focus_timeline_view()
end

local function get_sequence_display_name(sequence_id)
    if not sequence_id or sequence_id == "" then
        return "Untitled Sequence"
    end
    local record = database.load_sequence_record(sequence_id)
    if record and record.name and record.name ~= "" then
        return record.name
    end
    return sequence_id
end

local function register_tab_handler(callback)
    tab_handler_seq = tab_handler_seq + 1
    local name = "__timeline_tab_handler_" .. tostring(tab_handler_seq)
    _G[name] = function(...)
        callback(...)
    end
    return name
end

local function update_tab_styles(active_sequence_id)
    for id, tab in pairs(open_tabs) do
        apply_tab_style(tab, id == active_sequence_id)
    end
end

local function remove_from_tab_order(sequence_id)
    for index = #tab_order, 1, -1 do
        if tab_order[index] == sequence_id then
            table.remove(tab_order, index)
            break
        end
    end
end

local function close_tab(sequence_id)
    local tab = open_tabs[sequence_id]
    if not tab then
        return
    end

    if qt_constants.WIDGET.SET_PARENT then
        qt_constants.WIDGET.SET_PARENT(tab.container, recycle_bin)
    end
    if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
        qt_constants.DISPLAY.SET_VISIBLE(tab.container, false)
    end

    if tab.handler then
        _G[tab.handler] = nil
    end
    if tab.close_handler then
        _G[tab.close_handler] = nil
    end

    open_tabs[sequence_id] = nil
    remove_from_tab_order(sequence_id)

    local current_sequence = state.get_sequence_id and state.get_sequence_id()
    if current_sequence == sequence_id then
        local next_id = tab_order[#tab_order] or tab_order[1]
        if next_id then
            M.load_sequence(next_id)
        else
            local project_id = state.get_project_id and state.get_project_id() or nil
            if not project_id or project_id == "" then
                return
            end
            local sequences = database.load_sequences(project_id) or {}
            local fallback_id = sequences[1] and sequences[1].id or nil
            if fallback_id and fallback_id ~= "" then
                ensure_tab_for_sequence(fallback_id)
                M.load_sequence(fallback_id)
            end
        end
    else
        update_tab_styles(current_sequence)
    end
end

ensure_tab_for_sequence = function(sequence_id)
    if not tab_bar_tabs_layout or not sequence_id or sequence_id == "" then
        return
    end

    local display_name = get_sequence_display_name(sequence_id)
    local existing = open_tabs[sequence_id]
    if existing then
        if display_name ~= existing.name then
            qt_constants.PROPERTIES.SET_TEXT(existing.button, display_name)
            existing.name = display_name
        end
        return
    end

    local container = qt_constants.WIDGET.CREATE()
    local container_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(container_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(container_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, container_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Fixed", "Fixed")

    local text_button = qt_constants.WIDGET.CREATE_BUTTON(display_name)
    qt_constants.PROPERTIES.SET_STYLE(text_button, build_tab_button_style(inactive_text_color, "transparent", "normal"))
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(text_button, "Fixed", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(container_layout, text_button)

    local close_button = qt_constants.WIDGET.CREATE_BUTTON("×")
    qt_constants.PROPERTIES.SET_STYLE(close_button, build_close_button_style(inactive_text_color))
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(close_button, "Fixed", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(container_layout, close_button)

    local handler_name = register_tab_handler(function()
        if state and state.get_sequence_id then
            local current = state.get_sequence_id()
            if current ~= sequence_id then
                M.load_sequence(sequence_id)
            end
        end
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(text_button, handler_name)

    local close_handler_name = register_tab_handler(function()
        close_tab(sequence_id)
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(close_button, close_handler_name)

    qt_constants.LAYOUT.ADD_WIDGET(tab_bar_tabs_layout, container)

    open_tabs[sequence_id] = {
        container = container,
        button = text_button,
        close_button = close_button,
        name = display_name,
        handler = handler_name,
        close_handler = close_handler_name
    }
    table.insert(tab_order, sequence_id)
end

local function handle_tab_command_event(event)
    if not event or not event.event then
        return
    end

    local command = event.command
    if not command or not command.type then
        return
    end

    if command.type == "ImportFCP7XML" then
        local created_sequence_ids = nil
        if command.get_parameter then
            created_sequence_ids = command:get_parameter("created_sequence_ids")
        elseif command.parameters then
            created_sequence_ids = command.parameters.created_sequence_ids
        end

        if type(created_sequence_ids) ~= "table" then
            return
        end

        if event.event == "undo" then
            local active = state.get_sequence_id and state.get_sequence_id() or nil
            local active_deleted = false
            for _, sequence_id in ipairs(created_sequence_ids) do
                if open_tabs[sequence_id] then
                    close_tab(sequence_id)
                end
                if active and active == sequence_id then
                    active_deleted = true
                end
            end

            if active_deleted then
                local fallback = nil
                if #tab_order > 0 then
                    fallback = tab_order[#tab_order]
                end
                if fallback and fallback ~= "" then
                    M.load_sequence(fallback)
                else
                    local project_id = state.get_project_id and state.get_project_id() or nil
                    if project_id and project_id ~= "" then
                        local sequences = database.load_sequences(project_id) or {}
                        local fallback_id = sequences[1] and sequences[1].id or nil
                        if fallback_id and fallback_id ~= "" then
                            M.load_sequence(fallback_id)
                        end
                    end
                end
            end
        elseif event.event == "execute" or event.event == "redo" then
            local seq_id = created_sequence_ids[1]
            if seq_id then
                M.load_sequence(seq_id)
            end
        end

        return
    end

    if event.event ~= "execute" then
        return
    end

    if command.type ~= "RenameItem" then
        return
    end

    local get_param = command.get_parameter
    local target_type = nil
    local target_id = nil
    local new_name = nil
    if type(get_param) == "function" then
        target_type = command:get_parameter("target_type")
        target_id = command:get_parameter("target_id")
        new_name = command:get_parameter("new_name")
    elseif command.parameters then
        target_type = command.parameters.target_type
        target_id = command.parameters.target_id
        new_name = command.parameters.new_name
    end

    if target_type ~= "sequence" or not target_id or new_name == nil then
        return
    end

    local tab = open_tabs[target_id]
    if tab and tab.button and new_name ~= "" then
        qt_constants.PROPERTIES.SET_TEXT(tab.button, new_name)
        tab.name = new_name
    end
end

local function build_track_header_stylesheet(background_color)
    return string.format([[
        QLabel {
            background: %s;
            color: #cccccc;
            padding-left: 10px;
            border-left: 1px solid #222232;
            border-right: 1px solid #222232;
            border-top: 0px;
            border-bottom: 0px;
        }
    ]], background_color or "#111111")
end

-- Helper function to create video headers with splitters
local function create_video_headers()
    local video_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local video_tracks = state.get_video_tracks()

    -- Debug: Video tracks from state
    -- for i, track in ipairs(video_tracks) do
    --     print(string.format("  video_tracks[%d] = %s (id=%s)", i, track.name, track.id))
    -- end

    local video_headers = {}
    local current_track = nil
    local handler_name = "video_splitter_event_" .. tostring(video_splitter):gsub("[^%w]", "_")

    -- Add stretch widget at top to push tracks down (V1 is anchor at bottom)
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(video_splitter, stretch_widget)

    -- Add tracks in REVERSE order (V3, V2, V1)
    local video_header_heights = {}
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        local header = qt_constants.WIDGET.CREATE_LABEL(track.name)
        local track_height = clamp_track_height(state.get_track_height and state.get_track_height(track.id) or DEFAULT_TRACK_HEIGHT)
        local header_height = content_to_header(track_height)

        qt_constants.PROPERTIES.SET_STYLE(header, build_track_header_stylesheet(timeline_state.colors.video_track_header))
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, header_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, header_height)

        qt_constants.LAYOUT.ADD_WIDGET(video_splitter, header)
        video_headers[i] = header
        video_header_heights[i] = header_height
    end

    -- Install handlers: Handle N resizes Track N
    -- Physical layout (top to bottom): Stretch → V3 → V2 → V1 → [MIDLINE ANCHOR]
    -- Tracks grow upward from midline anchor
    --
    -- CRITICAL DISCOVERY: Qt splitter handle indices don't start at 0!
    -- Working indices are 1, 2, 3 (empirically discovered by trying handle 0 which didn't fire)
    --
    -- Qt handle mapping (empirically discovered):
    --   qt_handle 1: between V3 and V2 → Handle 3 → resizes V3 (track 3)
    --   qt_handle 2: between V2 and V1 → Handle 2 → resizes V2 (track 2)
    --   qt_handle 3: below V1 → Handle 1 → resizes V1 (track 1)
    --
    -- We renumber from bottom to top: handle_num = (#video_tracks + 1) - qt_handle_index
    logger.debug("timeline_panel", string.format("Installing video handles for %d tracks", #video_tracks))
    logger.debug("timeline_panel", "Checking which Qt handles exist...")
    for test_index = 0, #video_tracks + 1 do
        local test_handle = qt_get_splitter_handle(video_splitter, test_index)
        logger.debug("timeline_panel", string.format("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil"))
    end

    for qt_handle_index = 1, #video_tracks do
        local handle = qt_get_splitter_handle(video_splitter, qt_handle_index)
        logger.debug("timeline_panel", string.format("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle)))
        if handle then
            -- Renumber from bottom to top: qt_handle 1→Handle 3, qt_handle 2→Handle 2, qt_handle 3→Handle 1
            local handle_num = (#video_tracks + 1) - qt_handle_index

            -- Handle N resizes track N
            local track_num = handle_num
            local track_id = video_tracks[track_num].id
            local track_name = video_tracks[track_num].name

            -- Qt positions: Stretch=0, V3=1, V2=2, V1=3
            -- Handle N is between widget (N-1) and widget N
            local qt_pos_above = qt_handle_index - 1  -- Widget above the handle
            local qt_pos_below = qt_handle_index      -- Widget below the handle (what we want to resize)

            logger.debug("timeline_panel", string.format("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_below))

            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index
            logger.debug("timeline_panel", string.format("    Handler name: %s", this_handler_name))

            -- Create local copies for the closure to capture
            local captured_handle_num = handle_num
            local captured_track_num = track_num
            local captured_track_id = track_id
            local captured_track_name = track_name
            local captured_qt_pos_above = qt_pos_above
            local captured_qt_pos_below = qt_pos_below

            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], MIN_HEADER_HEIGHT)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], 16777215)
                elseif event_type == "release" then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(video_splitter)
                    local new_height = sizes[captured_qt_pos_below + 1]  -- Lua arrays are 1-indexed

                    logger.debug("timeline_panel", string.format("Handle %d → %s = %dpx", captured_handle_num, captured_track_name, new_height))

                    -- Lock at exact height to prevent unwanted resizing during main boundary drag
                    local clamped_header = math.max(MIN_HEADER_HEIGHT, new_height)
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], clamped_header)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], clamped_header)
                    -- Reset: stretch widget absorbs space, tracks fixed
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, captured_qt_pos_below, 0)

                    local new_track_height = header_to_content(clamped_header)
                    state.set_track_height(captured_track_id, new_track_height)

                    -- Update splitter minimum height to accommodate new track sizes
                    local total_height = 0
                    for _, track in ipairs(state.get_video_tracks()) do
                        total_height = total_height + content_to_header(state.get_track_height(track.id))
                    end
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_splitter, total_height)
                    logger.debug("timeline_panel", string.format("  Updated video_splitter min height to %dpx", total_height))
                end
            end
            logger.debug("timeline_panel", string.format("    Calling qt_set_widget_click_handler for %s", this_handler_name))
            qt_set_widget_click_handler(handle, this_handler_name)
            logger.debug("timeline_panel", "    Handler installed successfully")
        end
    end

    -- Set initial sizes: stretch widget gets 0, tracks get their natural height
    local initial_sizes = {0}  -- Stretch widget starts at 0
    for i = 1, #video_tracks do
        local source_index = #video_tracks - i + 1
        local header_height = video_header_heights[source_index] or content_to_header(DEFAULT_TRACK_HEIGHT)
        table.insert(initial_sizes, header_height)
    end
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(video_splitter, initial_sizes)

    -- Set stretch factors: stretch widget absorbs space, tracks stay fixed
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)  -- Stretch widget
    for i = 1, #video_tracks do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, i, 0)  -- Tracks stay fixed
    end

    -- Register splitterMoved handler to update minimum height dynamically
    _G["video_splitter_moved"] = function(pos, index)
        logger.debug("timeline_panel", string.format("video_splitter_moved fired: pos=%d, index=%d", pos, index))
        -- Calculate total height needed for all video tracks
        local total_height = 0
        for _, track in ipairs(state.get_video_tracks()) do
            total_height = total_height + content_to_header(state.get_track_height(track.id))
        end
        logger.debug("timeline_panel", string.format("  Setting video_splitter min height to %dpx", total_height))
        -- Set splitter minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_splitter, total_height)
    end
    logger.debug("timeline_panel", "Registering video_splitter_moved handler...")
    qt_set_splitter_moved_handler(video_splitter, "video_splitter_moved")
    logger.debug("timeline_panel", "  Handler registered")

    -- Hide the handle above V3 (between stretch widget and V3) - handle index 0
    qt_hide_splitter_handle(video_splitter, 0)

    return video_splitter, video_headers
end

-- Helper function to create audio headers with splitters
local function create_audio_headers()
    local audio_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local audio_tracks = state.get_audio_tracks()

    local audio_headers = {}
    local current_track = nil
    local handler_name = "audio_splitter_event_" .. tostring(audio_splitter):gsub("[^%w]", "_")

    -- Add tracks in normal order (A1, A2, A3)
    local audio_header_heights = {}
    for i, track in ipairs(audio_tracks) do
        local header = qt_constants.WIDGET.CREATE_LABEL(track.name)
        local track_height = clamp_track_height(state.get_track_height and state.get_track_height(track.id) or DEFAULT_TRACK_HEIGHT)
        local header_height = content_to_header(track_height)

        qt_constants.PROPERTIES.SET_STYLE(header, build_track_header_stylesheet(timeline_state.colors.audio_track_header))
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, header_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, header_height)

        qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, header)
        audio_headers[i] = header
        audio_header_heights[i] = header_height
    end

    -- Add stretch widget at bottom to push tracks up (A1 is anchor at top)
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, stretch_widget)

    -- Install handlers: Handle N resizes Track N
    -- Physical layout (top to bottom): A1 → A2 → A3 → Stretch
    -- A1 is anchor at top, tracks grow downward
    --
    -- CRITICAL DISCOVERY: Qt splitter handle indices don't start at 0!
    -- Working indices are 1, 2, 3 (just like video tracks)
    --
    -- Qt handle mapping - NO RENUMBERING NEEDED (both go 1-3 top to bottom):
    --   qt_handle 1: between A1 and A2 → Handle 1 → resizes A1 (track 1)
    --   qt_handle 2: between A2 and A3 → Handle 2 → resizes A2 (track 2)
    --   qt_handle 3: between A3 and Stretch → Handle 3 → resizes A3 (track 3)
    logger.debug("timeline_panel", string.format("Installing audio handles for %d tracks", #audio_tracks))
    logger.debug("timeline_panel", "Checking which Qt handles exist...")
    for test_index = 0, #audio_tracks + 1 do
        local test_handle = qt_get_splitter_handle(audio_splitter, test_index)
        logger.debug("timeline_panel", string.format("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil"))
    end

    for qt_handle_index = 1, #audio_tracks do
        local handle = qt_get_splitter_handle(audio_splitter, qt_handle_index)
        logger.debug("timeline_panel", string.format("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle)))
        if handle then
            -- Direct mapping: qt_handle N → Handle N → resizes Track N (no renumbering!)
            local handle_num = qt_handle_index
            local track_num = qt_handle_index  -- Direct 1:1 mapping
            local track_id = audio_tracks[track_num].id
            local track_name = audio_tracks[track_num].name

            -- Qt positions: A1=0, A2=1, A3=2, Stretch=3
            -- Each handle resizes the widget ABOVE it
            local qt_pos_to_resize = qt_handle_index - 1

            logger.debug("timeline_panel", string.format("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_to_resize))

            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index

            -- Create local copies for the closure to capture
            local captured_handle_num = handle_num
            local captured_track_num = track_num
            local captured_track_id = track_id
            local captured_track_name = track_name
            local captured_qt_pos_to_resize = qt_pos_to_resize

            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], MIN_HEADER_HEIGHT)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], 16777215)
                elseif event_type == "release" then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(audio_splitter)
                    local new_height = sizes[captured_qt_pos_to_resize + 1]  -- Lua arrays are 1-indexed

                    -- Lock at exact height to prevent unwanted resizing during main boundary drag
                    local clamped_header = math.max(MIN_HEADER_HEIGHT, new_height)
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], clamped_header)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], clamped_header)
                    -- Reset stretch factors: stretch widget absorbs, tracks fixed
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Stretch widget
                    for i = 0, #audio_tracks - 1 do
                        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- Tracks fixed
                    end

                    local new_track_height = header_to_content(clamped_header)
                    state.set_track_height(captured_track_id, new_track_height)
                end
            end
            logger.debug("timeline_panel", string.format("    Calling qt_set_widget_click_handler for %s", this_handler_name))
            qt_set_widget_click_handler(handle, this_handler_name)
            logger.debug("timeline_panel", "    Handler installed successfully")
        end
    end

    -- Set initial sizes: tracks get their natural height, stretch widget gets 0
    local initial_sizes = {}
    for i = 1, #audio_tracks do
        local header_height = audio_header_heights[i] or content_to_header(DEFAULT_TRACK_HEIGHT)
        table.insert(initial_sizes, header_height)
    end
    table.insert(initial_sizes, 0)  -- Stretch widget starts at 0
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(audio_splitter, initial_sizes)

    -- Set stretch factors: stretch widget absorbs space, tracks stay fixed
    for i = 0, #audio_tracks - 1 do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- Tracks stay fixed
    end
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Stretch widget

    -- Register splitterMoved handler to update minimum height dynamically
    _G["audio_splitter_moved"] = function(pos, index)
        -- Calculate total height needed for all audio tracks
        local total_height = 0
        for _, track in ipairs(state.get_audio_tracks()) do
            total_height = total_height + content_to_header(state.get_track_height(track.id))
        end
        -- Set splitter minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_splitter, total_height)
    end
    qt_set_splitter_moved_handler(audio_splitter, "audio_splitter_moved")

    -- Hide the handle below A3 (between A3 and stretch widget) - last handle index
    qt_hide_splitter_handle(audio_splitter, #audio_tracks)

    return audio_splitter, audio_headers
end

-- Helper function to create headers column with video/audio sections
local function create_headers_column()
    -- Wrapper VBox to add ruler-height spacer at top
    local headers_wrapper = qt_constants.WIDGET.CREATE()
    local headers_wrapper_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(headers_wrapper_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(headers_wrapper_layout, 0, 0, 0, 0)

    -- Top left header area aligned with the ruler; contains the timecode entry field.
    qt_constants.LAYOUT.ADD_WIDGET(headers_wrapper_layout, create_timecode_header())

    -- Main vertical splitter between video and audio header sections
    local headers_main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

    -- Video headers section with scroll area
    local video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local video_splitter, video_headers = create_video_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(video_scroll, video_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_scroll, "Fixed", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)
    qt_set_scroll_area_anchor_bottom(video_scroll, true)  -- V1 stays visible when shrinking

    -- Audio headers section with scroll area
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local audio_splitter, audio_headers = create_audio_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Fixed", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)

    -- Add both sections to main splitter
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, audio_scroll)

    -- Set initial 50/50 split (will be adjusted dynamically by splitterMoved handlers)
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, {1, 1})

    -- Add splitter to wrapper layout
    qt_constants.LAYOUT.ADD_WIDGET(headers_wrapper_layout, headers_main_splitter)
    qt_set_layout_stretch_factor(headers_wrapper_layout, headers_main_splitter, 1)

    -- Set layout on wrapper
    qt_constants.LAYOUT.SET_ON_WIDGET(headers_wrapper, headers_wrapper_layout)

    -- Constrain wrapper width to match scroll area widths
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(headers_wrapper, "Fixed", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(headers_wrapper, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(headers_wrapper, timeline_state.dimensions.track_header_width)

    -- Return wrapper widget, main splitter, and scroll areas for synchronization
    return headers_wrapper, headers_main_splitter, video_scroll, audio_scroll
end

function M.create(opts)
    logger.debug("timeline_panel", "Creating multi-view timeline panel...")

    -- Initialize state
    state = timeline_state
    local sequence_id = nil
    local project_id = nil
    if type(opts) == "table" then
        sequence_id = opts.sequence_id
        project_id = opts.project_id
    elseif type(opts) == "string" then
        sequence_id = opts
    end
    assert(sequence_id and sequence_id ~= "", "timeline_panel.create: sequence_id is required")
    assert(project_id and project_id ~= "", "timeline_panel.create: project_id is required")
    state.init(sequence_id, project_id)

    -- Set up selection callback for inspector
    state.set_on_selection_changed(function(selected_clips)
        selection_hub.update_selection("timeline", normalize_timeline_selection(selected_clips))
    end)
    local initial_selection = state.get_selected_clips and state.get_selected_clips() or {}
    selection_hub.update_selection("timeline", normalize_timeline_selection(initial_selection))

    local last_mark_signature = nil
    if #initial_selection == 0 then
        local mark_in = state.get_mark_in and state.get_mark_in() or nil
        local mark_out = state.get_mark_out and state.get_mark_out() or nil
        last_mark_signature = tostring(mark_in) .. ":" .. tostring(mark_out)
    end
    state.add_listener(profile_scope.wrap("timeline_panel.selection_listener", function()
        local selected = state.get_selected_clips and state.get_selected_clips() or {}

        -- Re-broadcast selection when only the timeline itself is selected and marks change.
        if #selected == 0 then
            local mark_in = state.get_mark_in and state.get_mark_in() or nil
            local mark_out = state.get_mark_out and state.get_mark_out() or nil
            local signature = tostring(mark_in) .. ":" .. tostring(mark_out)
            if signature ~= last_mark_signature then
                last_mark_signature = signature
                selection_hub.update_selection("timeline", normalize_timeline_selection(selected))
            end
        else
            last_mark_signature = nil
        end
    end))

    -- Main container
    local container = qt_constants.WIDGET.CREATE()
    local main_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(main_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(main_layout, 0, 0, 0, 0)

    -- Tab bar for open sequences
    local tab_bar_widget = qt_constants.WIDGET.CREATE()
    local tab_bar_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(tab_bar_layout, 6)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(tab_bar_layout, 12, 6, 12, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(tab_bar_widget, tab_bar_layout)
    qt_constants.PROPERTIES.SET_STYLE(tab_bar_widget, string.format(
        [[QWidget { background: %s; border-bottom: 1px solid %s; }]],
        colors.PANEL_BACKGROUND_COLOR or "#1f1f1f",
        colors.SCROLL_BORDER_COLOR or "#111111"
    ))
    tab_bar_tabs_container = qt_constants.WIDGET.CREATE()
    tab_bar_tabs_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(tab_bar_tabs_layout, 4)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(tab_bar_tabs_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(tab_bar_tabs_container, tab_bar_tabs_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_tabs_container, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(tab_bar_layout, tab_bar_tabs_container)
    qt_constants.LAYOUT.ADD_STRETCH(tab_bar_layout, 1)

    -- Create main horizontal splitter: Headers Column | Timeline Area Column
    local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

    -- LEFT SIDE: Headers column (all headers stacked vertically)
    local headers_column, headers_main_splitter, header_video_scroll, header_audio_scroll = create_headers_column()
    M.headers_main_splitter = headers_main_splitter
    M.header_video_scroll = header_video_scroll
    M.header_audio_scroll = header_audio_scroll

    -- RIGHT SIDE: Timeline area column
    local timeline_area = qt_constants.WIDGET.CREATE()
    local timeline_area_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(timeline_area_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(timeline_area_layout, 0, 0, 0, 0)

    -- Ruler widget (fixed height)
    local ruler_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local ruler = timeline_ruler.create(ruler_widget, state)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_widget, "Expanding", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Set 32px height
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Lock to 32px
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, ruler_widget)
    M.ruler_widget = ruler_widget

    -- Drag selection coordination state (panel-level, not view-level)
    local drag_state = {
        dragging = false,
        start_widget = nil,       -- Which widget the drag started in
        start_scroll_area = nil,  -- The scroll area containing that widget
        start_x = 0,              -- Start position in that widget's coords
        start_y = 0,
    }

    -- Map widget to its scroll area (will be populated after scroll areas are created)
    local widget_to_scroll_area = {}

    -- Forward declarations - will be set after splitter creation
    local vertical_splitter  -- Needed by on_drag_start for coordinate conversion
    local on_drag_move, on_drag_end

    -- Callback for views to notify panel when drag starts in empty space
    local function on_drag_start(source_widget, x, y, modifiers)
        drag_state.dragging = true
        drag_state.start_widget = source_widget
        drag_state.start_scroll_area = widget_to_scroll_area[source_widget]
        drag_state.start_x = x
        drag_state.start_y = y
        drag_state.modifiers = modifiers  -- Store for use in drag_end

        -- Convert start position to splitter coordinates immediately (not lazily)
        -- This ensures on_drag_end works even if there's no move event
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)
        local start_x_splitter, start_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(
            vertical_splitter,
            global_x,
            global_y
        )
        drag_state.splitter_start_x = start_x_splitter
        drag_state.splitter_start_y = start_y_splitter

        -- Return callbacks for view to use during drag
        return on_drag_move, on_drag_end
    end

    -- Create video timeline view
    local video_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local video_view = timeline_view.create(
        video_widget,
        state,
        function(track) return track.track_type == "VIDEO" end,
        {
            render_bottom_to_top = true,
            on_drag_start = on_drag_start,
            debug_id = "video",
        }
    )
    video_view_ref = video_view  -- Store reference for drag detection

    -- Make video widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_widget, "Expanding", "Expanding")

    -- Video scroll area
    local timeline_video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_video_scroll, "Expanding", "Expanding")
    qt_set_scroll_area_anchor_bottom(timeline_video_scroll, true)  -- V1 stays visible when shrinking

    -- Register video widget → scroll area mapping for coordinate conversion
    widget_to_scroll_area[video_widget] = timeline_video_scroll
    M.video_widget = video_widget

    -- Create audio timeline view
    local audio_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local audio_view = timeline_view.create(
        audio_widget,
        state,
        function(track) return track.track_type == "AUDIO" end,
        {
            on_drag_start = on_drag_start,
            debug_id = "audio",
        }
    )
    audio_view_ref = audio_view  -- Store reference for drag detection

    -- Make audio widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_widget, "Expanding", "Expanding")

    -- Audio scroll area
    local timeline_audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_audio_scroll, "Expanding", "Expanding")

    -- Register audio widget → scroll area mapping for coordinate conversion
    widget_to_scroll_area[audio_widget] = timeline_audio_scroll
    M.audio_widget = audio_widget

    -- Vertical splitter between video and audio scroll areas
    vertical_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_audio_scroll)

    -- Set initial 50/50 split (will be synchronized with headers_main_splitter)
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, {1, 1})

    -- Create rubber band for drag selection (parented to splitter so it can span both views)
    -- Note: rubber band starts hidden (QRubberBand::hide() called in C++)
    local rubber_band = qt_constants.WIDGET.CREATE_RUBBER_BAND(vertical_splitter)

    -- Panel drag coordination callbacks
    -- Called by view during drag to update rubber band geometry
    -- View passes its local coordinates, panel converts to splitter coords

    -- Show rubber band on first move
    local rubber_band_visible = false
    local function show_rubber_band_if_needed()
        if not rubber_band_visible then
            qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY(
                rubber_band,
                drag_state.splitter_start_x,
                drag_state.splitter_start_y,
                0, 0
            )
            qt_constants.DISPLAY.SET_VISIBLE(rubber_band, true)
            rubber_band_visible = true
        end
    end

    on_drag_move = function(source_widget, x, y)
        if not drag_state.dragging then return end

        -- Show rubber band on first move
        show_rubber_band_if_needed()

        -- Convert via global coordinates (always works regardless of hierarchy)
        -- Step 1: Widget-local → Global screen coords
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)

        -- Step 2: Global screen coords → Splitter-local coords
        local current_x_splitter, current_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(
            vertical_splitter,
            global_x,
            global_y
        )

        -- Calculate rubber band rectangle in splitter coords
        local rect_x = math.min(drag_state.splitter_start_x, current_x_splitter)
        local rect_y = math.min(drag_state.splitter_start_y, current_y_splitter)
        local rect_width = math.abs(current_x_splitter - drag_state.splitter_start_x)
        local rect_height = math.abs(current_y_splitter - drag_state.splitter_start_y)

        -- Update rubber band geometry
        qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY(rubber_band, rect_x, rect_y, rect_width, rect_height)

        -- TODO: Query views for clips in rectangle and update visual feedback
    end

    on_drag_end = function(source_widget, x, y)
        if not drag_state.dragging then return end

        -- Hide rubber band
        qt_constants.DISPLAY.SET_VISIBLE(rubber_band, false)

        -- Convert current mouse position to splitter coordinates
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)
        local end_x_splitter, end_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(vertical_splitter, global_x, global_y)

        -- Calculate selection rectangle in splitter coordinates
        local rect_x = math.min(drag_state.splitter_start_x, end_x_splitter)
        local rect_y = math.min(drag_state.splitter_start_y, end_y_splitter)
        local rect_width = math.abs(end_x_splitter - drag_state.splitter_start_x)
        local rect_height = math.abs(end_y_splitter - drag_state.splitter_start_y)

        -- Convert splitter rectangle to time range
        -- We need to map to a timeline view widget to get proper width for time conversion
        local viewport_width, _ = timeline.get_dimensions(video_widget)
        local start_value = state.pixel_to_time(rect_x, viewport_width)
        local end_time = state.pixel_to_time(rect_x + rect_width, viewport_width)

        -- Find all clips that intersect with the selection rectangle
        local selected_clips = {}
        for _, clip in ipairs(state.get_clips()) do
            -- Check time overlap
            local clip_end_time = clip.timeline_start + clip.duration
            local time_overlaps = not (clip_end_time < start_value or clip.timeline_start > end_time)

            if time_overlaps then

                -- Determine which view this clip is in
                local track = state.get_track_by_id(clip.track_id)
                if track then
                    local is_video = track.track_type == "VIDEO"
                    local view_widget = is_video and video_widget or audio_widget

                    -- Get widget height for bottom-to-top calculation
                    local widget_width, widget_height = timeline.get_dimensions(view_widget)

                    -- Calculate track Y position using SAME logic as timeline_view.lua rendering
                    local track_y_widget = 0
                    local tracks = is_video and state.get_video_tracks() or state.get_audio_tracks()

                    if is_video then
                        -- Video tracks: render bottom-to-top (same as timeline_view.lua)
                        -- Find track index
                        local track_index = -1
                        for i, t in ipairs(tracks) do
                            if t.id == clip.track_id then
                                track_index = i - 1  -- 0-based
                                break
                            end
                        end

                        -- Calculate Y from bottom upward (matches get_track_y in timeline_view.lua)
                        track_y_widget = widget_height
                        for i = 0, track_index do
                            if tracks[i + 1] then
                                local h = state.get_track_height(tracks[i + 1].id)
                                track_y_widget = track_y_widget - h
                            end
                        end
                    else
                        -- Audio tracks: render top-to-bottom (same as timeline_view.lua)
                        for _, t in ipairs(tracks) do
                            if t.id == clip.track_id then
                                break
                            end
                            track_y_widget = track_y_widget + state.get_track_height(t.id)
                        end
                    end

                    local track_height = state.get_track_height(clip.track_id)

                    -- Convert selection rectangle from splitter coordinates to widget coordinates
                    -- Splitter → global → widget
                    local sel_global_x, sel_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x, rect_y)
                    local sel_widget_x, sel_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_global_x, sel_global_y)

                    local sel_bottom_global_x, sel_bottom_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x + rect_width, rect_y + rect_height)
                    local sel_bottom_widget_x, sel_bottom_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_bottom_global_x, sel_bottom_global_y)

                    -- Check if selection rectangle (in widget coords) overlaps with track (also in widget coords)
                    local track_bottom = track_y_widget + track_height
                    local y_overlaps = not (track_bottom < sel_widget_y or track_y_widget > sel_bottom_widget_y)

                    if y_overlaps then
                        table.insert(selected_clips, clip)
                    end
                end
            end
        end

        -- Update selection state
        -- If Cmd was held during drag, toggle clips in/out of selection instead of replacing
        if drag_state.modifiers and drag_state.modifiers.command then
            local current_selection = state.get_selected_clips()

            -- Toggle: add clips that aren't selected, remove clips that are selected
            for _, dragged_clip in ipairs(selected_clips) do
                local found_index = nil
                for i, existing_clip in ipairs(current_selection) do
                    if existing_clip.id == dragged_clip.id then
                        found_index = i
                        break
                    end
                end

                if found_index then
                    -- Already selected - remove it (toggle off)
                    table.remove(current_selection, found_index)
                else
                    -- Not selected - add it (toggle on)
                    table.insert(current_selection, dragged_clip)
                end
            end

            state.set_selection(current_selection)
        else
            state.set_selection(selected_clips)
        end

        -- Reset drag state
        drag_state.dragging = false
        drag_state.start_widget = nil
        drag_state.start_x = 0
        drag_state.start_y = 0
        drag_state.splitter_start_x = nil
        drag_state.splitter_start_y = nil
        rubber_band_visible = false
    end

    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(vertical_splitter, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, vertical_splitter)

    -- Set stretch factor so splitter gets all remaining vertical space
    qt_set_layout_stretch_factor(timeline_area_layout, vertical_splitter, 1)

    -- Set layout on timeline area
    qt_constants.LAYOUT.SET_ON_WIDGET(timeline_area, timeline_area_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_area, "Expanding", "Expanding")

    -- Add both columns to main horizontal splitter
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, headers_column)
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_area)

    -- Add main splitter to main layout (gets all available vertical space)
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, tab_bar_widget)
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, main_splitter)
    qt_set_layout_stretch_factor(main_layout, main_splitter, 1)

    -- Scrollbar temporarily removed to test portal height allocation
    -- local scrollbar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    -- local scrollbar = timeline_scrollbar.create(scrollbar_widget, state)
    -- qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(scrollbar_widget, "Expanding", "Fixed")
    -- qt_constants.LAYOUT.ADD_WIDGET(main_layout, scrollbar_widget)

    -- Synchronize the headers splitter with the timeline splitter
    -- When headers video/audio boundary moves, update timeline
    local syncing = false  -- Prevent infinite loop
    _G["headers_splitter_moved"] = function(pos, index)
        logger.debug("timeline_panel", string.format("headers_splitter_moved fired: pos=%d, index=%d", pos, index))
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(headers_main_splitter)
            logger.debug("timeline_panel", string.format("  Syncing to timeline: sizes = {%d, %d}", sizes[1], sizes[2]))
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, sizes)
            syncing = false
        end
    end
    logger.debug("timeline_panel", "Registering headers_splitter_moved handler...")
    qt_set_splitter_moved_handler(headers_main_splitter, "headers_splitter_moved")
    logger.debug("timeline_panel", "  Handler registered")

    -- When timeline video/audio boundary moves, update headers
    _G["timeline_splitter_moved"] = function(pos, index)
        logger.debug("timeline_panel", string.format("timeline_splitter_moved fired: pos=%d, index=%d", pos, index))
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(vertical_splitter)
            logger.debug("timeline_panel", string.format("  Syncing to headers: sizes = {%d, %d}", sizes[1], sizes[2]))
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, sizes)
            syncing = false
        end
    end
    logger.debug("timeline_panel", "Registering timeline_splitter_moved handler...")
    qt_set_splitter_moved_handler(vertical_splitter, "timeline_splitter_moved")
    logger.debug("timeline_panel", "  Handler registered")

    -- Synchronize vertical scrolling in pairs (video ↔ video, audio ↔ audio)
    local video_scroll_syncing = false  -- Prevent infinite loop
    local audio_scroll_syncing = false

    -- Video scroll sync: header_video_scroll ↔ timeline_video_scroll
    _G["video_scroll_sync_handler"] = function(new_position)
        if not video_scroll_syncing then
            video_scroll_syncing = true
            qt_set_scroll_position(header_video_scroll, new_position)
            qt_set_scroll_position(timeline_video_scroll, new_position)
            video_scroll_syncing = false
        end
    end

    -- Audio scroll sync: header_audio_scroll ↔ timeline_audio_scroll
    _G["audio_scroll_sync_handler"] = function(new_position)
        if not audio_scroll_syncing then
            audio_scroll_syncing = true
            qt_set_scroll_position(header_audio_scroll, new_position)
            qt_set_scroll_position(timeline_audio_scroll, new_position)
            audio_scroll_syncing = false
        end
    end

    -- Connect video scroll areas to video sync handler
    qt_set_scroll_area_scroll_handler(header_video_scroll, "video_scroll_sync_handler")
    qt_set_scroll_area_scroll_handler(timeline_video_scroll, "video_scroll_sync_handler")

    -- Connect audio scroll areas to audio sync handler
    qt_set_scroll_area_scroll_handler(header_audio_scroll, "audio_scroll_sync_handler")
    qt_set_scroll_area_scroll_handler(timeline_audio_scroll, "audio_scroll_sync_handler")

    -- Set initial splitter sizes: 150px for headers, rest for timeline area
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {timeline_state.dimensions.track_header_width, 1000})

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, main_layout)

    -- Make main container expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Expanding", "Expanding")

    M.container = container
    M.main_splitter = main_splitter
    M.timeline_video_scroll = timeline_video_scroll
    M.timeline_audio_scroll = timeline_audio_scroll
    M.timeline_area = timeline_area

    logger.debug("timeline_panel", "Multi-view timeline panel created successfully")

    local initial_sequence_id = state.get_sequence_id and state.get_sequence_id() or nil
    if not initial_sequence_id or initial_sequence_id == "" then
        error("timeline_panel: missing initial sequence_id from state", 2)
    end
    ensure_tab_for_sequence(initial_sequence_id)
    update_tab_styles(initial_sequence_id)

    if not tab_command_listener and command_manager and command_manager.add_listener then
        tab_command_listener = command_manager.add_listener(profile_scope.wrap(
            "timeline_panel.command_listener",
            function(event)
                handle_tab_command_event(event)
            end
        ))
    end

    return container
end

function M.load_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    local current = state.get_sequence_id and state.get_sequence_id()
    if current == sequence_id then
        logger.debug("timeline_panel", string.format("Timeline already displaying sequence %s", sequence_id))
        return
    end

    logger.debug("timeline_panel", string.format("Loading sequence %s into timeline panel", sequence_id))
    local db_conn = database.get_connection()
    assert(db_conn, "timeline_panel.load_sequence: missing database connection")
    local project_id = nil
    local stmt = db_conn:prepare("SELECT project_id FROM sequences WHERE id = ?")
    assert(stmt, "timeline_panel.load_sequence: failed to prepare sequence project_id query")
    stmt:bind_value(1, sequence_id)
    if stmt:exec() and stmt:next() then
        project_id = stmt:value(0)
    end
    stmt:finalize()
    assert(project_id and project_id ~= "", "timeline_panel.load_sequence: missing project_id for sequence " .. tostring(sequence_id))
    state.init(sequence_id, project_id)

    database.set_project_setting(project_id, "last_open_sequence_id", sequence_id)

    if command_manager and command_manager.activate_timeline_stack then
        command_manager.activate_timeline_stack(sequence_id)
    end

    if M.header_video_scroll and M.header_audio_scroll then
        local new_video_splitter = select(1, create_video_headers())
        qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(M.header_video_scroll, new_video_splitter)

        local new_audio_splitter = select(1, create_audio_headers())
        qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(M.header_audio_scroll, new_audio_splitter)

        if M.headers_main_splitter then
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.headers_main_splitter, {1, 1})
        end
    end

    ensure_tab_for_sequence(sequence_id)
    update_tab_styles(sequence_id)
end

-- Check if timeline is currently dragging clips or edges
function M.is_dragging()
    local video_dragging = video_view_ref and video_view_ref.drag_state ~= nil
    local audio_dragging = audio_view_ref and audio_view_ref.drag_state ~= nil
    return video_dragging or audio_dragging
end

local function append_widget(list, widget)
    if widget then
        table.insert(list, widget)
    end
end

function M.get_focus_widgets()
    local widgets = {}
    append_widget(widgets, M.video_widget)
    append_widget(widgets, M.audio_widget)
    append_widget(widgets, M.timeline_video_scroll)
    append_widget(widgets, M.timeline_audio_scroll)
    append_widget(widgets, M.ruler_widget)
    append_widget(widgets, M.container)
    return widgets
end

return M
