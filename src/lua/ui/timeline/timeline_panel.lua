--- Timeline Panel - Multi-view timeline architecture
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
local log = require("core.logger").for_area("timeline")
local timecode = require("core.timecode")
local timecode_input = require("core.timecode_input")
local Track = require("models.track")
local Signals = require("core.signals")
local track_state = require("ui.timeline.state.track_state")
local drop_naming = require("ui.timeline.drop_naming")
local routing_pref  = require("ui.source_routing_view_pref")
local routing_state = require("ui.source_routing_view_state")

-- luacheck: globals qt_line_edit_select_all qt_scroll_area_h_scroll_by qt_scroll_area_h_scroll_info
-- luacheck: globals qt_set_scroll_area_h_scroll_handler

local View = require("ui.view")
local M = View.new("timeline")

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
local tab_bar_scroll = nil
local tab_bar_left_arrow = nil
local tab_bar_right_arrow = nil
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
local source_tab_color = "#5cbacc"  -- --src accent from design mockup v4

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

local function update_tab_scroll_arrows()
    if not tab_bar_scroll or not tab_bar_left_arrow or not tab_bar_right_arrow then return end
    local info = qt_scroll_area_h_scroll_info(tab_bar_scroll)
    local all_fit = (info.max == info.min)
    qt_constants.DISPLAY.SET_VISIBLE(tab_bar_left_arrow, not all_fit and info.value > info.min)
    qt_constants.DISPLAY.SET_VISIBLE(tab_bar_right_arrow, not all_fit and info.value < info.max)
end

-- The active sequence's frame rate, used by both format and parse paths
-- in the playhead TC entry. Asserts loudly when fps metadata is missing
-- (rule 1.14: required state, no silent default).
local function get_sequence_frame_rate_for_timecode()
    local rate = state and state.get_sequence_frame_rate and state.get_sequence_frame_rate() or nil
    assert(rate and rate.fps_numerator and rate.fps_denominator,
        "timeline_panel: missing sequence fps metadata")
    return rate
end

-- Whether typed timecode input is relative ("+10", "-2s", "+1:00") rather
-- than absolute. Relative input is a delta off the current playhead;
-- absolute input lands directly in absolute-TC frame space.
local function is_relative_timecode_input(text)
    assert(type(text) == "string",
        "timeline_panel.is_relative_timecode_input: text must be a string")
    local trimmed = text:match("^%s*(.-)%s*$")
    local first = trimmed:sub(1, 1)
    return first == "+" or first == "-"
end

local function get_formatted_playhead_timecode()
    local frame_utils = require("core.frame_utils")
    return frame_utils.format_timecode(state.get_playhead_position(),
        get_sequence_frame_rate_for_timecode())
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
    local font_size = (ui_constants.FONTS and ui_constants.FONTS.TIMECODE_FONT_SIZE) or "24px"
    local selection_bg = selection_color
    local selection_text = colors.WHITE_TEXT_COLOR or "#ffffff"

    return string.format([[
        QLineEdit {
            background: %s;
            color: %s;
            border: 1px solid %s;
            padding: 2px 6px;
            font-family: "Helvetica Neue";
            font-weight: 500;
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

-- Convert typed timecode text into the absolute sequence frame to store as
-- playhead_position. Returns (frame, nil) on success, (nil, err) on parse
-- failure. Absolute input ("01:02:03:04") parses straight to an absolute
-- frame. Relative input ("+10" / "-2s") is a delta off the current position.
local function parse_typed_timecode_to_raw_frame(text)
    local rate = get_sequence_frame_rate_for_timecode()
    local current = state.get_playhead_position()
    local parsed, err = timecode_input.parse(text, rate, {base_time = current})
    if not parsed then return nil, err end
    local frame = parsed.frames
    assert(type(frame) == "number" and frame == math.floor(frame),
        "timeline_panel: timecode parse must yield integer frame, got " .. tostring(frame))
    return frame, nil
end

local function apply_timecode_entry_text()
    if not timecode_entry.line_edit then
        return false
    end
    local raw = qt_constants.PROPERTIES.GET_TEXT(timecode_entry.line_edit)
    local frame, err = parse_typed_timecode_to_raw_frame(raw)
    if not frame then
        log.warn("Invalid timecode input: %s (%s)", tostring(raw), tostring(err))
        set_timecode_text_if_changed(get_formatted_playhead_timecode())
        return false
    end
    command_manager.execute_interactive("SetPlayhead", {
        project_id = state.get_project_id(),
        sequence_id = state.get_sequence_id(),
        playhead_position = frame,
    })
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
        if focus_in then
            -- Notify focus_manager that the timeline panel owns focus now —
            -- the timecode line_edit is a child of timeline_panel but isn't
            -- in get_focus_widgets() (it has its own dedicated handler).
            -- Without this, panel-scoped shortcuts (Tab → ToggleTimecodeFocus
            -- @timeline) wouldn't dispatch when the user clicks straight
            -- into the timecode field from another panel.
            require("ui.focus_manager").set_focused_panel("timeline")
        else
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
    -- ClickFocus (not StrongFocus) keeps the timecode field out of Qt's Tab
    -- chain. Tab dispatch in the timeline panel goes through the command
    -- system (ToggleTimecodeFocus). Click still focuses the field for typing.
    qt_set_focus_policy(line_edit, "ClickFocus")
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

local function apply_tab_style(tab, is_active, is_source)
    if not tab or not tab.button or not qt_constants.PROPERTIES.SET_STYLE then
        return
    end
    local accent = is_source and source_tab_color or selection_color
    local text_color = is_active and accent or inactive_text_color
    local border_color = is_active and accent or "transparent"
    local font_weight = is_active and "bold" or "normal"
    qt_constants.PROPERTIES.SET_STYLE(tab.button, build_tab_button_style(text_color, border_color, font_weight))
    if tab.close_button and qt_constants.PROPERTIES.SET_STYLE then
        qt_constants.PROPERTIES.SET_STYLE(tab.close_button, build_close_button_style(text_color))
    end
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

--- Toggle keyboard focus between the timecode entry field and the timeline
-- view. Bound to Tab via the TOML keymap (ToggleTimecodeFocus @timeline)
-- and remappable from the keyboard customization UI.
function M.toggle_timecode_focus()
    assert(timecode_entry.line_edit,
        "timeline_panel.toggle_timecode_focus: timecode_entry.line_edit not initialized")
    assert(M.video_widget or M.audio_widget,
        "timeline_panel.toggle_timecode_focus: no timeline view widget to focus")
    -- Use the focus handler's authoritative has_focus flag rather than
    -- comparing widget userdata pointers — Lua's `==` on widget userdata
    -- compares allocation identity, not the wrapped QWidget*, so two
    -- userdata wrapping the same widget are NOT equal.
    if timecode_entry.has_focus then
        return focus_timeline_view()
    end
    return focus_timecode_entry()
end


--- Cancel timecode entry: restore original display text and exit field.
-- Called by Escape key handler. Restores text BEFORE focus change so the
-- editingFinished handler sees valid (unchanged) timecode — effectively a no-op.
function M.cancel_timecode_entry()
    if not timecode_entry.line_edit then
        return false
    end
    timecode_entry.has_focus = false
    timecode_entry.last_text = nil  -- invalidate cache so SET_TEXT actually fires
    refresh_timecode_display()
    return focus_timeline_view()
end

local function get_sequence_display_name(sequence_id)
    assert(sequence_id and sequence_id ~= "", string.format(
        "get_sequence_display_name: sequence_id is %s", tostring(sequence_id)))
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

local function get_source_master_seq_id()
    local ok, pm = pcall(require, "ui.panel_manager")
    if not ok or not pm then return nil end
    local ok2, monitor = pcall(pm.get_sequence_monitor, "source_monitor")
    if not ok2 or not monitor then return nil end
    return monitor:get_loaded_master_seq_id()
end

local function update_tab_styles(active_sequence_id)
    local source_seq_id = get_source_master_seq_id()
    for id, tab in pairs(open_tabs) do
        apply_tab_style(tab, id == active_sequence_id, id == source_seq_id)
    end
end

--- Persist open tab IDs (in order) to the project settings DB.
local function persist_open_tabs()
    local project_id = state.get_project_id()
    assert(project_id and project_id ~= "",
        "persist_open_tabs: no project_id (state not initialized?)")
    database.set_project_setting(project_id, "open_sequence_ids", tab_order)
end

local function remove_from_tab_order(sequence_id)
    for index = #tab_order, 1, -1 do
        if tab_order[index] == sequence_id then
            table.remove(tab_order, index)
            break
        end
    end
end

--- Enter the no-active-sequence state: inverse of load_sequence. Feature 010.
--- Clears timeline state, deactivates the command stack, clears the selection
--- hub (inspector pulls empty), and persists the empty tab list + empty
--- last_open_sequence_id so a crash right after doesn't resurrect a tab.
--- Views (monitor, timeline widgets) pull from state and auto-render blank.
--- Idempotent.
function M.unload_sequence()
    local project_id = state.get_project_id()
    state.clear()
    command_manager.deactivate()
    selection_hub.update_selection("timeline", {})
    if project_id and project_id ~= "" then
        database.set_project_setting(project_id, "last_open_sequence_id", "")
        -- tab_order is authoritative for persisted open_sequence_ids.
        database.set_project_setting(project_id, "open_sequence_ids", tab_order)
    end
end

-- Assert that `first_clip` carries the metadata the new sequence needs.
-- The fps / width / height / audio_sample_rate come from the first dropped
-- clip (spec Q2). If that clip has no usable metadata the caller must
-- substitute project defaults before calling handle_drop_on_blank_timeline.
local function assert_clip_metadata_for_new_sequence(first_clip)
    assert(type(first_clip.name) == "string" and first_clip.name ~= "",
        "handle_drop_on_blank_timeline: first clip missing name")
    assert(type(first_clip.fps_numerator) == "number" and first_clip.fps_numerator > 0
        and type(first_clip.fps_denominator) == "number"
        and first_clip.fps_denominator > 0,
        "handle_drop_on_blank_timeline: first clip must carry fps_numerator "
            .. "and fps_denominator (caller lifts project defaults if media "
            .. "metadata is unusable)")
    assert(type(first_clip.audio_sample_rate) == "number" and first_clip.audio_sample_rate > 0,
        "handle_drop_on_blank_timeline: first clip must carry audio_sample_rate "
            .. "(caller lifts project defaults if media metadata is unusable)")
end

-- Create a new sequence for a drop batch and return its id + the id of its
-- V1 track (for subsequent Overwrite calls).
local function create_drop_target_sequence(project_id, first_clip, clip_count)
    local uuid = require("uuid")
    local new_seq_id = uuid.generate()
    local name = drop_naming.build_drop_sequence_name(first_clip.name, clip_count - 1)

    local result = command_manager.execute_interactive("CreateSequence", {
        project_id        = project_id,
        sequence_id       = new_seq_id,
        name              = name,
        frame_rate        = { fps_numerator = first_clip.fps_numerator,
                              fps_denominator = first_clip.fps_denominator },
        width             = first_clip.width,
        height            = first_clip.height,
        audio_sample_rate = first_clip.audio_sample_rate,
    })
    assert(result and result.success,
        "handle_drop_on_blank_timeline: CreateSequence failed: "
            .. tostring(result and result.error_message))

    local video_tracks = Track.find_by_sequence(new_seq_id, "VIDEO")
    assert(video_tracks and video_tracks[1] and video_tracks[1].id,
        "handle_drop_on_blank_timeline: new sequence has no VIDEO track")
    return new_seq_id, video_tracks[1].id
end

-- Place `clips` sequentially on `v1_track_id` starting at timeline 0.
-- Each Overwrite nests inside the current undo group.
local function insert_clips_sequentially(project_id, seq_id, v1_track_id, clips)
    local playhead = 0
    for index, clip in ipairs(clips) do
        assert(clip.nested_sequence_id and clip.nested_sequence_id ~= "",
            string.format("handle_drop_on_blank_timeline: clip[%d] missing "
                .. "nested_sequence_id", index))
        assert(type(clip.duration) == "number" and clip.duration > 0,
            string.format("handle_drop_on_blank_timeline: clip[%d] duration "
                .. "must be a positive integer", index))

        local result = command_manager.execute_interactive("Overwrite", {
            project_id            = project_id,
            sequence_id           = seq_id,
            nested_sequence_id    = clip.nested_sequence_id,
            target_video_track_id = v1_track_id,
            timeline_start_frame  = playhead,
            advance_playhead      = false,
        })
        assert(result and result.success,
            string.format("handle_drop_on_blank_timeline: Overwrite failed "
                .. "for clip[%d] at %d: %s",
                index, playhead,
                tostring(result and result.error_message)))
        playhead = playhead + clip.duration
    end
end

--- Drop-to-blank handler: called by the drag wiring when the user drops
--- items from the project browser onto the timeline while no sequence is
--- active (feature 010, FR-011). Dropped sequences open as tabs; dropped
--- clips fold into a single new sequence created from the first clip's
--- metadata (fps / resolution) and named after it.
---
--- @param payload table: {
---     sequences = { {id=...}, ... },   -- existing sequences to open as tabs
---     clips     = { {nested_sequence_id=..., name=..., duration=...,
---                    fps_numerator=..., fps_denominator=...,
---                    width=..., height=...}, ... },
--- }
--- Clips must already be flattened (bins recursed) by the caller. The
--- first clip supplies the new sequence's fps/resolution/name; if its
--- fps metadata is missing the caller must lift project defaults before
--- calling (spec Q2 fallback).
function M.handle_drop_on_blank_timeline(payload)
    assert(type(payload) == "table",
        "timeline_panel.handle_drop_on_blank_timeline: payload table required")

    local project_id = state.get_project_id()
    assert(project_id and project_id ~= "",
        "timeline_panel.handle_drop_on_blank_timeline: no project open")

    local active_seq = state.get_sequence_id()
    assert(not active_seq or active_seq == "",
        "timeline_panel.handle_drop_on_blank_timeline: must run in the "
            .. "no-active-sequence state; got active sequence "
            .. tostring(active_seq))

    local sequences = payload.sequences or {}
    local clips = payload.clips or {}

    -- Open each dropped existing sequence as a tab in drop order.
    for _, seq in ipairs(sequences) do
        assert(seq and seq.id and seq.id ~= "",
            "handle_drop_on_blank_timeline: sequence entry missing id")
        M.open_tab(seq.id)
    end

    -- Sequences-only drop: activate the last one as the active tab.
    -- Spec: "last activated wins."
    if #clips == 0 then
        if #sequences > 0 then
            M.load_sequence(sequences[#sequences].id)
        end
        return
    end

    assert_clip_metadata_for_new_sequence(clips[1])

    command_manager.begin_undo_group("drop_to_blank_timeline")
    local new_seq_id, v1_track_id = create_drop_target_sequence(
        project_id, clips[1], #clips)
    insert_clips_sequentially(project_id, new_seq_id, v1_track_id, clips)
    command_manager.end_undo_group()

    -- Make the new sequence the active tab.
    M.load_sequence(new_seq_id)
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
            -- Last tab closed — enter the no-active-sequence state.
            M.unload_sequence()
        end
    else
        update_tab_styles(current_sequence)
    end
    update_tab_scroll_arrows()
    persist_open_tabs()
end

-- Expose close_tab programmatically (for tests + any future script callers).
M.close_tab = close_tab

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
    update_tab_scroll_arrows()
end

--- Read a parameter off a command, tolerating both API shapes.
local function command_param(command, name)
    if command.get_parameter then return command:get_parameter(name) end
    if command.parameters then return command.parameters[name] end
    return nil
end

--- Load the first still-open sequence, or the first sequence on the project.
-- Used when undoing an import whose active tab was just deleted.
local function load_fallback_sequence()
    local fallback = tab_order[#tab_order]
    if fallback and fallback ~= "" then
        M.load_sequence(fallback)
        return
    end
    local project_id = state.get_project_id and state.get_project_id() or nil
    if not project_id or project_id == "" then return end
    local sequences = database.load_sequences(project_id) or {}
    local fallback_id = sequences[1] and sequences[1].id or nil
    if fallback_id and fallback_id ~= "" then
        M.load_sequence(fallback_id)
    end
end

--- Undo-side cleanup for commands that create sequences:
-- close any tabs opened for the about-to-be-deleted sequences, and if the
-- currently active sequence was among them, switch to a surviving one.
local function close_created_tabs_on_undo(created_sequence_ids)
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
        load_fallback_sequence()
    end
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
        local created_sequence_ids = command_param(command, "created_sequence_ids")
        if type(created_sequence_ids) ~= "table" then return end

        if event.event == "undo" then
            close_created_tabs_on_undo(created_sequence_ids)
        elseif event.event == "execute" or event.event == "redo" then
            local seq_id = created_sequence_ids[1]
            if seq_id then
                M.load_sequence(seq_id)
            end
        end
        return
    end

    if command.type == "ImportResolveTimeline" then
        local created_sequence_ids = command_param(command, "created_sequence_ids")
        if type(created_sequence_ids) ~= "table" then return end

        if event.event == "undo" then
            close_created_tabs_on_undo(created_sequence_ids)
        end
        -- Execute/redo: imported sequences appear in the browser; the user
        -- chooses when to open one. No auto-switch.
        return
    end

    if command.type == "DeleteSequence" then
        local sequence_id = nil
        if command.get_parameter then
            sequence_id = command:get_parameter("sequence_id")
        elseif command.parameters then
            sequence_id = command.parameters.sequence_id
        end
        if not sequence_id then return end

        if event.event == "execute" or event.event == "redo" then
            if not open_tabs[sequence_id] then return end
            local active = state.get_sequence_id and state.get_sequence_id() or nil
            -- If deleting the only open tab, switch to another sequence first
            -- so close_tab doesn't try to recreate a tab for a deleted sequence
            if active == sequence_id and #tab_order <= 1 then
                local project_id = state.get_project_id and state.get_project_id() or nil
                assert(project_id and project_id ~= "",
                    "DeleteSequence tab handler: no project_id")
                local sequences = database.load_sequences(project_id)
                assert(sequences, "DeleteSequence tab handler: load_sequences returned nil for " .. project_id)
                for _, seq in ipairs(sequences) do
                    if seq.id ~= sequence_id then
                        M.load_sequence(seq.id)
                        break
                    end
                end
            end
            close_tab(sequence_id)
        elseif event.event == "undo" then
            -- Sequence restored — reopen its tab
            ensure_tab_for_sequence(sequence_id)
            update_tab_styles(state.get_sequence_id and state.get_sequence_id() or nil)
            persist_open_tabs()
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
        QWidget {
            background: %s;
            border-left: 1px solid #222232;
            border-right: 1px solid #222232;
            border-top: 0px;
            border-bottom: 0px;
        }
    ]], background_color or "#111111")
end

local function build_track_header_label_stylesheet()
    return [[
        QLabel {
            background: transparent;
            color: #cccccc;
            padding: 0 2px;
        }
    ]]
end

local function build_track_header_btn_stylesheet(active, active_color)
    if active and active_color then
        return string.format([[
            QPushButton {
                background: %s;
                color: #ffffff;
                border: 1px solid #333333;
                padding: 1px 3px;
                font-size: 10px;
                font-weight: bold;
                min-width: 16px;
                max-width: 16px;
                min-height: 16px;
                max-height: 16px;
            }
        ]], active_color)
    end
    return [[
        QPushButton {
            background: #2a2a2a;
            color: #888888;
            border: 1px solid #333333;
            padding: 1px 3px;
            font-size: 10px;
            min-width: 16px;
            max-width: 16px;
            min-height: 16px;
            max-height: 16px;
        }
        QPushButton:hover {
            background: #3a3a3a;
            color: #cccccc;
        }
    ]]
end

-- Sync-mode: cycling order and icon glyphs (unicode stand-ins; proper SVG via QIcon pending)
local SYNC_CYCLE = { off = "ripple", ripple = "cut", cut = "off" }
local SYNC_ICONS = { off = "·", ripple = "≋", cut = "/" }

local function build_sm_btn_stylesheet(active, active_color)
    if active and active_color then
        return string.format([[
            QPushButton {
                background: %s; color: #ffffff;
                border: 1px solid #333333; padding: 0px;
                font-size: 9px; font-weight: bold;
                min-width: 16px; max-width: 16px;
                min-height: 12px; max-height: 12px;
            }
        ]], active_color)
    end
    return [[
        QPushButton {
            background: #2a2a2a; color: #888888;
            border: 1px solid #333333; padding: 0px; font-size: 9px;
            min-width: 16px; max-width: 16px;
            min-height: 12px; max-height: 12px;
        }
        QPushButton:hover { background: #3a3a3a; color: #cccccc; }
    ]]
end

local function build_id_btn_stylesheet(filled, accent)
    if filled then
        return string.format([[
            QPushButton {
                background: %s; color: #ffffff;
                border: 1px solid %s; padding: 0px 2px;
                font-size: 9px; font-weight: bold;
                min-width: 20px; max-width: 24px;
                min-height: 16px; max-height: 16px;
            }
        ]], accent, accent)
    end
    return string.format([[
        QPushButton {
            background: transparent; color: %s;
            border: 1px solid %s; padding: 0px 2px;
            font-size: 9px; font-weight: bold;
            min-width: 20px; max-width: 24px;
            min-height: 16px; max-height: 16px;
        }
        QPushButton:hover { color: #ffffff; border-color: #aaaaaa; }
    ]], accent, accent)
end

local function build_sync_mode_btn_stylesheet(mode)
    local colors = { ripple = "#2a3a2a", cut = "#3a2a2a" }
    return build_track_header_btn_stylesheet(mode ~= "off", colors[mode])
end

local track_btn_handler_seq = 0
local function register_track_btn_handler(callback)
    track_btn_handler_seq = track_btn_handler_seq + 1
    local name = "__track_btn_handler_" .. tostring(track_btn_handler_seq)
    _G[name] = function(...)
        callback(...)
    end
    return name
end

-- Registry of rec-id buttons for geometry-based drop-target resolution (T039, FR-010a).
-- { rec_btn=widget, track_index=N, track_type="AUDIO"|"VIDEO", seq_id="..." }
local rec_btn_hit_registry = {}

-- Returns the rec-id drop-target entry whose screen rect contains (gx, gy), or nil.
-- Widget identity comparison is not stable across userdata allocations, so bounding-rect
-- hit-test is the correct approach (WIDGET.MAP_TO_GLOBAL + PROPERTIES.GET_GEOMETRY).
local function find_drop_target(gx, gy)
    for _, entry in ipairs(rec_btn_hit_registry) do
        assert(entry.rec_btn, "find_drop_target: rec_btn nil in registry (track_index="
            .. tostring(entry.track_index) .. ")")
        local sx, sy = qt_constants.WIDGET.MAP_TO_GLOBAL(entry.rec_btn, 0, 0)
        local _, _, w, h = qt_constants.PROPERTIES.GET_GEOMETRY(entry.rec_btn)
        if gx >= sx and gx < sx + w and gy >= sy and gy < sy + h then
            return entry
        end
    end
    return nil
end


--- Wire a toggle-preference click: calls ToggleTrackPreference and re-pulls style.
local function wire_toggle_preference(btn, track_id, property, active_color)
    local captured_btn = btn
    local handler = register_track_btn_handler(function()
        local t = Track.load(track_id)
        assert(t, string.format("wire_toggle_preference: track %s not found", tostring(track_id)))
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_toggle_preference: no project_id")
        command_manager.execute_interactive("ToggleTrackPreference", {
            track_id = track_id, property = property, project_id = project_id,
        })
        local fresh = Track.load(track_id)
        if fresh then
            qt_constants.PROPERTIES.SET_STYLE(captured_btn,
                build_track_header_btn_stylesheet(fresh[property], active_color))
        end
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(btn, handler)
    return handler
end

--- Wire a sync-mode cycle click: Off→Ripple→Cut→Off via SetSyncMode.
local function wire_sync_mode_cycle(btn, track_id)
    local captured_btn = btn
    local handler = register_track_btn_handler(function()
        local t = Track.load(track_id)
        assert(t, string.format("wire_sync_mode_cycle: track %s not found", tostring(track_id)))
        local next_mode = SYNC_CYCLE[t.sync_mode]
        assert(next_mode, string.format(
            "wire_sync_mode_cycle: unrecognised sync_mode '%s' on track %s",
            tostring(t.sync_mode), tostring(track_id)))
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_sync_mode_cycle: no project_id")
        command_manager.execute_interactive("SetSyncMode", {
            track_id = track_id, sync_mode = next_mode, project_id = project_id,
        })
        local fresh = Track.load(track_id)
        if fresh then
            qt_constants.PROPERTIES.SET_TEXT(captured_btn, SYNC_ICONS[fresh.sync_mode] or "?")
            qt_constants.PROPERTIES.SET_STYLE(captured_btn, build_sync_mode_btn_stylesheet(fresh.sync_mode))
        end
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(btn, handler)
    return handler
end

--- Build and add the S/M vertical stack to a track header layout.
-- Returns mute_btn, solo_btn for style re-pull on external changes.
local function add_sm_stack_to_layout(header_layout, track, track_id)
    local sm_container = qt_constants.WIDGET.CREATE()
    local sm_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(sm_container, sm_layout)
    qt_constants.CONTROL.SET_LAYOUT_SPACING(sm_layout, 1)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(sm_layout, 0, 0, 0, 0)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(sm_container, "Fixed", "Fixed")

    local mute_btn = qt_constants.WIDGET.CREATE_BUTTON("M")
    qt_constants.PROPERTIES.SET_STYLE(mute_btn, build_sm_btn_stylesheet(track.muted, "#cc3333"))
    qt_constants.LAYOUT.ADD_WIDGET(sm_layout, mute_btn)
    wire_toggle_preference(mute_btn, track_id, "muted", "#cc3333")

    local solo_btn = qt_constants.WIDGET.CREATE_BUTTON("S")
    qt_constants.PROPERTIES.SET_STYLE(solo_btn, build_sm_btn_stylesheet(track.soloed, "#ccaa00"))
    qt_constants.LAYOUT.ADD_WIDGET(sm_layout, solo_btn)
    wire_toggle_preference(solo_btn, track_id, "soloed", "#ccaa00")

    qt_constants.LAYOUT.ADD_WIDGET(header_layout, sm_container)
    return mute_btn, solo_btn
end

-- Format a source-track label for display in the src-id button.
-- E.g. track_type="VIDEO", src_idx=1 → "V1"; track_type="AUDIO", src_idx=3 → "A3".
local function format_source_label(track_type, src_idx)
    local prefix = (track_type == "VIDEO") and "V" or "A"
    return prefix .. tostring(src_idx)
end

-- Wire src-id and rec-id buttons to SetPatch command (T038, FR-009, FR-010).
-- rec_track_index: the index of the RECORD track this row represents.
-- track_type: "VIDEO" or "AUDIO" — used to format the source-track label.
-- src_btn label: which SOURCE track feeds this record row (reverse-lookup from patches).
-- rec_btn label: this record track's own name — set at creation, never changed here.
local function wire_patch_buttons(src_btn, _rec_btn, sequence_id, rec_track_index, track_type)
    assert(sequence_id and sequence_id ~= "",
        "wire_patch_buttons: sequence_id required (rec_track_index=" .. tostring(rec_track_index) .. ")")
    assert(type(rec_track_index) == "number",
        "wire_patch_buttons: rec_track_index must be number, got " .. type(rec_track_index))
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "wire_patch_buttons: track_type must be VIDEO or AUDIO, got " .. tostring(track_type))
    local captured_src = src_btn
    local Patch = require("models.patch")

    local function refresh_src_btn()
        -- Reverse lookup: which source track is patched to this record row?
        local p = Patch.find_by_record(sequence_id, rec_track_index)
        if not p then
            -- No source routed here — show empty space, not a placeholder button.
            qt_constants.DISPLAY.SET_VISIBLE(captured_src, false)
            return
        end
        local enabled = p.enabled == 1 or p.enabled == true
        qt_constants.PROPERTIES.SET_TEXT(captured_src,
            format_source_label(track_type, p.source_track_index))
        qt_constants.PROPERTIES.SET_STYLE(captured_src,
            build_id_btn_stylesheet(enabled, source_tab_color))
        qt_constants.DISPLAY.SET_VISIBLE(captured_src, true)
    end

    refresh_src_btn()

    local src_handler = register_track_btn_handler(function()
        -- src-id click (record-tab mode): toggle enabled on the patch feeding this record row.
        local p = Patch.find_by_record(sequence_id, rec_track_index)
        if not p then return end  -- no patch yet; user must drag to create one
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_patch_buttons: no project_id (rec_track_index=" .. tostring(rec_track_index) .. ")")
        local current_enabled = p.enabled == 1 or p.enabled == true
        local cmd = require("core.command_manager")
        cmd.execute("SetPatch", {
            sequence_id        = sequence_id,
            source_track_index = p.source_track_index,
            project_id         = project_id,
            enabled            = not current_enabled,
        })
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(src_btn, src_handler)
end

-- Track button references for MVC re-pull on undo/redo
-- { [track_id] = { mute_btn, solo_btn, lock_btn, sync_mode_btn, src_btn, rec_btn, seq_id, src_idx } }
local track_button_refs = {}

local function refresh_track_button_styles()
    for track_id, refs in pairs(track_button_refs) do
        local t = Track.load(track_id)
        if not t then
            log.warn("refresh_track_button_styles: track %s not found (deleted?), clearing refs", tostring(track_id))
            track_button_refs[track_id] = nil
        else
            if refs.mute_btn then
                qt_constants.PROPERTIES.SET_STYLE(refs.mute_btn,
                    build_sm_btn_stylesheet(t.muted, "#cc3333"))
            end
            if refs.solo_btn then
                qt_constants.PROPERTIES.SET_STYLE(refs.solo_btn,
                    build_sm_btn_stylesheet(t.soloed, "#ccaa00"))
            end
            if refs.lock_btn then
                qt_constants.PROPERTIES.SET_STYLE(refs.lock_btn,
                    build_track_header_btn_stylesheet(t.locked, "#ccaa00"))
            end
            if refs.sync_mode_btn then
                qt_constants.PROPERTIES.SET_TEXT(refs.sync_mode_btn, SYNC_ICONS[t.sync_mode] or "?")
                qt_constants.PROPERTIES.SET_STYLE(refs.sync_mode_btn,
                    build_sync_mode_btn_stylesheet(t.sync_mode))
            end
        end
    end
end

-- MVC: update button styles when track state changes externally (undo/redo)
Signals.connect("track_mix_changed", refresh_track_button_styles)

-- MVC: track_preference_changed fires when mute/solo/lock/enabled is toggled.
Signals.connect("track_preference_changed", function(track_id, property, new_val)
    local refs = track_button_refs[track_id]
    if not refs then return end
    if property == "muted" and refs.mute_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.mute_btn,
            build_sm_btn_stylesheet(new_val, "#cc3333"))
    elseif property == "soloed" and refs.solo_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.solo_btn,
            build_sm_btn_stylesheet(new_val, "#ccaa00"))
    elseif property == "locked" and refs.lock_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.lock_btn,
            build_track_header_btn_stylesheet(new_val, "#ccaa00"))
    end
end)

-- MVC: sync_mode_changed fires when cycle button or SetSyncMode command runs.
Signals.connect("sync_mode_changed", function(track_id, new_mode)
    local refs = track_button_refs[track_id]
    if not refs or not refs.sync_mode_btn then return end
    qt_constants.PROPERTIES.SET_TEXT(refs.sync_mode_btn, SYNC_ICONS[new_mode] or "?")
    qt_constants.PROPERTIES.SET_STYLE(refs.sync_mode_btn, build_sync_mode_btn_stylesheet(new_mode))
end)

-- MVC: patch_changed fires when SetPatch creates/updates/disables a patch.
-- Re-pulls patch state and refreshes the src-id button on the affected RECORD row.
-- rec_btn label never changes (always the record track's own name).
Signals.connect("patch_changed", function(sequence_id, source_track_index, change_type)
    local Patch = require("models.patch")
    local p = Patch.find_by_source(sequence_id, source_track_index)

    -- Determine which record row to update.
    local rec_index = p and p.record_track_index
    local enabled   = p and (p.enabled == 1 or p.enabled == true)

    for track_id, refs in pairs(track_button_refs) do
        if refs.seq_id == sequence_id and refs.rec_idx == rec_index then
            assert(refs.src_btn,
                "patch_changed: src_btn nil for track " .. tostring(track_id))
            if p and change_type ~= "deleted" then
                local src_label = format_source_label(refs.track_type, source_track_index)
                qt_constants.PROPERTIES.SET_TEXT(refs.src_btn, src_label)
                qt_constants.PROPERTIES.SET_STYLE(refs.src_btn,
                    build_id_btn_stylesheet(enabled, source_tab_color))
                qt_constants.DISPLAY.SET_VISIBLE(refs.src_btn, true)
                log.event("patch_changed: src_btn rec_idx=%s → %s",
                    tostring(rec_index), src_label)
            else
                qt_constants.DISPLAY.SET_VISIBLE(refs.src_btn, false)
                log.event("patch_changed: src_btn rec_idx=%s hidden (deleted/nil)",
                    tostring(rec_index))
            end
            break
        end
    end
end)

-- MVC: re-evaluate tab accent colors when the source monitor loads/unloads a master.
-- source_seq_id changing means the Source tab's identity changed — update_tab_styles
-- re-queries the monitor so the correct tab gets the --src teal accent.
Signals.connect("source_loaded_changed", function()
    local current = state.get_sequence_id and state.get_sequence_id()
    update_tab_styles(current)
end)

-- Helper function to create video headers with splitters
local function create_video_headers()
    -- Clear drag drop-target registry; audio builder repopulates its entries below.
    -- Both builders always run together (init + rebuild paths both call both), so
    -- clearing here at the top of the first builder is safe.
    rec_btn_hit_registry = {}
    local video_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local video_tracks = state.get_video_tracks()

    -- Debug: Video tracks from state
    -- for i, track in ipairs(video_tracks) do
    --     print(string.format("  video_tracks[%d] = %s (id=%s)", i, track.name, track.id))
    -- end

    local video_headers = {}
    local handler_name = "video_splitter_event_" .. tostring(video_splitter):gsub("[^%w]", "_")

    -- Add stretch widget at top to push tracks down (V1 is anchor at bottom)
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(video_splitter, stretch_widget)

    -- Add tracks in REVERSE order (V3, V2, V1)
    local video_header_heights = {}
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        local track_height = clamp_track_height(state.get_track_height and state.get_track_height(track.id) or DEFAULT_TRACK_HEIGHT)
        local header_height = content_to_header(track_height)

        -- Container widget with HBox layout for buttons
        local header = qt_constants.WIDGET.CREATE()
        local header_layout = qt_constants.LAYOUT.CREATE_HBOX()
        qt_constants.LAYOUT.SET_ON_WIDGET(header, header_layout)
        qt_constants.CONTROL.SET_LAYOUT_SPACING(header_layout, 2)
        qt_constants.CONTROL.SET_LAYOUT_MARGINS(header_layout, 4, 0, 4, 0)

        qt_constants.PROPERTIES.SET_STYLE(header, build_track_header_stylesheet(timeline_state.colors.video_track_header))
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, header_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, header_height)

        local captured_track_id = track.id

        -- src-id button: shows which SOURCE track feeds this record row (filled when enabled).
        -- Label is populated by wire_patch_buttons via reverse patch lookup.
        local src_btn = qt_constants.WIDGET.CREATE_BUTTON("—")
        qt_constants.PROPERTIES.SET_STYLE(src_btn,
            build_id_btn_stylesheet(false, source_tab_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, src_btn)

        -- rec-patch-id button: always shows this record track's name, filled with rec-red.
        local rec_btn = qt_constants.WIDGET.CREATE_BUTTON(track.name)
        qt_constants.PROPERTIES.SET_STYLE(rec_btn,
            build_id_btn_stylesheet(true, selection_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, rec_btn)

        local video_seq_id = state.get_sequence_id()
        wire_patch_buttons(src_btn, rec_btn, video_seq_id, track.track_index, "VIDEO")
        table.insert(rec_btn_hit_registry, {
            rec_btn     = rec_btn,
            track_index = track.track_index,
            track_type  = "VIDEO",
            seq_id      = video_seq_id,
        })

        -- Track name label (flex)
        local name_label = qt_constants.WIDGET.CREATE_LABEL(track.name)
        qt_constants.PROPERTIES.SET_STYLE(name_label, build_track_header_label_stylesheet())
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(name_label, "Expanding", "Fixed")
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, name_label)

        -- Lock cell (unicode stand-in; proper QIcon pending binding)
        local lock_btn = qt_constants.WIDGET.CREATE_BUTTON("🔒")
        qt_constants.PROPERTIES.SET_STYLE(lock_btn, build_track_header_btn_stylesheet(track.locked, "#ccaa00"))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, lock_btn)
        wire_toggle_preference(lock_btn, captured_track_id, "locked", "#ccaa00")

        -- Sync-mode cell (cycles Off→Ripple→Cut→Off)
        local sync_btn = qt_constants.WIDGET.CREATE_BUTTON(SYNC_ICONS[track.sync_mode] or "?")
        qt_constants.PROPERTIES.SET_STYLE(sync_btn, build_sync_mode_btn_stylesheet(track.sync_mode))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, sync_btn)
        wire_sync_mode_cycle(sync_btn, captured_track_id)

        -- S/M vertical stack (both video and audio tracks carry solo/mute per FR-019/FR-020)
        local mute_btn, solo_btn = add_sm_stack_to_layout(header_layout, track, captured_track_id)

        track_button_refs[captured_track_id] = {
            mute_btn      = mute_btn,
            solo_btn      = solo_btn,
            lock_btn      = lock_btn,
            sync_mode_btn = sync_btn,
            src_btn       = src_btn,
            rec_btn       = rec_btn,
            seq_id        = video_seq_id,
            rec_idx       = track.track_index,
            track_type    = "VIDEO",
        }

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
    log.event("Installing video handles for %d tracks", #video_tracks)
    log.event("Checking which Qt handles exist...")
    for test_index = 0, #video_tracks + 1 do
        local test_handle = qt_get_splitter_handle(video_splitter, test_index)
        log.event("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil")
    end

    for qt_handle_index = 1, #video_tracks do
        local handle = qt_get_splitter_handle(video_splitter, qt_handle_index)
        log.event("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle))
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

            log.event("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_below)

            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index
            log.event("    Handler name: %s", this_handler_name)

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

                    log.event("Handle %d → %s = %dpx", captured_handle_num, captured_track_name, new_height)

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
                    log.event("  Updated video_splitter min height to %dpx", total_height)
                end
            end
            log.event("    Calling qt_set_widget_click_handler for %s", this_handler_name)
            qt_set_widget_click_handler(handle, this_handler_name)
            log.event("    Handler installed successfully")
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
        log.event("video_splitter_moved fired: pos=%d, index=%d", pos, index)
        -- Calculate total height needed for all video tracks
        local total_height = 0
        for _, track in ipairs(state.get_video_tracks()) do
            total_height = total_height + content_to_header(state.get_track_height(track.id))
        end
        log.event("  Setting video_splitter min height to %dpx", total_height)
        -- Set splitter minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_splitter, total_height)
    end
    log.event("Registering video_splitter_moved handler...")
    qt_set_splitter_moved_handler(video_splitter, "video_splitter_moved")
    log.event("  Handler registered")

    -- Hide the handle above V3 (between stretch widget and V3) - handle index 0
    qt_hide_splitter_handle(video_splitter, 0)

    return video_splitter, video_headers
end

-- Helper function to create audio headers with splitters
local function create_audio_headers()
    local audio_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local audio_tracks = state.get_audio_tracks()

    local audio_headers = {}
    local handler_name = "audio_splitter_event_" .. tostring(audio_splitter):gsub("[^%w]", "_")

    -- Add tracks in normal order (A1, A2, A3)
    local audio_header_heights = {}
    for i, track in ipairs(audio_tracks) do
        local track_height = clamp_track_height(state.get_track_height and state.get_track_height(track.id) or DEFAULT_TRACK_HEIGHT)
        local header_height = content_to_header(track_height)

        -- Container widget with HBox layout for buttons
        local header = qt_constants.WIDGET.CREATE()
        local header_layout = qt_constants.LAYOUT.CREATE_HBOX()
        qt_constants.LAYOUT.SET_ON_WIDGET(header, header_layout)
        qt_constants.CONTROL.SET_LAYOUT_SPACING(header_layout, 2)
        qt_constants.CONTROL.SET_LAYOUT_MARGINS(header_layout, 4, 0, 4, 0)

        qt_constants.PROPERTIES.SET_STYLE(header, build_track_header_stylesheet(timeline_state.colors.audio_track_header))
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, header_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, header_height)

        local captured_track_id = track.id

        -- src-id button: shows which SOURCE track feeds this record row.
        local src_btn = qt_constants.WIDGET.CREATE_BUTTON("—")
        qt_constants.PROPERTIES.SET_STYLE(src_btn,
            build_id_btn_stylesheet(false, source_tab_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, src_btn)

        -- rec-patch-id button: always shows this record track's name, filled with rec-red.
        local rec_btn = qt_constants.WIDGET.CREATE_BUTTON(track.name)
        qt_constants.PROPERTIES.SET_STYLE(rec_btn,
            build_id_btn_stylesheet(true, selection_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, rec_btn)

        local audio_seq_id = state.get_sequence_id()
        wire_patch_buttons(src_btn, rec_btn, audio_seq_id, track.track_index, "AUDIO")
        table.insert(rec_btn_hit_registry, {
            rec_btn     = rec_btn,
            track_index = track.track_index,
            track_type  = "AUDIO",
            seq_id      = audio_seq_id,
        })

        -- Track name label (flex); FR-021 channel count pending track model extension
        local name_label = qt_constants.WIDGET.CREATE_LABEL(track.name)
        qt_constants.PROPERTIES.SET_STYLE(name_label, build_track_header_label_stylesheet())
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(name_label, "Expanding", "Fixed")
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, name_label)

        -- Lock cell (unicode stand-in; proper QIcon pending binding)
        local lock_btn = qt_constants.WIDGET.CREATE_BUTTON("🔒")
        qt_constants.PROPERTIES.SET_STYLE(lock_btn, build_track_header_btn_stylesheet(track.locked, "#ccaa00"))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, lock_btn)
        wire_toggle_preference(lock_btn, captured_track_id, "locked", "#ccaa00")

        -- Sync-mode cell (cycles Off→Ripple→Cut→Off)
        local sync_btn = qt_constants.WIDGET.CREATE_BUTTON(SYNC_ICONS[track.sync_mode] or "?")
        qt_constants.PROPERTIES.SET_STYLE(sync_btn, build_sync_mode_btn_stylesheet(track.sync_mode))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, sync_btn)
        wire_sync_mode_cycle(sync_btn, captured_track_id)

        -- S/M vertical stack
        local mute_btn, solo_btn = add_sm_stack_to_layout(header_layout, track, captured_track_id)

        -- Waveform toggle (audio-only, UI state — no undo, kept at right edge)
        local wave_enabled = track_state.get_waveform_enabled(captured_track_id)
        local wave_btn = qt_constants.WIDGET.CREATE_BUTTON("W")
        qt_constants.PROPERTIES.SET_STYLE(wave_btn,
            build_track_header_btn_stylesheet(wave_enabled, "#4488aa"))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, wave_btn)

        local captured_wave_btn = wave_btn
        local wave_handler = register_track_btn_handler(function()
            local current = track_state.get_waveform_enabled(captured_track_id)
            track_state.set_waveform_enabled(captured_track_id, not current)
            qt_constants.PROPERTIES.SET_STYLE(captured_wave_btn,
                build_track_header_btn_stylesheet(not current, "#4488aa"))
        end)
        qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(wave_btn, wave_handler)

        track_button_refs[captured_track_id] = {
            mute_btn      = mute_btn,
            solo_btn      = solo_btn,
            lock_btn      = lock_btn,
            sync_mode_btn = sync_btn,
            src_btn       = src_btn,
            rec_btn       = rec_btn,
            seq_id        = audio_seq_id,
            rec_idx       = track.track_index,
            track_type    = "AUDIO",
        }

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
    log.event("Installing audio handles for %d tracks", #audio_tracks)
    log.event("Checking which Qt handles exist...")
    for test_index = 0, #audio_tracks + 1 do
        local test_handle = qt_get_splitter_handle(audio_splitter, test_index)
        log.event("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil")
    end

    for qt_handle_index = 1, #audio_tracks do
        local handle = qt_get_splitter_handle(audio_splitter, qt_handle_index)
        log.event("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle))
        if handle then
            -- Direct mapping: qt_handle N → Handle N → resizes Track N (no renumbering!)
            local handle_num = qt_handle_index
            local track_num = qt_handle_index  -- Direct 1:1 mapping
            local track_id = audio_tracks[track_num].id
            local track_name = audio_tracks[track_num].name

            -- Qt positions: A1=0, A2=1, A3=2, Stretch=3
            -- Each handle resizes the widget ABOVE it
            local qt_pos_to_resize = qt_handle_index - 1

            log.event("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_to_resize)

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
            log.event("    Calling qt_set_widget_click_handler for %s", this_handler_name)
            qt_set_widget_click_handler(handle, this_handler_name)
            log.event("    Handler installed successfully")
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
    log.event("Creating multi-view timeline panel...")

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
    -- project_id is always required; sequence_id is optional — nil means the
    -- editor is opening in the no-active-sequence state (feature 010).
    assert(project_id and project_id ~= "", "timeline_panel.create: project_id is required")
    if sequence_id and sequence_id ~= "" then
        state.init(sequence_id, project_id)
    else
        state.set_project_id(project_id)
        state.clear()
    end

    -- Set up selection callback for inspector. In the no-active-sequence
    -- state (feature 010 — project opened with no last_open_sequence_id, or
    -- after the user closed the last tab) there is no sequence to build a
    -- selection inspectable for. normalize_timeline_selection asserts on a
    -- present sequence_id; the boundary handles the absent-sequence case by
    -- broadcasting an empty selection so the inspector clears.
    local function broadcast_selection(selected_clips)
        local sid = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        if not (sid and sid ~= "") then
            selection_hub.update_selection("timeline", {})
            return
        end
        selection_hub.update_selection("timeline", normalize_timeline_selection(selected_clips))
    end

    state.set_on_selection_changed(broadcast_selection)
    local initial_selection = state.get_selected_clips and state.get_selected_clips() or {}
    broadcast_selection(initial_selection)

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
                broadcast_selection(selected)
            end
        else
            last_mark_signature = nil
        end
    end))

    -- Main container
    -- luacheck: globals qt_create_focus_container
    local container = qt_create_focus_container()  -- Tab cycles between timecode + timeline view
    -- Opaque background prevents resize artifacts (transparent children leave ghost pixels)
    qt_constants.PROPERTIES.SET_STYLE(container, [[QWidget { background: #2b2b2b; }]])
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
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_tabs_container, "Preferred", "Fixed")

    -- Scroll area constrains tab bar width, clips overflow
    local panel_bg = colors.PANEL_BACKGROUND_COLOR or "#1f1f1f"
    tab_bar_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET_RESIZABLE(tab_bar_scroll, true)
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(tab_bar_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(tab_bar_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(tab_bar_scroll, tab_bar_tabs_container)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_scroll, "Expanding", "Fixed")
    qt_constants.PROPERTIES.SET_STYLE(tab_bar_scroll, string.format(
        [[QScrollArea { background: %s; border: none; }
          QWidget#qt_scrollarea_viewport { background: %s; }]], panel_bg, panel_bg))

    -- Arrow buttons for scrolling overflow tabs
    local arrow_style = string.format([[
        QPushButton { background: %s; color: %s; border: none; padding: 2px 4px; font-size: 11px; }
        QPushButton:hover { color: %s; }
    ]], panel_bg, inactive_text_color, hover_text_color)

    tab_bar_left_arrow = qt_constants.WIDGET.CREATE_BUTTON("\xe2\x97\x80")  -- ◀
    qt_constants.PROPERTIES.SET_STYLE(tab_bar_left_arrow, arrow_style)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_left_arrow, "Fixed", "Fixed")
    qt_constants.DISPLAY.SET_VISIBLE(tab_bar_left_arrow, false)
    local left_arrow_handler = register_global_handler("__jve_tab_scroll_left", function()
        qt_scroll_area_h_scroll_by(tab_bar_scroll, -200)
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(tab_bar_left_arrow, left_arrow_handler)

    tab_bar_right_arrow = qt_constants.WIDGET.CREATE_BUTTON("\xe2\x96\xb6")  -- ▶
    qt_constants.PROPERTIES.SET_STYLE(tab_bar_right_arrow, arrow_style)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_right_arrow, "Fixed", "Fixed")
    qt_constants.DISPLAY.SET_VISIBLE(tab_bar_right_arrow, false)
    local right_arrow_handler = register_global_handler("__jve_tab_scroll_right", function()
        qt_scroll_area_h_scroll_by(tab_bar_scroll, 200)
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(tab_bar_right_arrow, right_arrow_handler)

    -- Update arrow visibility on horizontal scroll
    _G["__jve_tab_scroll_changed"] = function()
        update_tab_scroll_arrows()
    end
    qt_set_scroll_area_h_scroll_handler(tab_bar_scroll, "__jve_tab_scroll_changed")

    qt_constants.LAYOUT.ADD_WIDGET(tab_bar_layout, tab_bar_left_arrow)
    qt_constants.LAYOUT.ADD_WIDGET(tab_bar_layout, tab_bar_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(tab_bar_layout, tab_bar_right_arrow)

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
    M.timeline_video_scroll = timeline_video_scroll  -- for scroll persist/restore
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_video_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(timeline_video_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(timeline_video_scroll, "AlwaysOff")
    -- Remove scroll area frame/border so content width matches ruler width exactly
    qt_constants.PROPERTIES.SET_STYLE(timeline_video_scroll, "QScrollArea { border: none; }")
    qt_set_scroll_area_anchor_bottom(timeline_video_scroll, true)  -- V1 stays visible when shrinking

    -- Register video widget → scroll area mapping for coordinate conversion
    widget_to_scroll_area[video_widget] = timeline_video_scroll
    M.video_widget = video_widget
    -- ClickFocus (not StrongFocus) keeps the timeline view out of Qt's Tab
    -- chain. The timecode↔timeline toggle is now driven by the command
    -- system (ToggleTimecodeFocus @timeline). Mouse clicks still focus the
    -- view.
    if qt_set_focus_policy then qt_set_focus_policy(video_widget, "ClickFocus") end  -- luacheck: globals qt_set_focus_policy

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
    M.timeline_audio_scroll = timeline_audio_scroll  -- for scroll persist/restore
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_audio_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(timeline_audio_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(timeline_audio_scroll, "AlwaysOff")
    -- Remove scroll area frame/border so content width matches ruler width exactly
    qt_constants.PROPERTIES.SET_STYLE(timeline_audio_scroll, "QScrollArea { border: none; }")

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
    M._rubber_band = rubber_band  -- accessible by cancel signal handler

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
        local viewport_width, _ = timeline.get_dimensions(video_widget)
        local time_start = state.pixel_to_time(rect_x, viewport_width)
        local time_end = state.pixel_to_time(rect_x + rect_width, viewport_width)

        -- Find which tracks intersect the Y range of the selection rectangle
        local intersecting_track_ids = {}

        -- Helper to check track intersection and collect matching track IDs
        local function collect_intersecting_tracks(view_widget, tracks, bottom_to_top)
            local _, widget_height = timeline.get_dimensions(view_widget)

            -- Convert selection rect to widget coordinates
            local sel_top_global_x, sel_top_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x, rect_y)
            local _, sel_top_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_top_global_x, sel_top_global_y)

            local sel_bot_global_x, sel_bot_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x, rect_y + rect_height)
            local _, sel_bot_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_bot_global_x, sel_bot_global_y)

            local sel_y_min = math.min(sel_top_widget_y, sel_bot_widget_y)
            local sel_y_max = math.max(sel_top_widget_y, sel_bot_widget_y)

            local track_y = bottom_to_top and widget_height or 0

            for i, track in ipairs(tracks) do
                local track_height = state.get_track_height(track.id)

                local track_top, track_bottom
                if bottom_to_top then
                    track_y = track_y - track_height
                    track_top = track_y
                    track_bottom = track_y + track_height
                else
                    track_top = track_y
                    track_bottom = track_y + track_height
                    track_y = track_y + track_height
                end

                -- Check Y overlap
                local y_overlaps = not (track_bottom <= sel_y_min or track_top >= sel_y_max)
                if y_overlaps then
                    table.insert(intersecting_track_ids, track.id)
                end
            end
        end

        -- Check video tracks (bottom-to-top layout)
        collect_intersecting_tracks(video_widget, state.get_video_tracks(), true)
        -- Check audio tracks (top-to-bottom layout)
        collect_intersecting_tracks(audio_widget, state.get_audio_tracks(), false)

        -- Execute SelectRectangle command (handles Cmd→toggle, time/track intersection)
        command_manager.execute_interactive("SelectRectangle", {
            project_id = state.get_project_id(),
            sequence_id = state.get_sequence_id(),
            time_start = time_start,
            time_end = time_end,
            track_ids = intersecting_track_ids,
            modifiers = drag_state.modifiers,
        })

        -- Reset drag state
        drag_state.dragging = false
        drag_state.start_widget = nil
        drag_state.start_x = 0
        drag_state.start_y = 0
        drag_state.splitter_start_x = nil
        drag_state.splitter_start_y = nil
        rubber_band_visible = false
    end

    -- Subscribe to cancel signal: hide rubber band + inject synthetic mouse move
    -- so the drag handler's cancel.consume() runs the normal state cleanup.
    local Signals = require("core.signals")
    Signals.connect("cancel", function()
        -- Hide rubber band immediately
        qt_constants.DISPLAY.SET_VISIBLE(rubber_band, false)
        rubber_band_visible = false
        drag_state.dragging = false
        -- Synthetic move triggers discard_drag → clears view state + forces repaint
        if video_view_ref and video_view_ref.on_mouse_event then
            video_view_ref.on_mouse_event("move", 0, 0, 0, {})
        end
        if audio_view_ref and audio_view_ref.on_mouse_event then
            audio_view_ref.on_mouse_event("move", 0, 0, 0, {})
        end
    end)

    M.vertical_splitter = vertical_splitter  -- for split ratio restore
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(vertical_splitter, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, vertical_splitter)

    -- Persist scroll offsets whenever the Qt scroll area changes
    _G["video_scroll_changed"] = function(value)
        log.event("video_scroll_changed: %d", value)
        state.set_video_scroll_offset(value)
    end
    qt_set_scroll_area_v_scroll_handler(M.timeline_video_scroll, "video_scroll_changed")

    _G["audio_scroll_changed"] = function(value)
        log.event("audio_scroll_changed: %d", value)
        state.set_audio_scroll_offset(value)
    end
    qt_set_scroll_area_v_scroll_handler(M.timeline_audio_scroll, "audio_scroll_changed")

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
        log.event("headers_splitter_moved fired: pos=%d, index=%d", pos, index)
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(headers_main_splitter)
            log.event("  Syncing to timeline: sizes = {%d, %d}", sizes[1], sizes[2])
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, sizes)
            syncing = false
        end
    end
    log.event("Registering headers_splitter_moved handler...")
    qt_set_splitter_moved_handler(headers_main_splitter, "headers_splitter_moved")
    log.event("  Handler registered")

    -- When timeline video/audio boundary moves, update headers + persist ratio
    _G["timeline_splitter_moved"] = function(pos, index)
        log.event("timeline_splitter_moved fired: pos=%d, index=%d", pos, index)
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(vertical_splitter)
            log.event("  Syncing to headers: sizes = {%d, %d}", sizes[1], sizes[2])
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, sizes)
            -- Persist split ratio
            local total = sizes[1] + sizes[2]
            if total > 0 then
                state.set_video_audio_split_ratio(sizes[1] / total)
            end
            syncing = false
        end
    end
    log.event("Registering timeline_splitter_moved handler...")
    qt_set_splitter_moved_handler(vertical_splitter, "timeline_splitter_moved")
    log.event("  Handler registered")

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

    -- Initialize source-routing view preference and modifier-state tracking (T041, FR-029d).
    local home = assert(os.getenv("HOME"), "HOME env var required for source_routing_view pref")
    routing_pref.init(home .. "/.jve/source_routing_view.json")
    routing_state.init(routing_pref)

    -- Install a key-state watcher on the timeline container so holding Option/Alt
    -- flips effective_mode() from per_channel ↔ per_clip (FR-029d).
    -- Qt::Key_Alt = 0x01000023.  Per-clip collapsed rendering: T041a.
    -- luacheck: globals qt_install_key_state_watcher
    local alt_handler = register_global_handler("__timeline_alt_modifier_handler",
        function(event_type, key, _mods)
            if key ~= 0x01000023 then return end
            routing_state.set_modifier_held(event_type == "press")
        end)
    qt_install_key_state_watcher(container, alt_handler)

    log.event("Multi-view timeline panel created successfully")

    -- No initial tab when opening in the no-active-sequence state (feature 010).
    local initial_sequence_id = state.get_sequence_id and state.get_sequence_id() or nil
    if initial_sequence_id and initial_sequence_id ~= "" then
        ensure_tab_for_sequence(initial_sequence_id)
        update_tab_styles(initial_sequence_id)
    end

    if not tab_command_listener and command_manager and command_manager.add_listener then
        tab_command_listener = command_manager.add_listener(profile_scope.wrap(
            "timeline_panel.command_listener",
            function(event)
                handle_tab_command_event(event)
            end
        ))
    end

    -- Bidirectional playhead sync between timeline_monitor (engine) and timeline_state.
    -- last_viewer_playhead prevents feedback loops between the two listeners.
    local pm = require("ui.panel_manager")
    local tl_view = pm.get_sequence_monitor("timeline_monitor")

    local last_viewer_playhead = nil
    local viewer_seek_pending = false
    local viewer_seek_target = nil
    local VIEWER_SEEK_DEFER_MS = ui_constants.TIMELINE.VIEWER_SEEK_DEFER_MS or 1

    -- Viewer → State: engine position changes sync to timeline state.
    -- Fires during playback (every tick) and parked operations (arrow keys via seek_to_frame).
    -- set_playhead_position also calls ensure_playhead_visible (auto-scroll).
    tl_view:add_listener(function()
        local playhead_frame = tl_view.playhead
        last_viewer_playhead = playhead_frame
        state.set_playhead_position(playhead_frame)
    end)

    -- Load initial sequence into timeline_monitor (skipped when blank).
    -- pcall: bad clip data in a sequence must not crash the app.
    if initial_sequence_id and initial_sequence_id ~= "" then
        local load_ok, load_err = pcall(tl_view.load_sequence, tl_view, initial_sequence_id)
        if not load_ok then
            log.error("Failed to load initial sequence %s: %s", tostring(initial_sequence_id), tostring(load_err))
        end
    end

    -- After renderer updates widget content, apply any pending scroll restore.
    -- BUG: When switching from a sequence with fewer tracks (smaller widget height)
    -- to one with more tracks, the first render uses the stale height. The scroll
    -- restore succeeds (Qt accepts the value) but the drawing commands only cover
    -- the stale height region. The visible area at the new scroll position shows
    -- blank tracks until the user scrolls slightly (triggering a full repaint).
    -- Attempted fixes that did NOT work:
    --   - widget->update() / widget->repaint() after scroll restore
    --   - Deferred restore via singleShot(0) timer
    --   - Multi-pass retry (consume after 2+ renders)
    -- Root cause: the renderer draws commands clipped to widget height at render time.
    -- After SET_MIN_HEIGHT resizes the widget, Qt doesn't automatically repaint the
    -- newly allocated region with the correct commands.
    state.add_listener(function()
        local pending = M._pending_scroll_restore
        if not pending then return end
        if state.get_sequence_id() ~= pending.seq_id then
            M._pending_scroll_restore = nil
            return
        end
        M._pending_scroll_restore = nil
        M.restore_scroll_with_targets(pending.video, pending.audio)
    end)

    -- State → Viewer: when parked, state changes (from commands, ruler clicks, timecode entry)
    -- propagate to the viewer for frame display.
    -- Decimation: deferred via timer so timeline repaints aren't blocked by frame decode.
    state.add_listener(function()
        if not tl_view.engine:is_playing() and tl_view.sequence_id then
            local playhead = state.get_playhead_position()
            if playhead == last_viewer_playhead then return end
            viewer_seek_target = playhead
            if viewer_seek_pending then return end
            viewer_seek_pending = true
            qt_create_single_shot_timer(VIEWER_SEEK_DEFER_MS, function()
                viewer_seek_pending = false
                local target = viewer_seek_target
                if target == last_viewer_playhead then return end
                last_viewer_playhead = target
                tl_view:seek_to_frame(target)
            end)
        end
    end)

    return container
end

-- Zoom to fit content if sequence viewport is at factory defaults (never opened).
-- Sets playhead to first frame of content.
local function zoom_to_fit_if_first_open(sequence)
    local fr = sequence.frame_rate
    assert(fr and fr.fps_numerator and fr.fps_denominator,
        "zoom_to_fit_if_first_open: sequence missing frame_rate")
    local Sequence = require("models.sequence")
    local default_dur = Sequence.default_viewport_duration(fr.fps_numerator, fr.fps_denominator)
    if sequence.viewport_start_time ~= 0 or sequence.viewport_duration ~= default_dur then
        return  -- user has a saved viewport
    end

    local clips = state.get_clips()
    if not clips or #clips == 0 then
        return
    end

    local min_start, max_end
    for _, clip in ipairs(clips) do
        if not clip.is_gap then
            local s = clip.timeline_start
            local d = clip.duration
            assert(type(s) == "number", string.format(
                "zoom_to_fit_if_first_open: clip %s has non-number timeline_start: %s",
                tostring(clip.id), type(s)))
            assert(type(d) == "number", string.format(
                "zoom_to_fit_if_first_open: clip %s has non-number duration: %s",
                tostring(clip.id), type(d)))
            local e = s + d
            if not min_start or s < min_start then min_start = s end
            if not max_end or e > max_end then max_end = e end
        end
    end
    if not min_start or not max_end or max_end <= min_start then return end

    local ui_constants = require("core.ui_constants")
    local tc_floor = state.get_start_timecode_frame()
    local fit_start, fit_duration = ui_constants.compute_zoom_to_fit(min_start, max_end, tc_floor)
    state.set_viewport_duration(fit_duration)
    state.set_viewport_start_time(fit_start)
    state.set_playhead_position(min_start)
    state.flush_pending_notify()
end

--- Create a tab button for a sequence without activating it.
-- Use for batch loading background tabs at startup. The sequence is NOT
-- loaded into the timeline state, headers, or monitor until the user clicks
-- the tab (which calls load_sequence).
function M.open_tab(sequence_id)
    if not sequence_id or sequence_id == "" then return end
    if open_tabs[sequence_id] then return end  -- already exists
    -- Validate sequence exists before creating tab widget
    local Sequence = require("models.sequence")
    local seq = Sequence.load(sequence_id)
    if not seq then
        log.warn("open_tab: sequence %s not found in DB — skipping tab", tostring(sequence_id))
        return
    end
    ensure_tab_for_sequence(sequence_id)
    persist_open_tabs()
end

--- Build a merged tab_order: saved IDs first (validated), then any extras.
local function build_merged_tab_order(saved_order)
    local new_order = {}
    local seen = {}
    for _, id in ipairs(saved_order) do
        assert(open_tabs[id],
            string.format("restore_tab_order: saved ID %s has no open tab"
                .. " — delete/close path missed cleanup", tostring(id)))
        if not seen[id] then
            new_order[#new_order + 1] = id
            seen[id] = true
        end
    end
    -- Append any open tabs not in saved_order (e.g. tab opened since last save)
    for _, id in ipairs(tab_order) do
        if not seen[id] then
            new_order[#new_order + 1] = id
            seen[id] = true
        end
    end
    return new_order
end

--- Detach all tab widgets then re-insert in tab_order sequence.
local function reorder_tab_widgets()
    assert(tab_bar_tabs_layout, "reorder_tab_widgets: tab bar layout not created")
    assert(qt_constants.LAYOUT.INSERT_WIDGET, "reorder_tab_widgets: INSERT_WIDGET binding missing")
    for _, id in ipairs(tab_order) do
        local tab = assert(open_tabs[id], "reorder_tab_widgets: no tab for " .. tostring(id))
        assert(tab.container, "reorder_tab_widgets: tab missing container for " .. tostring(id))
        qt_constants.WIDGET.SET_PARENT(tab.container, nil)
    end
    for i, id in ipairs(tab_order) do
        local tab = open_tabs[id]
        qt_constants.LAYOUT.INSERT_WIDGET(tab_bar_tabs_layout, tab.container, i - 1)
    end
end

--- Reorder tabs to match a saved list. Reorders both the Lua tab_order
-- and the Qt tab bar widgets so visual order matches the model.
-- Called after startup restore to fix the order (initial tab was created first).
function M.restore_tab_order(saved_order)
    assert(type(saved_order) == "table", "restore_tab_order: saved_order must be a table")
    tab_order = build_merged_tab_order(saved_order)
    reorder_tab_widgets()
    persist_open_tabs()

    local current_sequence = state.get_sequence_id and state.get_sequence_id() or nil
    update_tab_styles(current_sequence)
    update_tab_scroll_arrows()
end

--- Return a copy of the open tab IDs in display order.
function M.get_open_tab_ids()
    local copy = {}
    for i, id in ipairs(tab_order) do
        copy[i] = id
    end
    return copy
end

function M.load_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    -- Guard: skip full reload if already loaded, but always restore scroll/splitter
    local current = state.get_sequence_id and state.get_sequence_id()
    if current == sequence_id and open_tabs[sequence_id] then
        M.restore_scroll_and_splitter()
        return
    end

    -- Persist outgoing scroll offsets NOW, while Qt scroll areas still have
    -- the correct content and range for the outgoing sequence. Must happen
    -- before state.init or any widget rebuild.
    state.persist_scroll_offsets()

    log.event("Loading sequence %s into timeline panel", sequence_id)
    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)
    assert(sequence, "timeline_panel.load_sequence: failed to load sequence " .. tostring(sequence_id))
    local project_id = sequence.project_id
    assert(project_id and project_id ~= "", "timeline_panel.load_sequence: missing project_id for sequence " .. tostring(sequence_id))
    state.init(sequence_id, project_id)

    -- First-open detection: if viewport is at defaults, zoom to fit content
    zoom_to_fit_if_first_open(sequence)

    database.set_project_setting(project_id, "last_open_sequence_id", sequence_id)

    if command_manager and command_manager.activate_timeline_stack then
        command_manager.activate_timeline_stack(sequence_id)
    end

    -- Suspend bottom-anchor filters during rebuild — their async singleShot(0)
    -- callbacks would overwrite restored scroll positions
    if M.timeline_video_scroll then
        qt_suspend_scroll_area_anchor(M.timeline_video_scroll, true)
    end
    if M.header_video_scroll then
        qt_suspend_scroll_area_anchor(M.header_video_scroll, true)
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

    -- Store pending scroll targets. The renderer (which fires async via
    -- notify_listeners) will apply these AFTER it updates widget content/heights.
    -- Setting scroll before the render would show stale content at the new position.
    M._pending_scroll_restore = {
        seq_id = sequence_id,
        video = sequence.video_scroll_offset or 0,
        audio = sequence.audio_scroll_offset or 0,
    }

    -- Resume anchor filters after restore
    if M.timeline_video_scroll then
        qt_suspend_scroll_area_anchor(M.timeline_video_scroll, false)
    end
    if M.header_video_scroll then
        qt_suspend_scroll_area_anchor(M.header_video_scroll, false)
    end

    local tab_existed = open_tabs[sequence_id] ~= nil
    ensure_tab_for_sequence(sequence_id)
    update_tab_styles(sequence_id)
    if not tab_existed then
        persist_open_tabs()
    end

    -- Load sequence into the timeline monitor
    local pm = require("ui.panel_manager")
    local tl_view = pm.get_sequence_monitor("timeline_monitor")
    tl_view:load_sequence(sequence_id)
end

--- Restore scroll offsets from explicit target values (immune to async Qt clobbering).
function M.restore_scroll_with_targets(v_scroll, a_scroll)
    if M.timeline_video_scroll then
        log.event("Restoring video scroll offset: %d", v_scroll)
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_video_scroll, v_scroll)
    end
    if M.timeline_audio_scroll then
        log.event("Restoring audio scroll offset: %d", a_scroll)
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_audio_scroll, a_scroll)
    end
    if M.vertical_splitter and M.headers_main_splitter then
        local ratio = state.get_video_audio_split_ratio()
        log.event("Restoring split ratio: %.3f", ratio)
        local total = qt_constants.LAYOUT.GET_SPLITTER_SIZES(M.vertical_splitter)
        local total_height = total[1] + total[2]
        if total_height > 0 then
            local video_h = math.floor(total_height * ratio + 0.5)
            local audio_h = total_height - video_h
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.vertical_splitter, {video_h, audio_h})
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.headers_main_splitter, {video_h, audio_h})
        end
    end
end

--- Restore scroll offsets and splitter ratio from persisted state.
-- Called after sequence load and after initial panel creation.
function M.restore_scroll_and_splitter()
    if M.timeline_video_scroll then
        local v_off = state.get_video_scroll_offset()
        log.event("Restoring video scroll offset: %d", v_off)
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_video_scroll, v_off)
    end
    if M.timeline_audio_scroll then
        local a_off = state.get_audio_scroll_offset()
        log.event("Restoring audio scroll offset: %d", a_off)
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_audio_scroll, a_off)
    end
    if M.vertical_splitter and M.headers_main_splitter then
        local ratio = state.get_video_audio_split_ratio()
        log.event("Restoring split ratio: %.3f", ratio)
        local total = qt_constants.LAYOUT.GET_SPLITTER_SIZES(M.vertical_splitter)
        local total_height = total[1] + total[2]
        if total_height > 0 then
            local video_h = math.floor(total_height * ratio + 0.5)
            local audio_h = total_height - video_h
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.vertical_splitter, {video_h, audio_h})
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.headers_main_splitter, {video_h, audio_h})
        end
    end
end

--- Snapshot current layout state for inheritance by new projects.
function M.snapshot_layout()
    local snapshot = {}
    if M.vertical_splitter then
        local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(M.vertical_splitter)
        local total = sizes[1] + sizes[2]
        if total > 0 then
            snapshot.split_ratio = sizes[1] / total
        end
    end
    if M.timeline_video_scroll then
        snapshot.video_scroll = qt_constants.CONTROL.GET_SCROLL_AREA_V_SCROLL(M.timeline_video_scroll)
    end
    if M.timeline_audio_scroll then
        snapshot.audio_scroll = qt_constants.CONTROL.GET_SCROLL_AREA_V_SCROLL(M.timeline_audio_scroll)
    end
    return snapshot
end

--- Apply inherited layout from a previous project.
-- Writes values to state AND to the Qt widgets, then persists to DB.
function M.apply_layout_if_default(snapshot)
    if not snapshot then return end

    -- Apply splitter ratio
    if snapshot.split_ratio and M.vertical_splitter and M.headers_main_splitter then
        local total = qt_constants.LAYOUT.GET_SPLITTER_SIZES(M.vertical_splitter)
        local total_height = total[1] + total[2]
        if total_height > 0 then
            local video_h = math.floor(total_height * snapshot.split_ratio + 0.5)
            local audio_h = total_height - video_h
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.vertical_splitter, {video_h, audio_h})
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.headers_main_splitter, {video_h, audio_h})
            state.set_video_audio_split_ratio(snapshot.split_ratio)
        end
    end

    -- Apply scroll offsets
    if snapshot.video_scroll and M.timeline_video_scroll then
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_video_scroll, snapshot.video_scroll)
        state.set_video_scroll_offset(snapshot.video_scroll)
    end
    if snapshot.audio_scroll and M.timeline_audio_scroll then
        qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(M.timeline_audio_scroll, snapshot.audio_scroll)
        state.set_audio_scroll_offset(snapshot.audio_scroll)
    end
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

--- Clear state that shouldn't persist across projects
function M.on_project_change()
    -- Close each tab's UI elements
    for _, tab in pairs(open_tabs) do
        if qt_constants.WIDGET.SET_PARENT then
            qt_constants.WIDGET.SET_PARENT(tab.container, nil)
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
    end
    open_tabs = {}
    tab_order = {}
    track_button_refs = {}
end

-- Register for project_changed signal
Signals.connect("project_changed", M.on_project_change, 50)

-- ============================================================================
-- View interface
-- ============================================================================

function M:navigate_to_clip(clip_id)
    assert(clip_id, "timeline_panel:navigate_to_clip: clip_id required")
    local clips = timeline_state.get_clips and timeline_state.get_clips() or {}
    for _, clip in ipairs(clips) do
        if clip.id == clip_id then
            local frame = clip.timeline_start_frame or clip.timeline_start or 0
            timeline_state.set_playhead_position(frame)
            timeline_state.surface_playhead()
            timeline_state.set_selection({{id = clip_id}})
            return
        end
    end
end

function M:select_clips(clip_ids)
    assert(clip_ids, "timeline_panel:select_clips: clip_ids required")
    local sel = {}
    for _, id in ipairs(clip_ids) do
        sel[#sel + 1] = {id = id}
    end
    timeline_state.set_selection(sel)
end

function M:get_clips()
    local raw = timeline_state.get_clips and timeline_state.get_clips() or {}
    local clips = {}
    for _, clip in ipairs(raw) do
        clips[#clips + 1] = {
            id = clip.id,
            name = clip.name or "",
            codec = clip.codec or "",
            fps = clip.fps_float or 0,
            duration = clip.duration_frames or clip.duration or 0,
            enabled = clip.enabled ~= false,
            volume = clip.volume or 1.0,
            timeline_start_frame = clip.timeline_start_frame or clip.timeline_start or 0,
            track_id = clip.track_id or "",
            properties = {},
        }
    end
    table.sort(clips, function(a, b)
        return a.timeline_start_frame < b.timeline_start_frame
    end)
    return clips
end

return M
