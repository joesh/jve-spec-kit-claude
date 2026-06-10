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
-- luacheck: globals qt_set_scroll_area_v_user_scroll_handler qt_set_scroll_area_v_range_handler

local View = require("ui.view")
local M = View.new("timeline")

-- Row metrics (sizing constants + pure helpers) live in their own module
-- so tests can exercise them without pulling Qt into the require graph.
-- Re-exposed below as M.metrics for the panel's public surface.
local metrics = require("ui.timeline.timeline_panel_metrics")
local MIN_TRACK_HEIGHT      = metrics.MIN_TRACK_HEIGHT
local RESIZE_EDGE_PX        = metrics.RESIZE_EDGE_PX
local TRAILING_ALIGNMENT_PX = metrics.TRAILING_ALIGNMENT_PX
local content_to_header     = metrics.content_to_header
M.metrics = metrics

-- Alias for timeline_state. Bound at module scope so file-scope signal
-- listeners (and the panel-resolving commands that route through them)
-- don't have to wait for M.create to run before `state.X` is callable.
-- M.create previously rebound this; that rebinding is redundant (it's
-- always the same module) and used to mask a load-order bug where
-- `state` was nil if any code touched it before layout.lua wired panels.
local state = timeline_state
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

local colors = assert(ui_constants.COLORS,
    "timeline_panel: ui_constants.COLORS missing — required for UI chrome colors")
-- Helper: fetch a required color or assert with key name. Removes the
-- widespread `colors.X or "#hex"` fallback pattern (rule 2.13). Production
-- always supplies every key referenced below; the assert is a contract
-- check, not a fallback.
local function color(key)
    return assert(colors[key],
        "timeline_panel: ui_constants.COLORS." .. key .. " is required")
end
local selection_color = color("SELECTION_BORDER_COLOR")
local inactive_text_color = color("GENERAL_LABEL_COLOR")
local active_text_color = selection_color
local hover_text_color = color("WHITE_TEXT_COLOR")
local source_tab_color = "#5cbacc"  -- --src accent from design mockup v4

-- Tab styling per spec FR-002: source vs record distinction is always-on
-- (determined by tab type, not just active state). Caller must pass an
-- explicit background ("transparent" for record tabs, accent hex for the
-- source tab). No fallback (rule 2.13).
local function build_tab_button_style(text_color, border_color, font_weight, background)
    assert(type(background) == "string" and background ~= "",
        "build_tab_button_style: background required (e.g. 'transparent' or '#1e3338')")
    return string.format([[
        QPushButton {
            background: %s;
            color: %s;
            border: none;
            border-bottom: 2px solid %s;
            padding: 4px 10px;
            font-weight: %s;
        }
        QPushButton:hover {
            color: %s;
        }
    ]], background, text_color, border_color, font_weight, hover_text_color)
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

-- The seq_id currently holding the source-kind panel tab, or nil if
-- there is no source tab open. The strip's source tab is a singleton
-- widget that reloads in place when the source master changes (A→B);
-- on the panel side we mirror that singleton semantics by REKEYING
-- the open_tabs entry (A's bag of widgets is re-pointed at B) instead
-- of creating a new entry under key B. This keeps the invariant
--   open_tabs[X].strip_tab.sequence_id == X
-- so the C++ strip and the Lua-side open_tabs cannot drift out of
-- sync. The earlier auto_source_tab_id close-on-prev heuristic was a
-- patch over the missing invariant (destroyed the source widget every
-- swap and left orphan tabs when the heuristic missed); rekey makes
-- the orphan impossible by construction.
local source_tab_seq_id = nil

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
-- in the playhead TC entry. Returns nil when no sequence is displayed
-- (callers degrade to empty TC display / "No sequence displayed" error);
-- asserts loudly when a sequence IS active but its fps metadata is
-- malformed (rule 1.14 — never invent a default rate).
local function get_sequence_frame_rate_for_timecode()
    local rate = state and state.get_sequence_frame_rate and state.get_sequence_frame_rate() or nil
    if not rate then return nil end
    assert(rate.fps_numerator and rate.fps_denominator,
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
    local rate = get_sequence_frame_rate_for_timecode()
    if not rate then return "" end
    local playhead = assert(state.get_playhead_position(), "timeline_panel: get_playhead_position returned nil")
    local frame_utils = require("core.frame_utils")
    return frame_utils.format_timecode(playhead, rate)
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
    local field_bg = color("FIELD_BACKGROUND_COLOR")
    local field_border = color("FIELD_BORDER_COLOR")
    local field_text = color("FIELD_TEXT_COLOR")
    local focus_bg = color("FIELD_FOCUS_BACKGROUND_COLOR")
    local focus_border = color("FOCUS_BORDER_COLOR")
    local fonts = assert(ui_constants.FONTS,
        "timeline_panel: ui_constants.FONTS missing — required for TIMECODE_FONT_SIZE")
    local font_size = assert(fonts.TIMECODE_FONT_SIZE,
        "timeline_panel: ui_constants.FONTS.TIMECODE_FONT_SIZE missing")
    local selection_bg = selection_color
    local selection_text = color("WHITE_TEXT_COLOR")

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
    if not rate then return nil, "No sequence displayed" end
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
        sequence_id = state.get_movement_target_sequence_id(),
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
    local sequence_id = timeline_state.get_tab_strip():active_sequence_id()
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

-- Tab background palette per spec FR-002. The source-vs-record distinction
-- is always-on (it identifies tab type), so the source tab carries a blue
-- background even when not active. The record tab keeps a transparent
-- background to match JVE's existing visual language.
-- Tab-background tints, each at half-density vs. the original 015 palette
-- (Joe 2026-05-13). Lightness profile preserved; saturation halved by
-- mixing 50/50 with the panel neutral so the strip reads as "blue tab +
-- red tabs" without screaming. Source = teal, record = selection-red.
local SOURCE_TAB_BG_INACTIVE = "#242e31"   -- dim teal when source tab not displayed
local SOURCE_TAB_BG_ACTIVE   = "#2b4146"   -- brighter teal when source tab displayed
local RECORD_TAB_BG_INACTIVE = "#312626"   -- dim red when record tab not displayed
local RECORD_TAB_BG_ACTIVE   = "#442f2c"   -- brighter red when record tab displayed

-- "Selected"/highlighted in the tab strip = the DISPLAYED tab (the one
-- whose content the timeline view renders). NOT the active record tab —
-- those can differ when the SourceTab is displayed and a record tab is
-- still the edit target (FR-005).
local function apply_tab_style(tab, is_displayed, is_source)
    if not tab or not tab.button or not qt_constants.PROPERTIES.SET_STYLE then
        return
    end
    local accent = is_source and source_tab_color or selection_color
    local text_color = is_displayed and accent or inactive_text_color
    local border_color = is_displayed and accent or "transparent"
    local font_weight = is_displayed and "bold" or "normal"
    -- Both tab kinds carry a tinted background that identifies their type
    -- at a glance: teal = source, red = record. Active/inactive variants
    -- give an additional brightness cue beyond the displayed-tab underline.
    -- Text stays at the accent hue even when not displayed, so the strip
    -- reads as "blue tab + red tabs" rather than a sea of grey labels.
    local background
    if is_source then
        background = is_displayed and SOURCE_TAB_BG_ACTIVE or SOURCE_TAB_BG_INACTIVE
    else
        background = is_displayed and RECORD_TAB_BG_ACTIVE or RECORD_TAB_BG_INACTIVE
    end
    text_color = accent
    qt_constants.PROPERTIES.SET_STYLE(tab.button,
        build_tab_button_style(text_color, border_color, font_weight, background))
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

-- Persisted setting key used to remember which open tab is the SourceTab
-- across restarts. The live answer comes from
-- source_monitor:get_loaded_master_seq_id(), but on restart the source
-- monitor hasn't been re-populated yet — so without this fallback,
-- ensure_tab_for_sequence would mis-classify the master id as a record
-- tab and the strip would render it as a normal record (Joe 2026-05-13).
local SOURCE_TAB_SETTING = "source_tab_sequence_id"

local function get_persisted_source_tab_seq_id()
    local project_id = state.get_project_id()
    if not project_id or project_id == "" then return nil end
    local stored = database.get_project_setting(project_id, SOURCE_TAB_SETTING)
    if type(stored) ~= "string" or stored == "" then return nil end
    return stored
end

local function set_persisted_source_tab_seq_id(seq_id)
    local project_id = state.get_project_id()
    if not project_id or project_id == "" then return end
    -- Empty string clears (database.set_project_setting normalizes nil→delete).
    database.set_project_setting(project_id, SOURCE_TAB_SETTING, seq_id or "")
end

local function get_source_master_seq_id()
    local ok, pm = pcall(require, "ui.panel_manager")
    if not ok or not pm then return nil end
    local ok2, monitor = pcall(pm.get_sequence_monitor, "source_monitor")
    if not ok2 or not monitor then return nil end
    local live = monitor:get_loaded_master_seq_id()
    if live and live ~= "" then return live end
    -- Source monitor hasn't been loaded yet (typical at restart before
    -- ShowSourceTab or browser-click fires); fall through to the persisted
    -- last-known source tab so tabs reconstruct with the right kind.
    return get_persisted_source_tab_seq_id()
end

-- Drive the strip's "selected" appearance off the DISPLAYED tab, not the
-- active record. When the SourceTab is displayed, the source-tab button
-- gets the underline; the active record tab (still receiving edits)
-- drops to inactive style. Callers may pass nil; nothing matches → all
-- inactive.
local function update_tab_styles(displayed_sequence_id)
    local source_seq_id = get_source_master_seq_id()
    for id, tab in pairs(open_tabs) do
        apply_tab_style(tab,
            displayed_sequence_id ~= nil and id == displayed_sequence_id,
            id == source_seq_id)
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
        assert(clip.source_sequence_id and clip.source_sequence_id ~= "",
            string.format("handle_drop_on_blank_timeline: clip[%d] missing "
                .. "source_sequence_id", index))
        assert(type(clip.duration) == "number" and clip.duration > 0,
            string.format("handle_drop_on_blank_timeline: clip[%d] duration "
                .. "must be a positive integer", index))

        local result = command_manager.execute_interactive("Overwrite", {
            project_id            = project_id,
            sequence_id           = seq_id,
            source_sequence_id    = clip.source_sequence_id,
            target_video_track_id = v1_track_id,
            sequence_start_frame  = playhead,
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
---     clips     = { {sequence_id=..., name=..., duration=...,
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

    local active_seq = state.get_tab_strip():active_sequence_id()
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

    -- Detect source-tab close BEFORE the open_tabs entry is removed: the
    -- visibility-changed signal needs to fire so FR-001b dismissal tracking
    -- (and any other source-tab listeners) can respond. A tab is the
    -- source tab iff its seq_id matches the source monitor's loaded master.
    local was_source_tab = (sequence_id == get_source_master_seq_id())

    -- Persist any pending view-state for the displayed sequence BEFORE the
    -- strip drops its displayed pointer below. flush_state_to_db reads the
    -- strip to decide which row to write; once the strip clears we can no
    -- longer name the outgoing sequence.
    if state.get_displayed_tab_id and state.get_displayed_tab_id() == sequence_id
       and state.persist_state_to_db then
        state.persist_state_to_db(true)
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

    -- Mirror the close into the TimelineTabStrip — but ONLY if the strip
    -- still "owns" this seq. When source master transitions A→B, the strip's
    -- source-tab singleton is reloaded in place: strip_tab.sequence_id is
    -- now B even though open_tabs[A] still holds a reference to it. If we
    -- naively closed via state here we'd close B (current source)
    -- instead of just doing Qt cleanup for A. The seq_id check guards that.
    assert(tab.strip_tab, string.format(
        "close_tab: open_tabs[%s] missing strip_tab — strip/open_tabs drift",
        tostring(sequence_id)))
    -- Capture the active-sequence pointer BEFORE close_displayed_tab runs.
    -- That helper may call core.clear() (when the strip ends up empty),
    -- which sets data.state.sequence_id = nil — if we read current_sequence
    -- after that, the active-closing branch below misfires (nil != seq_id)
    -- and unload_sequence never runs, leaving last_open_sequence_id stale.
    local current_sequence_before = state.get_tab_strip():active_sequence_id()

    if tab.strip_tab.sequence_id == sequence_id then
        if tab.strip_tab.kind == "source" then
            -- Mirror into the persisted setting so a subsequent restart
            -- doesn't resurrect this seq as a SourceTab.
            set_persisted_source_tab_seq_id(nil)
        end
        -- Delegate strip close + timeline-view re-pull (if displayed) to
        -- the state layer. close_displayed_tab handles the asymmetry
        -- where the closed tab WAS displayed but was NOT active
        -- (source-tab case) by calling activate_displayed on the new
        -- displayed sequence.
        timeline_state.close_displayed_tab(sequence_id)
    end

    open_tabs[sequence_id] = nil
    remove_from_tab_order(sequence_id)
    if source_tab_seq_id == sequence_id then
        source_tab_seq_id = nil
    end

    if current_sequence_before == sequence_id then
        local next_id = tab_order[#tab_order] or tab_order[1]
        if next_id then
            M.load_sequence(next_id)
        else
            -- Last tab closed — enter the no-active-sequence state.
            M.unload_sequence()
        end
    else
        -- close_displayed_tab already refreshed the timeline view if the
        -- closed tab was displayed. Tab styling tracks DISPLAYED, not active.
        update_tab_styles(timeline_state.get_displayed_tab_id())
    end
    update_tab_scroll_arrows()
    persist_open_tabs()

    -- Reclaim keyboard focus on the timeline view. When a tab's close
    -- button widget is destroyed, Qt's default focus-fallback lands on
    -- the next-in-tab-order widget — for this layout that's the
    -- timecode entry (TSO 2026-05-17). After a close the user is back
    -- to driving the timeline (arrow keys, JKL, mark in/out), so focus
    -- belongs on the clips area, not the typing field.
    focus_timeline_view()

    if was_source_tab then
        Signals.emit("source_tab_visibility_changed", false)
    end
end

-- Expose close_tab programmatically (for tests + any future script callers).
M.close_tab = close_tab

-- Push a new display name onto an existing tab entry's button when it
-- differs from the cached name. Idempotent; both the rename branch of
-- ensure_tab_for_sequence and rekey_source_tab go through this so the
-- Qt SET_TEXT call site lives in exactly one place.
local function update_tab_display_name(entry, new_name)
    if new_name == entry.name then return end
    qt_constants.PROPERTIES.SET_TEXT(entry.button, new_name)
    entry.name = new_name
end

-- Move the existing source-tab panel entry from key old_id to key new_id.
-- Mirrors the C++ TimelineTabStrip's source-singleton reload-in-place: the
-- same container/buttons/handlers are re-pointed at the new master sequence
-- instead of a new container being created. Handler closures dereference
-- entry.seq_box.id so updating that field rebinds clicks/closes to new_id
-- without recreating handlers. The downstream existing-branch in
-- ensure_tab_for_sequence is the authoritative writer for source_tab_seq_id
-- and the persisted source-tab setting; this function only reshapes the
-- open_tabs map and tab_order.
local function rekey_source_tab(old_id, new_id)
    local entry = open_tabs[old_id]
    assert(entry, string.format(
        "rekey_source_tab: open_tabs[%s] missing — source_tab_seq_id "
        .. "drifted from open_tabs", tostring(old_id)))
    assert(entry.seq_box, "rekey_source_tab: entry missing seq_box — "
        .. "handler-closure rebind requires per-entry seq_box")
    assert(not open_tabs[new_id], string.format(
        "rekey_source_tab: open_tabs[%s] already exists — caller must "
        .. "resolve collision via close_tab before rekey", tostring(new_id)))
    entry.seq_box.id = new_id
    update_tab_display_name(entry, get_sequence_display_name(new_id))
    for i, id in ipairs(tab_order) do
        if id == old_id then tab_order[i] = new_id; break end
    end
    open_tabs[old_id] = nil
    open_tabs[new_id] = entry
end

-- Restore the open_tabs[X].strip_tab.sequence_id == X invariant when the
-- source master moved from source_tab_seq_id to new_seq_id. Two sub-cases:
--   (a) open_tabs[new_seq_id] absent → rekey in place (preferred; no widget
--       churn; common path for F-press across media types).
--   (b) open_tabs[new_seq_id] present (user already had a record tab for
--       this seq) → close the OLD source widget. The strip's source
--       singleton has been reloaded in place to new_seq_id, so close_tab's
--       guard (strip_tab.sequence_id == sequence_id) prevents it from
--       touching the singleton; only panel-side Qt cleanup runs. The
--       existing-branch repair downstream then promotes open_tabs[new_seq_id]
--       to source kind.
-- Must run BEFORE strip dispatch so the strip's reload never leaves an
-- orphaned panel container behind, regardless of which code path drove
-- the source change.
local function reconcile_source_tab_swap(new_seq_id)
    if not source_tab_seq_id or source_tab_seq_id == new_seq_id then return end
    if open_tabs[new_seq_id] then
        close_tab(source_tab_seq_id)
    else
        rekey_source_tab(source_tab_seq_id, new_seq_id)
    end
end

ensure_tab_for_sequence = function(sequence_id)
    if not tab_bar_tabs_layout or not sequence_id or sequence_id == "" then
        return
    end

    local is_source_request = (sequence_id == get_source_master_seq_id())
    if is_source_request then reconcile_source_tab_swap(sequence_id) end

    -- Keep the TimelineTabStrip in sync on every call. Idempotent on the
    -- strip side: open_record_tab returns an existing tab for this seq if
    -- any; open_source_tab reloads the singleton in place. Hoisted above
    -- the early-return so a re-entrant call after a strip reset
    -- re-establishes the strip-side tab.
    local strip = timeline_state.get_tab_strip()
    local strip_tab
    if is_source_request then
        strip_tab = strip:open_source_tab(sequence_id)
        -- Persist so the SourceTab kind survives an editor restart even
        -- before the source monitor reloads — see SOURCE_TAB_SETTING.
        set_persisted_source_tab_seq_id(sequence_id)
    else
        strip_tab = strip:open_record_tab(sequence_id)
    end

    local display_name = get_sequence_display_name(sequence_id)
    local existing = open_tabs[sequence_id]
    if existing then
        existing.strip_tab = strip_tab  -- repair if drifted
        update_tab_display_name(existing, display_name)
        if is_source_request then source_tab_seq_id = sequence_id end
        return
    end


    local container = qt_constants.WIDGET.CREATE()
    local container_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(container_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(container_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, container_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Fixed", "Fixed")

    local text_button = qt_constants.WIDGET.CREATE_BUTTON(display_name)
    -- Initial style: neutral inactive (apply_tab_style is invoked immediately
    -- after creation in update_tab_styles to apply the type-specific palette).
    qt_constants.PROPERTIES.SET_STYLE(text_button,
        build_tab_button_style(inactive_text_color, "transparent", "normal", "transparent"))
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(text_button, "Fixed", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(container_layout, text_button)

    local close_button = qt_constants.WIDGET.CREATE_BUTTON("×")
    qt_constants.PROPERTIES.SET_STYLE(close_button, build_close_button_style(inactive_text_color))
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(close_button, "Fixed", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(container_layout, close_button)

    -- Tab-click routing (FR-005). A tab is THE source tab iff its seq_id
    -- equals the source monitor's currently-loaded master — this is a
    -- dynamic property of the source monitor, NOT of seq.kind (a master
    -- can live in a record tab; a nested can be the source tab). Both
    -- pointer-update entry points emit the appropriate signals; the
    -- displayed_tab_changed listener does the timeline-view rebuild.
    --
    -- The handler closures dereference seq_box.id rather than capturing
    -- sequence_id directly so the source-tab singleton can be REKEYED
    -- (rekey_source_tab) on a source master swap without recreating
    -- handlers. rekey_source_tab mutates seq_box.id; both handlers
    -- below see the new value on next invocation.
    local seq_box = { id = sequence_id }
    local handler_name = register_tab_handler(function()
        local sid = seq_box.id
        local current_displayed = state and state.get_displayed_tab_id and state.get_displayed_tab_id()
        if current_displayed == sid then return end   -- already displayed
        if sid == get_source_master_seq_id() then
            timeline_state.switch_to_source_tab(sid)
        else
            M.load_sequence(sid)
        end
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(text_button, handler_name)

    local close_handler_name = register_tab_handler(function()
        close_tab(seq_box.id)
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(close_button, close_handler_name)

    -- Source tab is forced leftmost (FR-001 singleton-first). Other tabs
    -- append at the end. Match Qt layout order to the Lua tab_order
    -- model on insertion — without this, opening a source tab AFTER a
    -- record tab put the source visually to the right while tab_order
    -- said position 1, and only restore_tab_order on next startup fixed it.
    if strip_tab.kind == "source" then
        assert(qt_constants.LAYOUT.INSERT_WIDGET,
            "open_tab: LAYOUT.INSERT_WIDGET binding required for source-tab insert")
        qt_constants.LAYOUT.INSERT_WIDGET(tab_bar_tabs_layout, container, 0)
        table.insert(tab_order, 1, sequence_id)
    else
        qt_constants.LAYOUT.ADD_WIDGET(tab_bar_tabs_layout, container)
        table.insert(tab_order, sequence_id)
    end

    open_tabs[sequence_id] = {
        container = container,
        button = text_button,
        close_button = close_button,
        name = display_name,
        handler = handler_name,
        close_handler = close_handler_name,
        strip_tab = strip_tab,
        seq_box = seq_box,  -- handler-closure dereferences this; updated by rekey_source_tab
    }
    if is_source_request then source_tab_seq_id = sequence_id end
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
    local active = state.get_tab_strip():active_sequence_id() or nil
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
        assert(type(created_sequence_ids) == "table",
            "timeline_panel on_command_executed: ImportFCP7XML must carry created_sequence_ids table")

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
        assert(type(created_sequence_ids) == "table",
            "timeline_panel on_command_executed: ImportResolveTimeline must carry created_sequence_ids table")

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
            local active = state.get_tab_strip():active_sequence_id() or nil
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
            update_tab_styles(timeline_state.get_displayed_tab_id())
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
    assert(type(background_color) == "string" and background_color ~= "",
        "build_track_header_stylesheet: background_color required (caller must " ..
        "pick a color — fallback removed per rule 2.13)")
    return string.format([[
        QWidget {
            background: %s;
            border-left: 1px solid #222232;
            border-right: 1px solid #222232;
            border-top: 0px;
            border-bottom: 0px;
        }
    ]], background_color)
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
                background: %s; color: #ffffff;
                border: 1px solid #333333;
                padding: 1px 3px; font-size: 10px; font-weight: bold;
            }
        ]], active_color)
    end
    return [[
        QPushButton {
            background: #2a2a2a; color: #888888;
            border: 1px solid #333333; padding: 1px 3px; font-size: 10px;
        }
        QPushButton:hover { background: #3a3a3a; color: #cccccc; }
    ]]
end

-- Track header column widths (px) — set once at widget creation via SET_MIN/MAX_WIDTH.
-- CSS never specifies width; geometry is owned here, appearance is owned by CSS.
local HDR = {
    SRC  = 28,   -- src-id patch button
    REC  = 28,   -- rec-id patch button
    LOCK = 20,   -- lock toggle
    SYNC = 24,   -- sync-mode toggle (slightly wider to fit larger glyph)
    SM   = 16,   -- each solo/mute button (stacked vertically)
    WAVE = TRAILING_ALIGNMENT_PX,  -- waveform toggle (audio only)
}

-- Sync-mode: cycling order and icon glyphs (unicode stand-ins; proper SVG via QIcon pending)
local SYNC_CYCLE = { off = "ripple", ripple = "cut", cut = "off" }
local SYNC_ICONS = { off = "🚫", ripple = "∿", cut = "/" }

local function build_sm_btn_stylesheet(active, active_color)
    if active and active_color then
        return string.format([[
            QPushButton {
                background: %s; color: #ffffff;
                border: 1px solid #333333; padding: 0px; font-size: 9px; font-weight: bold;
            }
        ]], active_color)
    end
    return [[
        QPushButton {
            background: #2a2a2a; color: #888888;
            border: 1px solid #333333; padding: 0px; font-size: 9px;
        }
        QPushButton:hover { background: #3a3a3a; color: #cccccc; }
    ]]
end

-- Empty src-id slot: geometry held by Qt widget-level HDR.SRC width set at creation.
-- No border, no color — purely invisible while preserving column alignment.
local SRC_BTN_EMPTY_STYLESHEET = [[
    QPushButton { background: transparent; border: none; color: transparent; }
]]

local function build_id_btn_stylesheet(filled, accent)
    if filled then
        return string.format([[
            QPushButton {
                background: %s; color: #ffffff;
                border: 1px solid %s; padding: 0px 2px;
                font-size: 11px; font-weight: bold;
            }
        ]], accent, accent)
    end
    return string.format([[
        QPushButton {
            background: transparent; color: %s;
            border: 1px solid %s; padding: 0px 2px;
            font-size: 11px; font-weight: bold;
        }
        QPushButton:hover { color: #ffffff; border-color: #aaaaaa; }
    ]], accent, accent)
end

local function build_sync_mode_btn_stylesheet(mode)
    -- Match the lock-button neighbour: same neutral background + border
    -- so the cell doesn't pop out of the header row. State is read off
    -- the glyph, not a colour tint. Per-mode font-size because the text
    -- glyphs (∿, /) need a bump to be legible while 🚫 is an emoji that
    -- already renders large.
    local font_sizes = { off = 11, ripple = 14, cut = 14 }
    local font_size = font_sizes[mode]
    assert(font_size, "build_sync_mode_btn_stylesheet: unknown sync mode " .. tostring(mode))
    return string.format([[
        QPushButton {
            background: #2a2a2a; color: #cccccc;
            border: 1px solid #333333; padding: 0px; font-size: %dpx;
        }
        QPushButton:hover { background: #3a3a3a; color: #ffffff; }
    ]], font_size)
end

local track_btn_handler_seq = 0
-- Register a Lua callback under a generated global name and return the name.
-- The wrapper forwards args AND return values: most callers are fire-and-forget
-- click handlers that return nothing, but drag-source payload providers
-- return a mime payload string that the C++ filter consumes. Swallowing the
-- return value would silently break that path.
local function register_track_btn_handler(callback)
    track_btn_handler_seq = track_btn_handler_seq + 1
    local name = "__track_btn_handler_" .. tostring(track_btn_handler_seq)
    _G[name] = function(...)
        return callback(...)
    end
    return name
end

--- Wire a toggle-preference click: dispatches ToggleTrackPreference. Visual
-- update is pull-on-signal — the `track_preference_changed` listener
-- (registered below) restyles the widget when the command's signal fires.
-- The handler must NOT restyle directly: it would push the WRONG style for
-- S/M stack buttons (which use build_sm_btn_stylesheet, not the header
-- style) and would double-render every click.
local command_dispatch = require("core.command_dispatch")

local function wire_toggle_preference(btn, track_id, property, _active_color)
    local handler = register_track_btn_handler(function()
        assert(Track.load(track_id), string.format(
            "wire_toggle_preference: track %s not found", tostring(track_id)))
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_toggle_preference: no project_id")
        command_dispatch.execute_or_fail("ToggleTrackPreference", {
            track_id = track_id, property = property, project_id = project_id,
        }, "track-header " .. property .. " click")
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(btn, handler)
    return handler
end

--- Wire the audio "W" waveform-display toggle. Mirrors the other
-- wire_* helpers: dispatch only, no direct restyle. The
-- `track_waveform_display_changed` listener restyles the button when the
-- command fires (rule 3.0 — pull-on-signal).
local function wire_waveform_display_toggle(btn, track_id)
    local handler = register_track_btn_handler(function()
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_waveform_display_toggle: no project_id (track_id="
            .. tostring(track_id) .. ")")
        command_dispatch.execute_or_fail("ToggleTrackWaveformDisplay", {
            track_id = track_id, project_id = project_id,
        }, "waveform-display btn click")
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(btn, handler)
    return handler
end

--- Wire a sync-mode cycle click: Off→Ripple→Cut→Off via SetSyncMode. Visual
-- update lands via the `sync_mode_changed` listener; this handler only
-- dispatches.
local function wire_sync_mode_cycle(btn, track_id)
    local handler = register_track_btn_handler(function()
        local t = Track.load(track_id)
        assert(t, string.format("wire_sync_mode_cycle: track %s not found", tostring(track_id)))
        local next_mode = SYNC_CYCLE[t.sync_mode]
        assert(next_mode, string.format(
            "wire_sync_mode_cycle: unrecognised sync_mode '%s' on track %s",
            tostring(t.sync_mode), tostring(track_id)))
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_sync_mode_cycle: no project_id")
        command_dispatch.execute_or_fail("SetSyncMode", {
            track_id = track_id, sync_mode = next_mode, project_id = project_id,
        }, "sync-mode cycle click")
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
    qt_constants.PROPERTIES.SET_MIN_WIDTH(mute_btn, HDR.SM)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(mute_btn, HDR.SM)
    qt_constants.PROPERTIES.SET_STYLE(mute_btn, build_sm_btn_stylesheet(track.muted, "#cc3333"))
    qt_constants.LAYOUT.ADD_WIDGET(sm_layout, mute_btn)
    wire_toggle_preference(mute_btn, track_id, "muted", "#cc3333")

    local solo_btn = qt_constants.WIDGET.CREATE_BUTTON("S")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(solo_btn, HDR.SM)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(solo_btn, HDR.SM)
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

local patch_drag_logic = require("ui.timeline.patch_drag_logic")

-- Mime type for the src-btn → rec-row drag-and-drop (FR-010, FR-010a).
-- Self-contained payload: drop targets read source identity from the payload,
-- never re-query the drag origin. Snapshot at gesture-start; survives any
-- mid-drag mutation of the source row.
local PATCH_DRAG_MIME = "application/x-jve-patch-drag"

-- Shared dispatch for patch-drag drops. Both header drop targets and
-- timeline-strip drop targets funnel through here once they have a
-- (source, target) pair. compute_patch_drop_action is the single decision
-- authority — refusals propagate as log-and-no-op (user-input case, not
-- invariant violation); happy path fires SetPatch.
local function dispatch_patch_drop(source, target)
    assert(source and target,
        "dispatch_patch_drop: source and target required")
    local result = patch_drag_logic.compute_patch_drop_action(source, target)
    if result.refusal then
        log.event("patch-drag refused: %s", result.refusal)
        return
    end
    require("core.command_manager").execute("SetPatch", result.params)
end

-- Build a Track-id → {track_index, track_type} info resolver for the
-- strip drop handlers. Uses Track.load — same model the headers pull
-- from. Pure pull (MVC rule 3.0).
local function track_info_for_id(track_id)
    local t = Track.load(track_id)
    assert(t, string.format(
        "track_info_for_id: track %s not found in model", tostring(track_id)))
    return { track_index = t.track_index, track_type = t.track_type }
end

-- Install a drop target on a track-HEADER widget (one row, fixed identity).
-- Header widgets are recreated on every displayed_tab_changed rebuild, so
-- closing over sequence_id at install time is correct: each rebuild gives
-- this handler the then-current sequence id, and the old handler dies with
-- the old header widget.
local function install_header_drop_target(header_widget, sequence_id,
                                          rec_track_index, track_type)
    assert(header_widget,
        "install_header_drop_target: header_widget required")
    assert(sequence_id and sequence_id ~= "",
        "install_header_drop_target: sequence_id required")
    assert(type(rec_track_index) == "number",
        "install_header_drop_target: rec_track_index must be number")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "install_header_drop_target: track_type must be VIDEO|AUDIO, got "
        .. tostring(track_type))
    local handler = register_track_btn_handler(function(_x, _y, payload_str)
        local source = patch_drag_logic.parse_payload(payload_str)
        dispatch_patch_drop(source, {
            sequence_id     = sequence_id,
            track_type      = track_type,
            rec_track_index = rec_track_index,
        })
    end)
    qt_constants.CONTROL.INSTALL_DROP_TARGET(header_widget, PATCH_DRAG_MIME,
        handler)
end

-- Install a drop target on a timeline-STRIP widget (whole side, Y-resolves
-- the track row). Strip widgets persist across rebuilds while the displayed
-- sequence changes; the handler must pull the CURRENT displayed sequence
-- from the model at drop time (MVC rule 3.0). The track_type is fixed
-- per strip (video strip → VIDEO, audio strip → AUDIO) and is also used
-- to refuse cross-type drops upstream of derive_target_from_strip via
-- compute_patch_drop_action.
local function install_strip_drop_target(strip_widget, view, strip_track_type)
    assert(strip_widget,
        "install_strip_drop_target: strip_widget required")
    assert(type(view) == "table" and type(view.get_track_id_at_y) == "function",
        "install_strip_drop_target: view must expose get_track_id_at_y")
    assert(strip_track_type == "VIDEO" or strip_track_type == "AUDIO",
        "install_strip_drop_target: strip_track_type must be VIDEO|AUDIO, got "
        .. tostring(strip_track_type))
    local handler = register_track_btn_handler(function(_x, local_y, payload_str)
        local source = patch_drag_logic.parse_payload(payload_str)
        local displayed_seq = timeline_state.get_displayed_tab_id()
        assert(displayed_seq and displayed_seq ~= "",
            "install_strip_drop_target: no displayed sequence at drop time")
        local widget_height = qt_constants.PROPERTIES.GET_HEIGHT(strip_widget)
        local target = patch_drag_logic.derive_target_from_strip({
            view          = view,
            local_y       = local_y,
            widget_height = widget_height,
            sequence_id   = displayed_seq,
            info_lookup = track_info_for_id,
        })
        if not target then
            log.detail("patch-drag: strip drop outside any track row — ignored")
            return
        end
        dispatch_patch_drop(source, target)
    end)
    qt_constants.CONTROL.INSTALL_DROP_TARGET(strip_widget, PATCH_DRAG_MIME,
        handler)
end

-- 015 F2: src-btn visibility is a PROJECTION of the effective source's
-- tracks through the current shape's patch map. Rendering iterates the
-- source's tracks; for each, places a src-btn at the routed rec row.
-- No source loaded ⇒ no btns rendered. See spec acceptance §2b-i.
--
-- src-btn widgets are registered by `wire_patch_buttons` during header
-- build into `src_btn_by_rec`, keyed by `[track_type][rec_track_index]`.
-- The registry is cleared at the top of `create_video_headers`; both
-- builders (video + audio) repopulate before rerender_all_src_btns runs.
local src_btn_by_rec = {}

-- Clear all src-btns to "empty" state. Used at start of rerender.
local function clear_all_src_btns()
    for _, by_idx in pairs(src_btn_by_rec) do
        for _, btn in pairs(by_idx) do
            qt_constants.PROPERTIES.SET_TEXT(btn, "")
            qt_constants.PROPERTIES.SET_STYLE(btn, SRC_BTN_EMPTY_STYLESHEET)
        end
    end
end

-- Rerender all src-btns from current effective_source + patches. Called on
-- any signal that may change the projection: effective_source_changed,
-- patch_changed, patches_reset.
local function rerender_all_src_btns()
    clear_all_src_btns()
    local effective_source = require("core.effective_source")
    local src_seq = effective_source.get()
    if not src_seq then return end  -- spec §2b-i: no source ⇒ no btns
    local rec_seq = state.get_tab_strip():active_sequence_id()
    if not rec_seq or rec_seq == "" then return end
    local Patch = require("models.patch")
    local entries = Patch.source_routing_for_rec(rec_seq, src_seq)
    for _, e in ipairs(entries) do
        local by_idx = src_btn_by_rec[e.track_type]
        local btn = by_idx and by_idx[e.record_track_index]
        if btn then
            qt_constants.PROPERTIES.SET_TEXT(btn, e.source_label)
            qt_constants.PROPERTIES.SET_STYLE(btn,
                build_id_btn_stylesheet(e.enabled, source_tab_color))
        end
        -- If no btn at e.record_track_index, the source track is routed to
        -- a rec track that doesn't exist on this sequence. Insert/Overwrite
        -- auto-creates missing rec tracks at edit time; visually we just
        -- skip — the next render after the auto-create will pick it up.
    end
end

-- Register a src-btn widget for the current rebuild. Called per-row during
-- header construction. Builders must clear `src_btn_by_rec` themselves
-- before they begin building (since the widgets being registered will
-- replace any previously-registered ones for the same key).
local function register_src_btn(track_type, rec_track_index, src_btn)
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "register_src_btn: track_type must be VIDEO|AUDIO, got "
        .. tostring(track_type))
    assert(type(rec_track_index) == "number",
        "register_src_btn: rec_track_index must be number")
    assert(src_btn, "register_src_btn: src_btn widget required")
    src_btn_by_rec[track_type] = src_btn_by_rec[track_type] or {}
    src_btn_by_rec[track_type][rec_track_index] = src_btn
end

-- Render the rec-patch-id button per its track's autoselect (FR-038):
-- ON (filled) participates in selection-driven ops, OFF (outlined) is excluded.
local function render_rec_btn(rec_btn, track_id)
    local t = Track.load(track_id)
    assert(t, string.format("render_rec_btn: track %s not found", tostring(track_id)))
    qt_constants.PROPERTIES.SET_STYLE(rec_btn,
        build_id_btn_stylesheet(t.autoselect, selection_color))
end

-- src_btn label: rendered by the rerender_all_src_btns sweep based on the
-- effective source's tracks at current shape (§F2). Per-row, wire_patch_buttons
-- only REGISTERS the widget for the sweep and installs interaction handlers.
-- rec_btn label: this record track's own name (text set at creation); style
-- toggles per track.autoselect.
local function wire_patch_buttons(src_btn, rec_btn, sequence_id, rec_track_id, rec_track_index, track_type)
    assert(sequence_id and sequence_id ~= "",
        "wire_patch_buttons: sequence_id required (rec_track_index=" .. tostring(rec_track_index) .. ")")
    assert(rec_track_id and rec_track_id ~= "",
        "wire_patch_buttons: rec_track_id required (rec_track_index=" .. tostring(rec_track_index) .. ")")
    assert(type(rec_track_index) == "number",
        "wire_patch_buttons: rec_track_index must be number, got " .. type(rec_track_index))
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "wire_patch_buttons: track_type must be VIDEO or AUDIO, got " .. tostring(track_type))
    local Patch = require("models.patch")

    -- Initial visual state: empty placeholder. The post-build call to
    -- rerender_all_src_btns will fill in labels for rec rows that have
    -- a source track routed to them under the current shape.
    qt_constants.PROPERTIES.SET_TEXT(src_btn, "")
    qt_constants.PROPERTIES.SET_STYLE(src_btn, SRC_BTN_EMPTY_STYLESHEET)
    register_src_btn(track_type, rec_track_index, src_btn)
    render_rec_btn(rec_btn, rec_track_id)

    -- rec-id click toggles tracks.autoselect via the non-undoable
    -- ToggleTrackPreference command (FR-040a). Outlined ↔ filled
    -- mirrors the src-id button's enable/disable visual.
    local rec_handler = register_track_btn_handler(function()
        local project_id = timeline_state.get_project_id()
        assert(project_id, "wire_patch_buttons: no project_id (rec_track_id="
            .. tostring(rec_track_id) .. ")")
        local cmd = require("core.command_manager")
        cmd.execute("ToggleTrackPreference", {
            track_id = rec_track_id, property = "autoselect", project_id = project_id,
        })
        render_rec_btn(rec_btn, rec_track_id)
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(rec_btn, rec_handler)

    -- Under §F2, src-btn visibility implies (a) effective source is loaded
    -- and (b) a patch row routes to this rec row at the current source
    -- shape. Both click and drag-gesture handlers depend on the same three
    -- pieces of state — (project_id, source shape, patch row) — and used to
    -- re-derive them independently. The helper below asserts the invariants
    -- once and returns the resolved (shape, patch, project_id) triple so
    -- callers focus on what they do, not on how they look it up.
    local function lookup_active_patch_for_rec(label)
        local project_id = timeline_state.get_project_id()
        assert(project_id and project_id ~= "", string.format(
            "%s: no project_id (rec_track_index=%d)", label, rec_track_index))
        local effective_source = require("core.effective_source")
        local src_seq = effective_source.get()
        assert(src_seq and src_seq ~= "", string.format(
            "%s at rec_idx=%d but no effective source — "
            .. "src-btn visibility invariant violated", label, rec_track_index))
        local shape = #Track.find_by_sequence(src_seq, track_type)
        assert(shape > 0, string.format(
            "%s: effective source %s has zero %s tracks",
            label, src_seq, track_type))
        local p = Patch.find_by_record(sequence_id, track_type, shape, rec_track_index)
        assert(p, string.format(
            "%s at rec_idx=%d shape=%d but no patch routes here",
            label, rec_track_index, shape))
        return project_id, shape, p
    end

    -- src-id click toggles `enabled` on the patch row currently routed to
    -- this rec row under the current shape (§F2). Visibility invariants are
    -- enforced by lookup_active_patch_for_rec.
    local src_handler = register_track_btn_handler(function()
        local project_id, shape, p = lookup_active_patch_for_rec("src-btn click")
        local current_enabled = p.enabled == 1  -- INTEGER per Patch.save
        require("core.command_manager").execute("SetPatch", {
            sequence_id        = sequence_id,
            track_type         = track_type,
            source_shape       = shape,
            source_track_index = p.source_track_index,
            project_id         = project_id,
            enabled            = not current_enabled,
        })
    end)
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(src_btn, src_handler)

    -- Drag source (FR-010, FR-010a): on gesture-start, snapshot the source
    -- identity (including current source_shape) into a JSON mime payload.
    -- Real Qt QDrag/QDropEvent dispatch routes the drop to whichever widget
    -- (track header OR timeline-strip row) the user releases over.
    local payload_provider_name = register_track_btn_handler(function()
        local project_id, shape, p = lookup_active_patch_for_rec("patch-drag")
        return patch_drag_logic.build_payload({
            sequence_id          = sequence_id,
            track_type           = track_type,
            source_shape         = shape,
            source_track_index   = p.source_track_index,
            home_rec_track_index = rec_track_index,
            project_id           = project_id,
        })
    end)
    qt_constants.CONTROL.INSTALL_DRAG_SOURCE(src_btn, PATCH_DRAG_MIME,
        payload_provider_name)
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

-- ----------------------------------------------------------------------------
-- MODULE-LEVEL SIGNAL CONNECTS — NOT A LEAK.
--
-- The Signals.connect calls from here down to the end of this block run
-- ONCE at module-load time (Lua caches `require`), not once per project or
-- per panel-create. They are intentional process-lifetime listeners, same
-- shape as the `project_changed` connects documented in CLAUDE.md. Past
-- audits (pass 15c) flagged these as "stacking on project switch" — that
-- analysis is incorrect; they do not stack.
--
-- DO NOT add Signals.disconnect calls in M.on_project_change for these.
-- If you need a per-project listener, add it inside M.create() (which DOES
-- run per project) and track its connection id for cleanup.
-- ----------------------------------------------------------------------------

-- MVC: update button styles when track state changes externally (undo/redo)
Signals.connect("track_mix_changed", refresh_track_button_styles)

-- MVC: track_preference_changed fires when mute/solo/lock/enabled is toggled.
-- The signal payload's new_val is INTEGER 0/1 (ToggleTrackPreference normalizes
-- at the emit boundary). Convert to bool for the stylesheet builders — they
-- use `if active and color then ...` which treats INTEGER 0 as truthy (Lua
-- semantics), so passing the raw int would render as "active" for both
-- on and off.
Signals.connect("track_preference_changed", function(track_id, property, new_val)
    local refs = track_button_refs[track_id]
    if not refs then return end
    local active = new_val == 1
    if property == "muted" and refs.mute_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.mute_btn,
            build_sm_btn_stylesheet(active, "#cc3333"))
    elseif property == "soloed" and refs.solo_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.solo_btn,
            build_sm_btn_stylesheet(active, "#ccaa00"))
    elseif property == "locked" and refs.lock_btn then
        qt_constants.PROPERTIES.SET_STYLE(refs.lock_btn,
            build_track_header_btn_stylesheet(active, "#ccaa00"))
    end
end)

-- MVC: track_waveform_display_changed fires when ToggleTrackWaveformDisplay
-- runs. Payload's new_val is INTEGER 0/1; convert to bool for the stylesheet
-- builder (same INTEGER-truthy hazard as track_preference_changed above).
Signals.connect("track_waveform_display_changed", function(track_id, new_val)
    local refs = track_button_refs[track_id]
    if not refs or not refs.wave_btn then return end
    local active = new_val == 1
    qt_constants.PROPERTIES.SET_STYLE(refs.wave_btn,
        build_track_header_btn_stylesheet(active, "#4488aa"))
end)

-- MVC: sync_mode_changed fires when cycle button or SetSyncMode command runs.
Signals.connect("sync_mode_changed", function(track_id, new_mode)
    local refs = track_button_refs[track_id]
    if not refs or not refs.sync_mode_btn then return end
    qt_constants.PROPERTIES.SET_TEXT(refs.sync_mode_btn, SYNC_ICONS[new_mode] or "?")
    qt_constants.PROPERTIES.SET_STYLE(refs.sync_mode_btn, build_sync_mode_btn_stylesheet(new_mode))
end)

-- MVC: patch_changed fires when SetPatch creates/updates/disables a patch.
-- Signal: (sequence_id, track_type, source_track_index, change_type)
-- Any patch mutation may move a src-btn between rec rows (drag-redirect),
-- toggle its enabled style (click), or create/delete a row. Cheapest correct
-- response is a full sweep — the projection is O(N+M) over source tracks
-- + rec rows. Tracking partial deltas is more code for no gain at typical
-- NLE sizes. patches_reset (Restore Default) and effective_source_changed
-- funnel through the same sweep.
Signals.connect("patch_changed",
    function(_seq, _type, _shape, _src_idx, _change)
        rerender_all_src_btns()
    end)
Signals.connect("patches_reset", function(_rec_seq)
    rerender_all_src_btns()
end)

-- FR-001b session-scoped dismissal. After the user closes the source tab
-- via × in a session, no further auto-open occurs until project reopen.
-- Tracked by listening to source_tab_visibility_changed(false) — the signal
-- is emitted from close_tab when the closed tab IS the source tab. The
-- flag is cleared on project_changed.
local source_tab_dismissed = false

Signals.connect("source_tab_visibility_changed", function(visible)
    if visible then
        source_tab_dismissed = false
    else
        source_tab_dismissed = true
    end
end)

Signals.connect("project_changed", function()
    source_tab_dismissed = false
end, 35)

-- Source monitor loaded a new master. Three responsibilities:
--   1. Refresh tab styles (the source tab's identity changed).
--   2. Apply identity patch defaults if the active record has no patches yet
--      (handled by sibling listeners on effective_source_changed).
--   3. FR-001b: auto-switch the displayed tab to the new source if the
--      user has not dismissed it this session. switch_to_source_tab
--      emits displayed_tab_changed; the displayed_tab_changed listener
--      drives rebuild_for_displayed_tab, which calls ensure_tab_for_sequence
--      on the new master — and THAT is where the source-tab singleton is
--      rekeyed (rekey_source_tab) from prev to new, preserving the panel
--      widget and the open_tabs[X].strip_tab.sequence_id == X invariant.
--      No explicit eviction needed here; the old close-on-prev block
--      destroyed the source widget instead of reusing it (orphaned
--      source-tab bug F-press across media types, 2026-05-23).
Signals.connect("source_loaded_changed", function(new_master_seq_id, _prev_seq_id)
    -- Style update tracks DISPLAYED tab; pass that, not the active record.
    update_tab_styles(timeline_state.get_displayed_tab_id())

    -- Source cleared (e.g. source viewer was reset, project closed). No
    -- rekey target exists; the only way to preserve the invariant
    -- open_tabs[X].strip_tab.sequence_id == X is to drop the source-tab
    -- panel entry. close_tab unwinds Qt parenting, handlers, and clears
    -- source_tab_seq_id. Falls through silently when no source tab is open.
    if not new_master_seq_id or new_master_seq_id == "" then
        if source_tab_seq_id then close_tab(source_tab_seq_id) end
        return
    end

    -- Auto-switch the displayed tab to the new source. switch_to_source_tab
    -- emits displayed_tab_changed; the displayed_tab_changed listener calls
    -- rebuild_for_displayed_tab → ensure_tab_for_sequence(new_master_seq_id),
    -- which is where the rekey-or-collision branch (above) restores the
    -- panel invariant. No explicit eviction here.
    local record_seq_id = state.get_tab_strip():active_sequence_id()
    if record_seq_id and not source_tab_dismissed then
        timeline_state.switch_to_source_tab(new_master_seq_id)
    end
end)

-- 015 F2: identity-patch seeding follows the EFFECTIVE source (source
-- viewer OR active-browser master_clip selection):
--   1. Seeds identity rows at the new shape (idempotent; existing
--      user-rerouted/disabled rows are preserved).
--   2. Triggers a full src-btn rerender so the header reflects the new
--      source's tracks (or, if source went to nil, hides all src-btns).
-- Both branches must run even when source is nil — that's precisely when
-- src-btns must disappear (spec §2b-i).
--
-- Two trigger signals because identity is a function of (rec_seq, source):
--   • effective_source_changed — source side moves while rec stays
--   • active_sequence_changed   — rec side moves while source stays
-- Either can leave the panel rendering stale src-btns (or unseeded
-- patches for an unseen rec/source shape combination). Same body runs
-- on both; both reads come from current state, not the signal payload,
-- so the handler is symmetric.
local function reseed_and_rerender_src_btns()
    -- strip:active_sequence_id is wired during init; if it isn't, the signal
    -- has fired before the panel is set up — that's a startup-order bug
    -- and we want the stack trace, not a silent skip. rerender_all_src_btns
    -- already calls state.get_tab_strip():active_sequence_id() without a guard for the same
    -- reason.
    local record_seq_id = state.get_tab_strip():active_sequence_id()
    local source_seq_id = require("core.effective_source").get()
    -- Both ids may legitimately be nil before any project is open or any
    -- source is loaded; that's the "hide src-btns" branch (spec §2b-i)
    -- and intentionally produces no seeding work.
    if record_seq_id and record_seq_id ~= "" and source_seq_id then
        require("models.patch").ensure_identity_for_source(
            record_seq_id, source_seq_id)
    end
    rerender_all_src_btns()
end

Signals.connect("effective_source_changed", reseed_and_rerender_src_btns)
Signals.connect("active_sequence_changed",  reseed_and_rerender_src_btns)

-- Build one track-header row (the per-track block shared by video and audio
-- header builders). Both builders previously inlined ~90 lines of identical
-- Qt widget construction + wiring; the V/A differences are isolated to:
--   • header background color (passed in via `header_color`)
--   • whether a waveform toggle trails the s/m stack (AUDIO only)
--   • the `cells` snapshot fed to `track_button_refs` for T017 inspection
-- Returns header_widget, header_height, refs_entry. The builder is
-- responsible for inserting the widget into its splitter in iteration order.
local function build_track_header_row(track, track_type, header_color)
    assert(track and track.id, "build_track_header_row: track required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        string.format("build_track_header_row: track_type must be VIDEO|AUDIO; got %s",
            tostring(track_type)))

    -- Source-tab headers strip back to the buttons that make sense for
    -- a master view: M/S (per-track monitoring) and W (audio waveform).
    -- Patch routing (src/rec), track lock, and sync_mode are
    -- record-only concerns — masters don't accept patch routing, can't
    -- be locked-against-edit (no edits target them), and have no
    -- ripple sync mode.
    local displayed_kind = state.get_displayed_tab_kind()
    assert(displayed_kind == "source" or displayed_kind == "record",
        string.format("build_track_header_row: displayed_tab_kind must be "
            .. "'source'|'record' (rebuild fires only with a displayed tab); "
            .. "got %s", tostring(displayed_kind)))
    local is_source_tab = displayed_kind == "source"

    -- state.get_track_height asserts when the track is unknown; the
    -- track here came from strip:displayed_tracks so the call is safe.
    -- DEFAULT_TRACK_HEIGHT is returned for tracks that exist but have
    -- never been resized (legitimate "unset" semantic on a known row).
    local track_height = state.get_track_height(track.id)
    local header_height = content_to_header(track_height)

    local header = qt_constants.WIDGET.CREATE()
    local header_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(header, header_layout)
    qt_constants.CONTROL.SET_LAYOUT_SPACING(header_layout, 2)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(header_layout, 4, 0, 4, 0)
    qt_constants.PROPERTIES.SET_STYLE(header,
        build_track_header_stylesheet(header_color))
    qt_constants.PROPERTIES.SET_MIN_WIDTH(header,
        timeline_state.dimensions.track_header_width)
    -- MinimumExpanding lets the header track its parent column's width
    -- so the name_label (which has Expanding horizontal policy) can
    -- stretch into the extra space when the headers column is dragged
    -- wider. The Fixed policy that used to live here relied on the old
    -- main_splitter_moved cascade explicitly SET_SIZE'ing each header —
    -- that cascade is gone since the column went HBox.
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "MinimumExpanding", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, header_height)
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, header_height)

    local captured_track_id = track.id

    local src_btn, rec_btn, lock_btn, sync_btn = nil, nil, nil, nil
    local seq_id = state.get_tab_strip():active_sequence_id()

    if not is_source_tab then
        src_btn = qt_constants.WIDGET.CREATE_BUTTON("—")
        qt_constants.PROPERTIES.SET_MIN_WIDTH(src_btn, HDR.SRC)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(src_btn, HDR.SRC)
        qt_constants.PROPERTIES.SET_STYLE(src_btn,
            build_id_btn_stylesheet(false, source_tab_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, src_btn)

        rec_btn = qt_constants.WIDGET.CREATE_BUTTON(track.name)
        qt_constants.PROPERTIES.SET_MIN_WIDTH(rec_btn, HDR.REC)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(rec_btn, HDR.REC)
        qt_constants.PROPERTIES.SET_STYLE(rec_btn,
            build_id_btn_stylesheet(true, selection_color))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, rec_btn)

        wire_patch_buttons(src_btn, rec_btn, seq_id, track.id,
            track.track_index, track_type)
        install_header_drop_target(header, seq_id, track.track_index, track_type)
    end

    local label_text = require("ui.timeline.track_header_label").for_display(
        { name = track.name, track_index = track.track_index, track_type = track_type },
        displayed_kind)
    local name_label = qt_constants.WIDGET.CREATE_LABEL(label_text)
    qt_constants.PROPERTIES.SET_STYLE(name_label,
        build_track_header_label_stylesheet())
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(name_label, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(header_layout, name_label)

    if not is_source_tab then
        lock_btn = qt_constants.WIDGET.CREATE_BUTTON("🔒")
        qt_constants.PROPERTIES.SET_MIN_WIDTH(lock_btn, HDR.LOCK)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(lock_btn, HDR.LOCK)
        qt_constants.PROPERTIES.SET_STYLE(lock_btn,
            build_track_header_btn_stylesheet(track.locked, "#ccaa00"))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, lock_btn)
        wire_toggle_preference(lock_btn, captured_track_id, "locked", "#ccaa00")

        sync_btn = qt_constants.WIDGET.CREATE_BUTTON(
            SYNC_ICONS[track.sync_mode] or "?")
        qt_constants.PROPERTIES.SET_MIN_WIDTH(sync_btn, HDR.SYNC)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(sync_btn, HDR.SYNC)
        qt_constants.PROPERTIES.SET_STYLE(sync_btn,
            build_sync_mode_btn_stylesheet(track.sync_mode))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, sync_btn)
        wire_sync_mode_cycle(sync_btn, captured_track_id)
    end

    local mute_btn, solo_btn = add_sm_stack_to_layout(
        header_layout, track, captured_track_id)

    -- Cells snapshot for T017 inspection (FR-008): records the LTR order of
    -- widgets actually placed in header_layout above.
    local cells = is_source_tab
        and {"label", "sm_stack"}
        or {"src_btn", "rec_btn", "label", "lock", "sync_mode", "sm_stack"}

    -- Audio rows trail a waveform toggle (UI-only state, no undo).
    -- Video rows render an empty spacer of the same width so the M/S
    -- stacks on both row kinds end at the same x-coord.
    local wave_btn = nil
    if track_type == "AUDIO" then
        wave_btn = qt_constants.WIDGET.CREATE_BUTTON("W")
        qt_constants.PROPERTIES.SET_MIN_WIDTH(wave_btn, HDR.WAVE)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(wave_btn, HDR.WAVE)
        qt_constants.PROPERTIES.SET_STYLE(wave_btn,
            build_track_header_btn_stylesheet(
                track_state.get_waveform_enabled(captured_track_id), "#4488aa"))
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, wave_btn)
        wire_waveform_display_toggle(wave_btn, captured_track_id)
        cells[#cells + 1] = "wave"
    else
        local trailing_spacer = qt_constants.WIDGET.CREATE()
        qt_constants.PROPERTIES.SET_MIN_WIDTH(trailing_spacer, TRAILING_ALIGNMENT_PX)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(trailing_spacer, TRAILING_ALIGNMENT_PX)
        qt_constants.LAYOUT.ADD_WIDGET(header_layout, trailing_spacer)
        cells[#cells + 1] = "trailing_spacer"
    end

    local refs_entry = {
        mute_btn      = mute_btn,
        solo_btn      = solo_btn,
        lock_btn      = lock_btn,
        sync_mode_btn = sync_btn,
        src_btn       = src_btn,
        rec_btn       = rec_btn,
        wave_btn      = wave_btn,  -- nil for video tracks
        seq_id        = seq_id,
        rec_idx       = track.track_index,
        track_type    = track_type,
        cells         = cells,
        lock_kind     = "icon",
        label_text    = track.name,
    }

    return header, header_height, refs_entry
end

-- Spreadsheet-style row resize handles. Each track header gets a thin
-- (RESIZE_EDGE_PX-tall) widget on its outside edge — for video that's
-- ABOVE the header (tracks grow upward from the V1 anchor at bottom);
-- for audio it's BELOW the header (tracks grow downward from the A1
-- anchor at top). Dragging the edge changes ONLY that track's height;
-- neighbors keep their min==max pin, the stretch widget absorbs/releases
-- the difference, and the scroll area handles overflow. No QSplitter
-- redistribute — that was the source of the twitchy multi-track jumping
-- earlier (Qt could only honor a handle move by giving on both sides,
-- but every track was pinned, so it would snap rather than glide).
-- (RESIZE_EDGE_PX is declared at the top of the file alongside the row-
-- alignment metrics — header_widget + edge must sum to track_height.)

--- Build a resize edge widget and wire its drag filter to live-resize
--- one track. `growth_sign` is +1 when dragging DOWN should grow the
--- track (audio: edge below A_n) and -1 when dragging UP should grow
--- (video: edge above V_n). `get_header_widget` returns the header
--- widget so we can pin its min==max as we go (live visual feedback).
local function create_resize_edge(track, get_header_widget, growth_sign)
    assert(track and track.id, "create_resize_edge: track required")
    assert(growth_sign == 1 or growth_sign == -1,
        "create_resize_edge: growth_sign must be +1 or -1")
    local edge = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(edge, "MinimumExpanding", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(edge, RESIZE_EDGE_PX)
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(edge, RESIZE_EDGE_PX)
    -- luacheck: globals qt_set_widget_cursor qt_set_widget_drag_handler
    qt_set_widget_cursor(edge, "split_v")

    -- Live-drag state. Captured on "start"; consumed on "move".
    local press_y = 0
    local orig_track_height = 0
    local captured_track_id = track.id

    local handler_name = "track_resize_edge_" .. tostring(edge):gsub("[^%w]", "_")
    _G[handler_name] = function(event_type, _global_x, global_y, _modifiers)
        if event_type == "start" then
            press_y = global_y
            orig_track_height = state.get_track_height(captured_track_id)
            assert(type(orig_track_height) == "number", string.format(
                "track_resize_edge[start]: state.get_track_height(%s) returned %s; "
                .. "track must exist in timeline_state at press time",
                tostring(captured_track_id), type(orig_track_height)))
        elseif event_type == "move" then
            local dy = global_y - press_y
            local new_h = math.max(MIN_TRACK_HEIGHT,
                orig_track_height + dy * growth_sign)
            -- Pin the header widget at its new height so the VBox lays
            -- out instantly; setting only the model wouldn't push Qt
            -- past Fixed sizing.
            local header = get_header_widget()
            assert(header,
                "track_resize_edge[move]: header widget missing — VBox was "
                .. "torn down mid-drag without disconnecting this filter")
            local clamped_header = content_to_header(new_h)
            qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, clamped_header)
            qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, clamped_header)
            state.set_track_height(captured_track_id, new_h)
        end
        -- "end" no-op: state.set_track_height already triggered debounced
        -- persist; final visual state matches the last "move".
    end
    qt_set_widget_drag_handler(edge, handler_name)
    return edge
end

-- Build the video header column. Layout top→bottom:
--     [stretch (Expanding) — absorbs/releases as tracks resize]
--     [edge_V3]
--     [header_V3]
--     [edge_V2]
--     [header_V2]
--     [edge_V1]
--     [header_V1]               ← anchored at bottom (midline)
-- Each edge is a 4-px-tall widget with the split_v cursor and a drag
-- filter that live-resizes exactly the track immediately BELOW it.
-- Dragging UP grows the track; the stretch widget gives up space.
-- Neighbors stay min==max-pinned and do not jiggle.
local function create_video_headers()
    -- Clear the src-btn render registry; both builders (video + audio) run
    -- back-to-back during init and rebuild paths and they collectively
    -- register every src-btn before any rerender fires. Clearing in the
    -- first builder is safe and avoids stale widget refs from a prior tab.
    src_btn_by_rec = {}
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "MinimumExpanding", "Expanding")

    local video_tracks = state.get_video_tracks()
    local video_headers = {}
    local video_header_heights = {}

    -- Stretch at top so tracks visually grow upward from the V1 anchor.
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(layout, stretch_widget)

    -- Build all headers first so resize-edge closures can capture by index.
    for i, track in ipairs(video_tracks) do
        local header, header_height, refs_entry = build_track_header_row(
            track, "VIDEO", timeline_state.colors.video_track_header)
        track_button_refs[track.id] = refs_entry
        video_headers[i] = header
        video_header_heights[i] = header_height
    end

    -- Add edge-then-header pairs in REVERSE order (V3, V2, V1) so V1
    -- lands at the bottom (anchor) and the edge ABOVE each track sits
    -- on the side away from the anchor — dragging that edge UP grows
    -- the track underneath it.
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        local captured_i = i
        local edge = create_resize_edge(track,
            function() return video_headers[captured_i] end, -1)
        qt_constants.LAYOUT.ADD_WIDGET(layout, edge)
        qt_constants.LAYOUT.ADD_WIDGET(layout, video_headers[i])
    end

    -- Pin every header at its natural height. The VBox will lay them
    -- out fixed; the stretch widget consumes the rest. During an edge
    -- drag the create_resize_edge handler unpins+repins the target
    -- header in place — no neighbor ever changes.
    for i, header in ipairs(video_headers) do
        local h = video_header_heights[i]
        assert(type(h) == "number" and h > 0, string.format(
            "create_video_headers: video_header_heights[%d] missing — "
            .. "header builder didn't return a height for track %s",
            i, tostring(video_tracks[i] and video_tracks[i].id)))
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, h)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, h)
    end

    return container, video_headers
end

-- Helper function to create audio headers with splitters
-- Build the audio header column. Layout top→bottom:
--     [header_A1]               ← anchored at top (midline)
--     [edge_A1]
--     [header_A2]
--     [edge_A2]
--     [header_A3]
--     [edge_A3]
--     [stretch (Expanding)]
-- Each edge sits BELOW its header and live-resizes that header
-- (growth_sign=+1: drag down grows). Neighbors stay pinned.
local function create_audio_headers()
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "MinimumExpanding", "Expanding")

    local audio_tracks = state.get_audio_tracks()
    local audio_headers = {}
    local audio_header_heights = {}

    -- Build all headers first so the edge closures can capture by index.
    for i, track in ipairs(audio_tracks) do
        local header, header_height, refs_entry = build_track_header_row(
            track, "AUDIO", timeline_state.colors.audio_track_header)
        track_button_refs[track.id] = refs_entry
        audio_headers[i] = header
        audio_header_heights[i] = header_height
    end

    -- Add header-then-edge pairs in natural order (A1, A2, A3) so A1
    -- anchors at the top and the edge BELOW each track sits on the
    -- side away from the anchor — dragging that edge DOWN grows the
    -- track above it.
    for i, track in ipairs(audio_tracks) do
        local captured_i = i
        qt_constants.LAYOUT.ADD_WIDGET(layout, audio_headers[i])
        local edge = create_resize_edge(track,
            function() return audio_headers[captured_i] end, 1)
        qt_constants.LAYOUT.ADD_WIDGET(layout, edge)
    end

    -- Stretch at bottom so tracks visually grow downward from A1.
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(layout, stretch_widget)

    for i, header in ipairs(audio_headers) do
        local h = audio_header_heights[i]
        assert(type(h) == "number" and h > 0, string.format(
            "create_audio_headers: audio_header_heights[%d] missing — "
            .. "header builder didn't return a height for track %s",
            i, tostring(audio_tracks[i] and audio_tracks[i].id)))
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, h)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, h)
    end

    return container, audio_headers
end

-- Helper function to create headers column with video/audio sections
local function create_headers_column()
    -- Wrapper VBox to add ruler-height spacer at top
    local headers_wrapper = qt_constants.WIDGET.CREATE()
    local headers_wrapper_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(headers_wrapper_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(headers_wrapper_layout, 0, 0, 0, 0)

    -- Top left header area aligned with the ruler; contains the timecode entry field.
    local tc_header = create_timecode_header()
    qt_constants.LAYOUT.ADD_WIDGET(headers_wrapper_layout, tc_header)

    -- Main vertical splitter between video and audio header sections
    local headers_main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

    -- Video headers section with scroll area. The inner content is a
    -- plain QWidget with a VBox layout (see create_video_headers), not a
    -- QSplitter — track row resize is handled by per-track edge widgets.
    local video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local video_container, video_headers = create_video_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(video_scroll, video_container)
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET_RESIZABLE(video_scroll, true)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)

    -- Audio headers section with scroll area (same VBox shape as video).
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local audio_container, audio_headers = create_audio_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_container)
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET_RESIZABLE(audio_scroll, true)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)

    -- Both builders ran above and registered every src-btn into
    -- src_btn_by_rec; render the projection now so the panel shows the
    -- correct src-btns at construction time (or none, if no source is loaded).
    rerender_all_src_btns()

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

    -- Min-width enforces the column floor; no max lets the splitter drag it wider.
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(headers_wrapper, "MinimumExpanding", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(headers_wrapper, timeline_state.dimensions.track_header_width)

    -- Return wrapper, main splitter, scroll areas, inner content containers, and TC header.
    -- Callers need the inner containers and TC header to force-resize them when the
    -- main horizontal splitter moves (widgetResizable cascade alone is unreliable).
    return headers_wrapper, headers_main_splitter, video_scroll, audio_scroll,
           video_container, audio_container, tc_header
end

function M.create(opts)
    log.event("Creating multi-view timeline panel...")

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
        local sid = timeline_state.get_tab_strip():active_sequence_id()
        if not (sid and sid ~= "") then
            selection_hub.update_selection("timeline", {})
            return
        end
        selection_hub.update_selection("timeline", normalize_timeline_selection(selected_clips))
    end

    state.set_on_selection_changed(broadcast_selection)
    local initial_selection = state.get_selected_clips and state.get_selected_clips() or {}
    broadcast_selection(initial_selection)

    -- Re-broadcast when DISPLAYED marks change (not active marks). The
    -- inspector shows the currently-rendered tab's sequence when nothing is
    -- selected, so a mark change on the SourceTab while it's displayed must
    -- repaint the inspector even if the active record sequence is unchanged
    -- (FR-038 / display-aware marks per CLAUDE.md key pattern).
    local last_mark_signature = nil
    if #initial_selection == 0 then
        local mark_in = state.get_display_mark_in and state.get_display_mark_in() or nil
        local mark_out = state.get_display_mark_out and state.get_display_mark_out() or nil
        last_mark_signature = tostring(mark_in) .. ":" .. tostring(mark_out)
    end
    state.add_listener(profile_scope.wrap("timeline_panel.selection_listener", function()
        local selected = state.get_selected_clips and state.get_selected_clips() or {}

        -- Re-broadcast selection when only the timeline itself is selected and marks change.
        if #selected == 0 then
            local mark_in = state.get_display_mark_in and state.get_display_mark_in() or nil
            local mark_out = state.get_display_mark_out and state.get_display_mark_out() or nil
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
        color("PANEL_BACKGROUND_COLOR"),
        color("SCROLL_BORDER_COLOR")
    ))
    tab_bar_tabs_container = qt_constants.WIDGET.CREATE()
    tab_bar_tabs_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(tab_bar_tabs_layout, 4)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(tab_bar_tabs_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(tab_bar_tabs_container, tab_bar_tabs_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tab_bar_tabs_container, "Preferred", "Fixed")

    -- Scroll area constrains tab bar width, clips overflow
    local panel_bg = color("PANEL_BACKGROUND_COLOR")
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

    -- Main row: [headers_column | drag_edge | timeline_area]. HBox + a
    -- thin vertical drag edge replaces what used to be a QSplitter.
    -- Same rationale as the track row resize refactor (2026-05-13):
    -- QSplitter's redistribute logic fought the inner widgets' size
    -- constraints (headers_column is MinimumExpanding with a pinned
    -- min_width; embedded scroll areas added more constraints), making
    -- the drag feel twitchy. The HBox + drag-edge model is direct:
    -- dragging the edge pins the headers_column's min==max width;
    -- the timeline_area's Expanding policy absorbs the difference.
    local main_row = qt_constants.WIDGET.CREATE()
    local main_row_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(main_row_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(main_row_layout, 0, 0, 0, 0)
    qt_constants.LAYOUT.SET_ON_WIDGET(main_row, main_row_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(main_row, "Expanding", "Expanding")

    -- LEFT SIDE: Headers column (all headers stacked vertically)
    local headers_column, headers_main_splitter, header_video_scroll, header_audio_scroll,
          video_hdr_container, audio_hdr_container, tc_header = create_headers_column()
    M.headers_main_splitter = headers_main_splitter
    M.header_video_scroll = header_video_scroll
    M.header_audio_scroll = header_audio_scroll

    -- RIGHT SIDE: Timeline area column
    local timeline_area = qt_constants.WIDGET.CREATE()
    local timeline_area_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(timeline_area_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(timeline_area_layout, 0, 0, 0, 0)

    -- Ruler widget (fixed height). The ruler and the track views must
    -- map time across the SAME pixel span — but the track views live
    -- inside scroll areas whose vertical scrollbar reserves a gutter
    -- (width depends on the OS scrollbar style; 0 for overlay
    -- scrollbars). A trailing spacer in the ruler row mirrors the
    -- measured gutter so ruler width == track viewport width by
    -- construction; sync_ruler_gutter (below) keeps it current.
    local ruler_row = qt_constants.WIDGET.CREATE()
    local ruler_row_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(ruler_row_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(ruler_row_layout, 0, 0, 0, 0)
    local ruler_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local ruler = timeline_ruler.create(ruler_widget, state)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_widget, "Expanding", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Set 32px height
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Lock to 32px
    local ruler_gutter = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_gutter, "Fixed", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(ruler_gutter, 0)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(ruler_gutter, 0)
    qt_constants.LAYOUT.ADD_WIDGET(ruler_row_layout, ruler_widget)
    qt_constants.LAYOUT.ADD_WIDGET(ruler_row_layout, ruler_gutter)
    qt_constants.LAYOUT.SET_ON_WIDGET(ruler_row, ruler_row_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_row, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, ruler_row)
    M.ruler_widget = ruler_widget
    M._ruler_gutter = ruler_gutter

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
            -- Model-owned vertical scroll entry points (single-owner
            -- redesign): wheel + scroll-into-view route through the
            -- panel so every position change is a model write.
            vertical_scroll = {
                by = function(dy) M.user_scroll_pane_by("video", dy) end,
                to = function(v) M.user_scroll_pane_to("video", v) end,
                metrics = function()
                    -- luacheck: globals qt_get_scroll_area_v_metrics
                    return qt_get_scroll_area_v_metrics(M.timeline_video_scroll)
                end,
            },
        }
    )
    video_view_ref = video_view  -- Store reference for drag detection
    install_strip_drop_target(video_widget, video_view, "VIDEO")

    -- Make video widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_widget, "Expanding", "Expanding")

    -- Video scroll area
    local timeline_video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    M.timeline_video_scroll = timeline_video_scroll  -- for scroll persist/restore
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_video_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(timeline_video_scroll, "AlwaysOff")
    -- Visible scrollbar: a second user gesture source alongside the
    -- wheel, wired below via qt_set_scroll_area_v_user_scroll_handler.
    -- AlwaysOn (not AsNeeded) so the reserved gutter is CONSTANT: with
    -- AsNeeded a pane whose content fits would be gutter-less while the
    -- other pane isn't, and the two lanes (and the ruler) would map
    -- time across different pixel spans. On overlay-scrollbar systems
    -- the gutter measures 0 either way — see sync_ruler_gutter.
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(timeline_video_scroll, "AlwaysOn")
    -- Remove scroll area frame/border so content width matches ruler width exactly
    qt_constants.PROPERTIES.SET_STYLE(timeline_video_scroll, "QScrollArea { border: none; }")

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
            -- Same model-owned scroll entry points as the video view.
            vertical_scroll = {
                by = function(dy) M.user_scroll_pane_by("audio", dy) end,
                to = function(v) M.user_scroll_pane_to("audio", v) end,
                metrics = function()
                    -- luacheck: globals qt_get_scroll_area_v_metrics
                    return qt_get_scroll_area_v_metrics(M.timeline_audio_scroll)
                end,
            },
        }
    )
    audio_view_ref = audio_view  -- Store reference for drag detection
    install_strip_drop_target(audio_widget, audio_view, "AUDIO")

    -- Make audio widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_widget, "Expanding", "Expanding")

    -- Audio scroll area
    local timeline_audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    M.timeline_audio_scroll = timeline_audio_scroll  -- for scroll persist/restore
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_audio_scroll, "Expanding", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(timeline_audio_scroll, "AlwaysOff")
    -- Visible scrollbar, AlwaysOn for a constant gutter — same
    -- rationale as the video pane above.
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(timeline_audio_scroll, "AlwaysOn")
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
            sequence_id = state.get_tab_strip():active_sequence_id(),
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

    -- Horizontal timeline scrollbar: projects the model's time viewport
    -- in FRAMES (value = viewport start, page = viewport duration,
    -- range = [sequence TC start, extent − duration]) — a standalone
    -- QScrollBar, not a scroll area's, because the horizontal axis is
    -- virtual time, not any widget's pixel range. Gestures dispatch the
    -- same ScrollTimelineViewport command as a horizontal wheel; the
    -- state listener (below) re-projects after every model change so
    -- pans, zooms, and clamps keep the thumb honest. The trailing
    -- spacer mirrors the vertical-scrollbar gutter so the bar's track
    -- spans the same pixels as the lanes (see sync_ruler_gutter).
    local h_scroll_row = qt_constants.WIDGET.CREATE()
    local h_scroll_row_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(h_scroll_row_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(h_scroll_row_layout, 0, 0, 0, 0)
    -- luacheck: globals qt_create_scroll_bar
    local h_scrollbar = qt_create_scroll_bar("horizontal")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(h_scrollbar, "Expanding", "Fixed")
    -- Explicit stylesheet, not native rendering: macOS draws a bare
    -- QScrollBar in the transient overlay style — a hairline that fades
    -- out when idle (the pane bars escape this via their scroll areas'
    -- AlwaysOn policy). Styling the handle opts the bar out of the
    -- platform style entirely, so it's permanently visible. min-width
    -- keeps the thumb grabbable on long timelines where the honest
    -- proportion (viewport/extent) would shrink it to slivers.
    qt_constants.PROPERTIES.SET_STYLE(h_scrollbar, string.format([[
        QScrollBar:horizontal {
            background: %s;
            border-top: 1px solid %s;
            height: 14px;
            margin: 0;
        }
        QScrollBar::handle:horizontal {
            background: %s;
            border-radius: 5px;
            min-width: 24px;
            margin: 2px;
        }
        QScrollBar::handle:horizontal:hover { background: %s; }
        QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
            width: 0;
        }
        QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {
            background: none;
        }
    ]], color("SCROLL_BACKGROUND_COLOR"), color("SCROLL_BORDER_COLOR"),
        color("DROPDOWN_BORDER_COLOR"), color("HOVER_BACKGROUND_COLOR")))
    local h_scroll_gutter = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(h_scroll_gutter, "Fixed", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(h_scroll_gutter, 0)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(h_scroll_gutter, 0)
    qt_constants.LAYOUT.ADD_WIDGET(h_scroll_row_layout, h_scrollbar)
    qt_constants.LAYOUT.ADD_WIDGET(h_scroll_row_layout, h_scroll_gutter)
    qt_constants.LAYOUT.SET_ON_WIDGET(h_scroll_row, h_scroll_row_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(h_scroll_row, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, h_scroll_row)
    M.timeline_h_scrollbar = h_scrollbar
    M._h_scroll_gutter = h_scroll_gutter

    -- Scrollbar gestures (drags, page clicks, arrow steps) write the
    -- model. actionTriggered fires ONLY for user interaction — never
    -- for programmatic setValue or layout clamps — so this is a pure
    -- intent signal, unlike the old valueChanged wiring whose ambiguity
    -- let transient layout clamps overwrite saved offsets.
    _G["video_user_scrolled"] = function(value)
        M.user_scroll_pane_to("video", value)
    end
    qt_set_scroll_area_v_user_scroll_handler(M.timeline_video_scroll, "video_user_scrolled")

    _G["audio_user_scrolled"] = function(value)
        M.user_scroll_pane_to("audio", value)
    end
    qt_set_scroll_area_v_user_scroll_handler(M.timeline_audio_scroll, "audio_user_scrolled")

    -- Whenever Qt's scrollable range catches up with a layout change
    -- (content min-height applied, viewport resized, splitter dragged),
    -- re-apply the model. Anchored model coordinates make this a pure
    -- projection: video re-anchors to the bottom (the old
    -- BottomAnchorFilter behavior, now derived from the model instead
    -- of a timer race), audio to the top, and a deferred sequence-load
    -- restore lands as soon as the new content's range exists (the old
    -- _pending_scroll_restore mechanism, minus the stale-range hole).
    _G["video_scroll_range_changed"] = function()
        M.apply_pane_scroll("video")
    end
    qt_set_scroll_area_v_range_handler(M.timeline_video_scroll, "video_scroll_range_changed")

    _G["audio_scroll_range_changed"] = function()
        M.apply_pane_scroll("audio")
    end
    qt_set_scroll_area_v_range_handler(M.timeline_audio_scroll, "audio_scroll_range_changed")

    -- Horizontal-bar gestures (thumb drags, page clicks, arrow steps)
    -- land here with the user's absolute target in frames. Same
    -- actionTriggered intent signal as the vertical panes.
    _G["timeline_h_user_scrolled"] = function(value)
        M.user_scroll_timeline_to(value)
    end
    -- luacheck: globals qt_set_scroll_bar_user_scroll_handler
    qt_set_scroll_bar_user_scroll_handler(
        M.timeline_h_scrollbar, "timeline_h_user_scrolled")

    -- Re-project the bar on every model change: pans (wheel or bar),
    -- zooms (pageStep follows the viewport duration), extent growth
    -- (playhead past content), tab switches. Projection emits no
    -- user-scroll signal, so this can't echo into the write path.
    state.add_listener(function() M.sync_h_scrollbar() end)
    M.sync_h_scrollbar()

    -- The ruler-gutter spacer mirrors the scrollbar's reserved width.
    -- The style hint isn't trustworthy until the widget is realized
    -- (it reports transient/0 pre-show), and rangeChanged never fires
    -- for sequences whose content fits the viewport — so hook the
    -- scroll area's geometry changes: the first real layout pass fires
    -- one, and the sync is an idempotent pair of width pins.
    _G["video_scroll_geometry_changed"] = function()
        M.sync_ruler_gutter()
    end
    qt_constants.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER(
        M.timeline_video_scroll, "video_scroll_geometry_changed")

    -- Set stretch factor so splitter gets all remaining vertical space
    qt_set_layout_stretch_factor(timeline_area_layout, vertical_splitter, 1)

    -- Set layout on timeline area
    qt_constants.LAYOUT.SET_ON_WIDGET(timeline_area, timeline_area_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_area, "Expanding", "Expanding")

    -- Pin headers_column to a fixed width. Initial value mirrors the
    -- previous QSplitter default (timeline_state.dimensions.track_header_width).
    -- The drag-edge handler below mutates min==max as the user drags.
    local INITIAL_HEADERS_WIDTH = timeline_state.dimensions.track_header_width
    assert(type(INITIAL_HEADERS_WIDTH) == "number" and INITIAL_HEADERS_WIDTH > 0,
        "timeline_panel: dimensions.track_header_width must be a positive number")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(headers_column, "Fixed", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(headers_column, INITIAL_HEADERS_WIDTH)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(headers_column, INITIAL_HEADERS_WIDTH)

    -- Vertical drag-edge between the two columns. split_h cursor; drag
    -- handler live-resizes headers_column's min==max. Width matches the
    -- row-resize edges (RESIZE_EDGE_PX) for visual consistency.
    local width_drag_edge = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(width_drag_edge, "Fixed", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(width_drag_edge, RESIZE_EDGE_PX)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(width_drag_edge, RESIZE_EDGE_PX)
    -- luacheck: globals qt_set_widget_cursor qt_set_widget_drag_handler
    qt_set_widget_cursor(width_drag_edge, "split_h")

    -- Drag state captured on "start" and consumed on "move".
    local headers_width_press_x = 0
    local headers_width_orig = INITIAL_HEADERS_WIDTH
    local headers_width_handler = "headers_column_width_drag_"
        .. tostring(width_drag_edge):gsub("[^%w]", "_")
    _G[headers_width_handler] = function(event_type, global_x, _global_y, _modifiers)
        if event_type == "start" then
            headers_width_press_x = global_x
            local cur_w = qt_constants.PROPERTIES.GET_SIZE(headers_column)
            assert(type(cur_w) == "number" and cur_w > 0,
                "headers width drag[start]: GET_SIZE returned non-numeric width")
            headers_width_orig = cur_w
        elseif event_type == "move" then
            local dx = global_x - headers_width_press_x
            local new_w = math.max(INITIAL_HEADERS_WIDTH,
                headers_width_orig + dx)
            qt_constants.PROPERTIES.SET_MIN_WIDTH(headers_column, new_w)
            qt_constants.PROPERTIES.SET_MAX_WIDTH(headers_column, new_w)
            -- tc_header (above the headers in the column wrapper) mirrors
            -- the column width — same constraint the old splitter-moved
            -- cascade enforced.
            qt_constants.PROPERTIES.SET_MIN_WIDTH(tc_header, new_w)
            qt_constants.PROPERTIES.SET_MAX_WIDTH(tc_header, new_w)
        end
    end
    qt_set_widget_drag_handler(width_drag_edge, headers_width_handler)

    qt_constants.LAYOUT.ADD_WIDGET(main_row_layout, headers_column)
    qt_constants.LAYOUT.ADD_WIDGET(main_row_layout, width_drag_edge)
    qt_constants.LAYOUT.ADD_WIDGET(main_row_layout, timeline_area)

    -- Add main_row to outer main_layout (gets all available vertical space).
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, tab_bar_widget)
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, main_row)
    qt_set_layout_stretch_factor(main_layout, main_row, 1)

    -- Scrollbar temporarily removed to test portal height allocation
    -- local scrollbar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    -- local scrollbar = timeline_scrollbar.create(scrollbar_widget, state)
    -- qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(scrollbar_widget, "Expanding", "Fixed")
    -- qt_constants.LAYOUT.ADD_WIDGET(main_layout, scrollbar_widget)

    -- (Width-resize cascade is now owned by the drag-edge handler above:
    -- it pins headers_column AND tc_header min==max width directly, so
    -- there's no need for a separate splitter-moved cascade.)

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

    -- Header columns are passive followers of the timeline panes — they
    -- never scroll on their own. Capture wheel gestures over them and
    -- route through the model write path like any other scroll gesture
    -- (the sync handlers above then mirror the result back to the
    -- headers). Without this capture Qt would scroll the header area
    -- natively, the model would never hear about it, and the next
    -- model projection would snap the headers back.
    -- luacheck: globals qt_set_scroll_area_wheel_handler
    _G["header_video_wheel"] = function(dy)
        M.user_scroll_pane_by("video", dy)
    end
    qt_set_scroll_area_wheel_handler(header_video_scroll, "header_video_wheel")

    _G["header_audio_wheel"] = function(dy)
        M.user_scroll_pane_by("audio", dy)
    end
    qt_set_scroll_area_wheel_handler(header_audio_scroll, "header_audio_wheel")

    -- (Headers column width is already pinned to track_header_width above
    -- via SET_MIN/MAX_WIDTH on headers_column; the drag-edge handler
    -- mutates that pin as the user drags. Timeline area Expanding policy
    -- absorbs the rest. No splitter to initialize.)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, main_layout)

    -- Make main container expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Expanding", "Expanding")

    M.container = container
    M.main_row = main_row
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
    local initial_sequence_id = state.get_tab_strip():active_sequence_id() or nil
    if initial_sequence_id and initial_sequence_id ~= "" then
        ensure_tab_for_sequence(initial_sequence_id)
        -- At bootstrap the displayed and active are the same record sequence,
        -- but use the canonical displayed accessor so the strip-authoritative
        -- contract is preserved through every styling call.
        update_tab_styles(timeline_state.get_displayed_tab_id())
    end

    if not tab_command_listener and command_manager and command_manager.add_listener then
        tab_command_listener = command_manager.add_listener(profile_scope.wrap(
            "timeline_panel.command_listener",
            function(event)
                handle_tab_command_event(event)
            end
        ))
    end

    -- Bidirectional playhead sync between the timeline view (state) and
    -- whichever monitor is currently the timeline view's "engine". When
    -- the source tab is displayed, the source monitor IS that engine
    -- (scrubbing the timeline view drives the source viewer). When a
    -- record tab is displayed, the timeline monitor is the engine. The
    -- timeline_monitor itself is BONDED to the active record sequence
    -- regardless of which tab is displayed (see active_sequence_changed).
    local pm = require("ui.panel_manager")
    local tl_monitor  = pm.get_sequence_monitor("timeline_monitor")
    local src_monitor = pm.get_sequence_monitor("source_monitor")

    local last_viewer_playhead = nil
    local viewer_seek_pending = false
    local viewer_seek_target = nil
    local VIEWER_SEEK_DEFER_MS = ui_constants.TIMELINE.VIEWER_SEEK_DEFER_MS or 1

    -- Resolve the monitor whose playhead the timeline view both reads
    -- from and writes to right now. Determined by displayed_tab_id ==
    -- source-monitor's loaded master.
    local function get_view_engine()
        local displayed = state.get_displayed_tab_id and state.get_displayed_tab_id()
        if displayed and displayed == get_source_master_seq_id() then
            return src_monitor
        end
        return tl_monitor
    end

    -- Viewer → State: only the CURRENT view-engine's playhead changes
    -- propagate to timeline state. Both monitors fire ticks (timeline
    -- monitor on record playback, source monitor on source scrubbing);
    -- the guard ensures the off-screen monitor doesn't write into state.
    local function bind_engine_to_state(monitor)
        monitor:add_listener(function()
            if get_view_engine() ~= monitor then return end
            local playhead_frame = monitor.playhead
            last_viewer_playhead = playhead_frame
            state.set_playhead_position(playhead_frame)
        end)
    end
    bind_engine_to_state(tl_monitor)
    bind_engine_to_state(src_monitor)

    -- Load initial active record into the timeline_monitor (skipped when blank).
    if initial_sequence_id and initial_sequence_id ~= "" then
        local load_ok, load_err = pcall(tl_monitor.load_sequence, tl_monitor, initial_sequence_id)
        if not load_ok then
            log.error("Failed to load initial sequence %s: %s", tostring(initial_sequence_id), tostring(load_err))
        end
    end

    -- (Scroll restore needs no deferred listener: the model is projected
    -- onto the panes by rebuild_for_displayed_tab, and Qt's rangeChanged
    -- handlers re-apply it whenever layout catches up with new content.)

    -- State → Viewer: state changes (commands, ruler clicks, timecode entry)
    -- propagate to whichever monitor is currently the timeline view's engine.
    -- Decimation: deferred via timer so timeline repaints aren't blocked by frame decode.
    state.add_listener(function()
        local view_engine = get_view_engine()
        if not view_engine.engine:is_playing() and view_engine.sequence_id then
            local playhead = state.get_playhead_position()
            if playhead == last_viewer_playhead then return end
            viewer_seek_target = playhead
            if viewer_seek_pending then return end
            viewer_seek_pending = true
            qt_create_single_shot_timer(VIEWER_SEEK_DEFER_MS, function()
                viewer_seek_pending = false
                -- Cancelled by displayed_tab_cleared while pending: the
                -- captured target was a stale frame from the closed
                -- sequence (its extent may not contain that frame anymore).
                if viewer_seek_target == nil then return end
                local target = viewer_seek_target
                if target == last_viewer_playhead then return end
                last_viewer_playhead = target
                get_view_engine():seek_to_frame(target)
            end)
        end
    end)

    -- Displayed tab cleared (close-last-tab / ShowSourceTab no-master /
    -- Toggle no-master): a deferred viewer seek scheduled against the
    -- closed sequence's playhead must NOT fire — it would Park a stale
    -- frame against the new (or absent) sequence's bounds. Cancel the
    -- pending target; the timer callback gates on viewer_seek_target nil.
    Signals.connect("displayed_tab_cleared", function(_prev_seq_id)
        viewer_seek_target = nil
        last_viewer_playhead = nil
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

    local clips = state.get_tab_strip():displayed_clips()
    if not clips or #clips == 0 then
        return
    end

    local min_start, max_end
    for _, clip in ipairs(clips) do
        if not clip.is_gap then
            local s = clip.sequence_start
            local d = clip.duration
            assert(type(s) == "number", string.format(
                "zoom_to_fit_if_first_open: clip %s has non-number sequence_start: %s",
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
    assert(type(tc_floor) == "number",
        "zoom_to_fit_if_first_open: start_timecode_frame nil — no displayed tab "
        .. "or cache uninitialised (H1 invariant)")
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

--- Build a merged tab_order: source tab forced leftmost (FR-001 singleton-
--- first), then saved IDs in their saved order (validated), then any extras.
local function build_merged_tab_order(saved_order)
    local new_order = {}
    local seen = {}
    -- Force the SourceTab to position 1 regardless of where it lived in
    -- the saved order. Older sessions may have persisted it in a later
    -- slot; we don't want that to leak forward.
    for id, tab in pairs(open_tabs) do
        if tab.strip_tab and tab.strip_tab.kind == "source" then
            new_order[#new_order + 1] = id
            seen[id] = true
            break  -- singleton
        end
    end
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

    -- Strip styling: drive off DISPLAYED tab so opening a record tab while
    -- the source tab is showing doesn't move the underline away from source.
    update_tab_styles(timeline_state.get_displayed_tab_id())
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

--- Test-only introspection: which sequence_id currently owns the
--- source-tab panel slot, or nil if no source tab is open. Mirrors the
--- internal source_tab_seq_id state; used to verify the rekey-in-place
--- invariant from integration tests that drive source_loaded_changed.
function M._test_get_source_tab_seq_id()
    return source_tab_seq_id
end

--------------------------------------------------------------------------------
-- Vertical scroll: single-owner plumbing (2026-06-09 redesign)
--
-- The displayed tab's cache (via timeline_state get/set_*_scroll_offset)
-- is the ONLY owner of scroll position, in anchored coordinates:
-- video = px from content BOTTOM (V1 visible at 0), audio = px from TOP
-- (A1 visible at 0). The QScrollAreas are projections: every user
-- gesture (timeline wheel, scrollbar action, header-column wheel) and
-- every navigation (scroll-into-view) writes the model through the two
-- entry points below, which then push to the widget. Qt's rangeChanged
-- re-applies the model whenever layout catches up — replacing the old
-- BottomAnchorFilter and deferred-restore mechanisms whose races
-- destroyed saved offsets (test_scroll_survives_tab_switch.lua).
--------------------------------------------------------------------------------

local function pane_scroll_area(pane)
    if pane == "video" then return M.timeline_video_scroll end
    if pane == "audio" then return M.timeline_audio_scroll end
    error("timeline_panel: unknown scroll pane '" .. tostring(pane) .. "'")
end

local function pane_model_offset(pane)
    if pane == "video" then return state.get_video_scroll_offset() end
    return state.get_audio_scroll_offset()
end

local function pane_set_model_offset(pane, offset)
    if pane == "video" then
        state.set_video_scroll_offset(offset)
    else
        state.set_audio_scroll_offset(offset)
    end
end

-- Anchored model offset ↔ Qt's top-anchored scrollbar value.
-- Video stacks bottom-up (V1 at the content bottom), so its offset is
-- measured from the bottom: value = max - offset. Audio is top-anchored:
-- value = offset. max is the scrollbar maximum at conversion time.
local function model_offset_to_value(pane, offset, max)
    if pane == "video" then return max - offset end
    return offset
end

local function value_to_model_offset(pane, value, max)
    if pane == "video" then return max - value end
    return value
end

--- Project the model's scroll offset onto the pane's QScrollArea.
--- Idempotent and safe to call on every rangeChanged: when the model
--- offset exceeds the current range the value pins at the nearest edge
--- WITHOUT writing the clamp back to the model, so the user's position
--- re-emerges intact once the content is tall enough again.
function M.apply_pane_scroll(pane)
    local sa = pane_scroll_area(pane)
    if not sa then return end  -- panel not built yet (bootstrap)
    local offset = pane_model_offset(pane)
    if not offset then return end  -- blank panel (no displayed tab)
    local _, max = qt_get_scroll_area_v_metrics(sa)  -- luacheck: globals qt_get_scroll_area_v_metrics
    if not max then return end  -- widget destroyed (teardown)
    local value = model_offset_to_value(pane, offset, max)
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLL(
        sa, math.max(0, math.min(max, value)))
end

--- User gesture / navigation: scroll a pane to an absolute scrollbar
--- value. Clamps to the current range, writes the model (anchored
--- coords), then projects back onto the widget. The model write also
--- arms the throttle persist.
function M.user_scroll_pane_to(pane, value)
    local sa = pane_scroll_area(pane)
    assert(sa, "timeline_panel.user_scroll_pane_to: scroll area for '"
        .. pane .. "' not built — gestures cannot precede panel creation")
    local _, max = qt_get_scroll_area_v_metrics(sa)  -- luacheck: globals qt_get_scroll_area_v_metrics
    if not max then return end  -- widget destroyed (teardown)
    value = math.max(0, math.min(max, value))
    pane_set_model_offset(pane, value_to_model_offset(pane, value, max))
    M.apply_pane_scroll(pane)
end

--- Keep the ruler's time→x span identical to the track views'. The
--- vertical scrollbar reserves a gutter inside each pane's scroll area
--- (a STYLE metric: 0 on overlay-scrollbar systems, the scrollbar's
--- hinted width otherwise — qt_get_scroll_area_v_gutter asks the style
--- directly, so the value is stable regardless of in-flight layout
--- passes, unlike measuring widget widths). Mirror it into the ruler
--- row's trailing spacer so ruler width == track viewport width by
--- construction. Both panes are AlwaysOn, so one pane's gutter speaks
--- for both.
function M.sync_ruler_gutter()
    if not (M._ruler_gutter and M.timeline_video_scroll) then
        return  -- panel not built yet (bootstrap)
    end
    -- luacheck: globals qt_get_scroll_area_v_gutter
    local gutter = qt_get_scroll_area_v_gutter(M.timeline_video_scroll)
    if not gutter then return end  -- widget destroyed (teardown)
    qt_constants.PROPERTIES.SET_MIN_WIDTH(M._ruler_gutter, gutter)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(M._ruler_gutter, gutter)
    -- The horizontal bar's row mirrors the same gutter so its track ends
    -- where the lanes' content does.
    if M._h_scroll_gutter then
        qt_constants.PROPERTIES.SET_MIN_WIDTH(M._h_scroll_gutter, gutter)
        qt_constants.PROPERTIES.SET_MAX_WIDTH(M._h_scroll_gutter, gutter)
    end
end

--- Project the model's time viewport onto the horizontal scrollbar.
--- Pure read→write: frames in, frames out, no echo (programmatic
--- setters never emit the user-scroll signal). On a blank panel the
--- range collapses to [0,0], which renders the bar inert.
function M.sync_h_scrollbar()
    if not M.timeline_h_scrollbar then
        return  -- panel not built yet (bootstrap)
    end
    local start = state.get_viewport_start_time()
    local duration = state.get_viewport_duration()
    -- luacheck: globals qt_set_scroll_bar_metrics
    if not start or not duration then
        qt_set_scroll_bar_metrics(M.timeline_h_scrollbar, 0, 0, 0, 0)
        return
    end
    local extent = state.get_timeline_extent()
    local floor = state.get_start_timecode_frame()
    assert(type(floor) == "number",
        "timeline_panel.sync_h_scrollbar: displayed tab has a viewport but "
        .. "no sequence_timecode_start_frame (sequence load did not run)")
    local max_start = math.max(floor, extent - duration)
    qt_set_scroll_bar_metrics(
        M.timeline_h_scrollbar, floor, max_start, start, duration)
end

--- User gesture: pan the time viewport so it starts at an absolute
--- frame (the horizontal bar's thumb target). Dispatches the same
--- ScrollTimelineViewport command as a horizontal wheel — the model
--- clamps to the sequence extent — then re-projects so the thumb snaps
--- to the clamped result even when the command was a no-op.
function M.user_scroll_timeline_to(start_frame)
    assert(M.timeline_h_scrollbar,
        "timeline_panel.user_scroll_timeline_to: panel not built — "
        .. "gestures cannot precede panel creation")
    local current = state.get_viewport_start_time()
    if not current then return end  -- blank panel: bar is inert ([0,0])
    local delta = start_frame - current
    if delta ~= 0 then
        require("core.command_manager").execute("ScrollTimelineViewport", {
            delta_frames = delta,
        })
    end
    M.sync_h_scrollbar()
end

--- User gesture: scroll a pane by a wheel delta (widget px). Matches
--- Qt's native wheel direction: positive dy (fingers swipe down on a
--- natural-scrolling trackpad) moves the content down, i.e. decreases
--- the scrollbar value.
function M.user_scroll_pane_by(pane, dy)
    local sa = pane_scroll_area(pane)
    assert(sa, "timeline_panel.user_scroll_pane_by: scroll area for '"
        .. pane .. "' not built — gestures cannot precede panel creation")
    local value = qt_get_scroll_area_v_metrics(sa)  -- luacheck: globals qt_get_scroll_area_v_metrics
    if not value then return end  -- widget destroyed (teardown)
    M.user_scroll_pane_to(pane, value - dy)
end

--- Single canonical timeline-view rebuild path. Reads from the model
--- (`state.get_displayed_tab_id()`) and refreshes the timeline view's
--- track headers, tab widget, scroll restore, and engine load to match.
--- Called by M.load_sequence (record path) AND by the displayed_tab_changed
--- listener (source path). Both pointer-update entry points
--- (switch_to_source_tab, switch_to_record_tab) emit the signal that
--- triggers the listener; the rebuild is signal-driven and pull-based
--- per CLAUDE.md MVC rule 3.0.
local function rebuild_for_displayed_tab()
    local displayed_id = timeline_state.get_displayed_tab_id()
    assert(displayed_id and displayed_id ~= "",
        "rebuild_for_displayed_tab: no displayed_tab_id set")

    -- Skip if the panel hasn't been constructed yet (bootstrap sequencing).
    if not M.header_video_scroll then return end

    -- Timeline-view data (tracks, clips, view-state) lives on the
    -- displayed TimelineTab's cache, hydrated by strip:open_record_tab /
    -- open_source_tab before displayed_tab_changed fired. This function
    -- does widget-level rebuild only — pull from the displayed tab via
    -- the strip (MVC rule 3.0).
    if M.header_video_scroll and M.header_audio_scroll then
        local new_video_container = select(1, create_video_headers())
        qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(M.header_video_scroll, new_video_container)

        local new_audio_container = select(1, create_audio_headers())
        qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(M.header_audio_scroll, new_audio_container)

        if M.headers_main_splitter then
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(M.headers_main_splitter, {1, 1})
        end

        -- Both builders have registered every src-btn into src_btn_by_rec.
        -- Run a single render-projection pass to fill labels for whichever
        -- rec rows the effective source's tracks route to (or leave all
        -- empty if no source is loaded).
        rerender_all_src_btns()
    end

    -- Project the incoming tab's scroll offsets (already on its cache,
    -- hydrated from the DB by tab:load_from_database) onto the panes.
    -- If Qt's range still reflects the OUTGOING tab's layout, the value
    -- pins at an edge without touching the model; the rangeChanged
    -- handlers re-apply as soon as the new content's range exists.
    M.apply_pane_scroll("video")
    M.apply_pane_scroll("audio")
    M.sync_ruler_gutter()
    M.sync_h_scrollbar()

    -- Tab widget: ensure it exists in the strip and apply current styling.
    -- The underline tracks the DISPLAYED tab (which is what we just swapped
    -- to), not the active record — they differ when SourceTab is shown.
    local tab_existed = open_tabs[displayed_id] ~= nil
    ensure_tab_for_sequence(displayed_id)
    update_tab_styles(displayed_id)
    if not tab_existed then
        persist_open_tabs()
    end

    -- The timeline_monitor's loaded sequence is owned by active_sequence
    -- (not displayed_tab) — it always shows the active record. The source
    -- monitor is owned by source_viewer.load_master_clip. The timeline
    -- view's "current view engine" is dispatched dynamically based on
    -- which tab is displayed (see get_view_engine), so this function
    -- does not load any monitor.
end

-- Timeline-view-rebuild listener: any pointer transition (record→record,
-- record→source, source→record) flows through here. NOTE: outgoing
-- scroll persistence happens BEFORE the strip swap (timeline_state's
-- switch_to_*_tab wrappers call persist_scroll_offsets first) — doing
-- it here would write outgoing values to the incoming row because the
-- strip pointer has already moved by the time this listener fires.
Signals.connect("displayed_tab_changed", function(_new, _prev)
    rebuild_for_displayed_tab()
end)

-- Active-sequence-only side effects: project-level setting + activating
-- the per-sequence undo stack. Fires only when the active sequence
-- ACTUALLY transitions (FR-005: source-tab click does NOT fire this).
Signals.connect("active_sequence_changed", function(new_active, _prev)
    if not new_active or new_active == "" then return end
    local project_id = state.get_project_id()
    if project_id and project_id ~= "" then
        database.set_project_setting(project_id, "last_open_sequence_id", new_active)
    end
    if command_manager and command_manager.activate_timeline_stack then
        command_manager.activate_timeline_stack(new_active)
    end

    -- The timeline_monitor (record viewer) is BONDED to the active record
    -- sequence, regardless of which tab the timeline view is currently
    -- displaying. Source-tab display does NOT load the master into this
    -- monitor — that's the source monitor's job (see source_viewer).
    local pm = require("ui.panel_manager")
    local tl_monitor = pm.get_sequence_monitor("timeline_monitor")
    if tl_monitor.sequence_id ~= new_active then
        tl_monitor:load_sequence(new_active)
    end
end)

function M.load_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    -- Three cases:
    --   (a) active AND displayed already point at this seq → just restore
    --       viewport state; no init work.
    --   (b) active points here but displayed is something else (source
    --       tab is showing) → swap displayed back to this record tab via
    --       switch_to_record_tab; no full state.init needed.
    --   (c) active points elsewhere → full state.init.
    -- The earlier "check displayed only" form short-circuited case (c)
    -- after open_tab seeded the strip's displayed pointer (drop-to-blank
    -- regression). The "check active only" form short-circuited case
    -- (b) — Joe's tab-click regression today, where clicking the active
    -- record tab while the source tab was displayed did nothing.
    local current_active    = state.get_tab_strip():active_sequence_id()
    local current_displayed = state.get_displayed_tab_id
        and state.get_displayed_tab_id()
    if current_active == sequence_id and open_tabs[sequence_id] then
        if current_displayed == sequence_id then
            M.restore_scroll_and_splitter()
        else
            timeline_state.switch_to_record_tab(sequence_id)
        end
        return
    end

    log.event("Loading sequence %s into timeline panel", sequence_id)
    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)
    assert(sequence, "timeline_panel.load_sequence: failed to load sequence " .. tostring(sequence_id))
    local project_id = sequence.project_id
    assert(project_id and project_id ~= "", "timeline_panel.load_sequence: missing project_id for sequence " .. tostring(sequence_id))

    state.persist_scroll_offsets()

    -- state.init sets active+displayed to sequence_id, loads tracks/clips + view-state,
    -- and emits active_sequence_changed when the active pointer transitions
    -- (the listener handles project-level side effects: last_open setting,
    -- activate_timeline_stack). It does NOT emit displayed_tab_changed —
    -- that's reserved for source/record tab swaps via activate_displayed.
    -- The timeline-view rebuild on the record-tab path is therefore explicit.
    state.init(sequence_id, project_id)

    -- Make load_sequence's postcondition explicit: after this returns,
    -- the record-role transport engine is bound to sequence_id. state.init
    -- emits active_sequence_changed only on actual transitions (its
    -- listener chain wants transition semantics), but bind_role_to_sequence
    -- is engine-state plumbing — it needs to be consistent regardless of
    -- whether the active id transitioned. Relying on the signal misbinds
    -- on the OpenProject-swaps-to-same-sequence-id path (per-test jvp is
    -- a copy of template; both share sequence_id; signal skips; engine
    -- left torn down from project_changed's transport.shutdown). The call
    -- is idempotent in transport.bind_role_to_sequence.
    require("core.playback.transport").bind_role_to_sequence("record", sequence_id)

    zoom_to_fit_if_first_open(sequence)
    rebuild_for_displayed_tab()
end

--- Restore scroll offsets and splitter ratio from persisted state.
-- Called after sequence load and after initial panel creation. Scroll
-- is a pure projection of the model (apply_pane_scroll); the splitter
-- ratio read is per-sequence (H1): nil when no displayed tab — skip
-- rather than write fabricated values to the Qt widget.
function M.restore_scroll_and_splitter()
    M.apply_pane_scroll("video")
    M.apply_pane_scroll("audio")
    if M.vertical_splitter and M.headers_main_splitter then
        local ratio = state.get_video_audio_split_ratio()
        if ratio then
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
end

--- Snapshot current layout state for inheritance by new projects.
-- Scroll offsets come from the model (anchored coordinates), not the
-- widgets — the model is the value the user chose; a widget can be
-- transiently clamped by in-flight layout.
function M.snapshot_layout()
    local snapshot = {}
    if M.vertical_splitter then
        local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(M.vertical_splitter)
        local total = sizes[1] + sizes[2]
        if total > 0 then
            snapshot.split_ratio = sizes[1] / total
        end
    end
    snapshot.video_scroll = state.get_video_scroll_offset()
    snapshot.audio_scroll = state.get_audio_scroll_offset()
    return snapshot
end

--- Apply inherited layout from a previous project.
-- Writes values to the model, then projects onto the Qt widgets.
-- Snapshot scroll values are anchored model coordinates (see
-- snapshot_layout above).
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

    -- Apply scroll offsets (model write + projection)
    if snapshot.video_scroll then
        state.set_video_scroll_offset(snapshot.video_scroll)
        M.apply_pane_scroll("video")
    end
    if snapshot.audio_scroll then
        state.set_audio_scroll_offset(snapshot.audio_scroll)
        M.apply_pane_scroll("audio")
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
    source_tab_seq_id = nil
end

-- Register for project_changed signal
Signals.connect("project_changed", M.on_project_change, 50)

-- ============================================================================
-- View interface
-- ============================================================================

function M:navigate_to_clip(clip_id)
    assert(clip_id, "timeline_panel:navigate_to_clip: clip_id required")
    local clips = timeline_state.get_tab_strip():displayed_clips()
    for _, clip in ipairs(clips) do
        if clip.id == clip_id then
            -- cache.clips uses the Lua-domain field name `sequence_start`
            -- (no `_frame` suffix). Asserted non-nil at load by Clip.load
            -- and by gap_lifecycle.make_gap_clip.
            assert(type(clip.sequence_start) == "number", string.format(
                "timeline_panel:navigate_to_clip: clip %s missing sequence_start",
                tostring(clip_id)))
            timeline_state.set_playhead_position(clip.sequence_start)
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

--- Return a sift-ready snapshot of the displayed-tab clips.
--- Gaps (synthesized in-memory, no name/codec/volume) are excluded — sift
--- and timeline_index treat clips as DB-backed entities. Media-clip fields
--- are asserted at the source (Clip.load) so we read them directly with
--- no `or` fallbacks — a missing field is a model bug, not a sift concern.
--- Consumers (sift, find_dialog, timeline_index) read sequence_start_frame
--- and duration_frames in the `_frame`-suffixed form, so we expose those
--- as the public field names for this VIEW snapshot — they are distinct
--- from the underlying model fields (`sequence_start`, `duration`).
function M:get_clips()
    local raw = timeline_state.get_tab_strip():displayed_clips()
    local clips = {}
    for _, clip in ipairs(raw) do
        if not clip.is_gap then
            assert(type(clip.sequence_start) == "number",
                "timeline_panel:get_clips: clip " .. tostring(clip.id) .. " missing sequence_start")
            assert(type(clip.duration) == "number",
                "timeline_panel:get_clips: clip " .. tostring(clip.id) .. " missing duration")
            assert(type(clip.volume) == "number",
                "timeline_panel:get_clips: clip " .. tostring(clip.id) .. " missing volume")
            assert(type(clip.track_id) == "string" and clip.track_id ~= "",
                "timeline_panel:get_clips: clip " .. tostring(clip.id) .. " missing track_id")
            assert(type(clip.name) == "string",
                "timeline_panel:get_clips: clip " .. tostring(clip.id) .. " missing name")
            -- codec is a media-table field; the timeline-clip query
            -- (database.lua load_clips) joins to media only for name /
            -- file_path / offline_note. No codec on timeline clips —
            -- consumers (sift / find_dialog) read absence as "no codec
            -- column for this row" and skip codec-filtering it. No
            -- fabricated "" — that would silently filter out as
            -- "codec equals empty string" instead of "codec unknown."
            clips[#clips + 1] = {
                id = clip.id,
                name = clip.name,
                duration_frames = clip.duration,
                enabled = clip.enabled ~= false,
                volume = clip.volume,
                sequence_start_frame = clip.sequence_start,
                track_id = clip.track_id,
                properties = {},
            }
        end
    end
    table.sort(clips, function(a, b)
        return a.sequence_start_frame < b.sequence_start_frame
    end)
    return clips
end

--- TEST-ONLY: return a snapshot of how the track header is laid out for
--- the given track id. Used by tests/synthetic/binding/test_015_track_header_layout
--- to verify spec FR-008–FR-021d invariants (cell order, banned cells,
--- lock-not-text-L) without coupling to private Qt widget state.
--- @param track_id string
--- @return table|nil { cells = {string...}, lock_kind = string,
---                    label_text = string } or nil if track not loaded
function M.get_track_header_layout_for_test(track_id)
    assert(track_id and track_id ~= "",
        "get_track_header_layout_for_test: track_id required")
    local refs = track_button_refs[track_id]
    if not refs then return nil end
    return {
        cells      = refs.cells,
        lock_kind  = refs.lock_kind,
        label_text = refs.label_text,
    }
end

--- TEST-ONLY: global screen coords of the center of a clip on the
--- displayed sequence. Smoke tests use this to drive real OS mouse
--- clicks at clip centers via the Python runner.click(gx,gy).
--- Returns (nil, nil) when the clip is not on the displayed sequence
--- (caller asserts loudly — no silent zero-coord clicks).
--- @param clip_id string
--- @return integer|nil, integer|nil global_x, global_y
function M.get_clip_global_center_for_test(clip_id)
    assert(clip_id and clip_id ~= "",
        "get_clip_global_center_for_test: clip_id required")
    local strip = timeline_state.get_tab_strip()
    if not strip then return nil, nil end
    local clip = strip:clip_by_id(clip_id)
    if not clip then return nil, nil end
    local track_type
    for _, t in ipairs(strip:displayed_tracks()) do
        if t.id == clip.track_id then track_type = t.track_type; break end
    end
    if not track_type then return nil, nil end
    local widget, view
    if track_type == "VIDEO" then
        widget = M.video_widget; view = video_view_ref
    elseif track_type == "AUDIO" then
        widget = M.audio_widget; view = audio_view_ref
    else
        return nil, nil
    end
    if not widget or not view then return nil, nil end
    local w, h = qt_constants.PROPERTIES.GET_SIZE(widget)
    if not w or w <= 0 or not h or h <= 0 then return nil, nil end

    -- Mirror what a user does manually: scroll the timeline to bring the
    -- clip into view before clicking. Without this, tests that ran after
    -- a viewport-narrowing test (or simply opened a project whose
    -- saved viewport doesn't cover this clip's frame) compute a pixel x
    -- far outside [0, widget_w], producing off-screen global coords that
    -- System Events refuses (-25200). Center the clip in the current
    -- viewport duration. If the viewport is narrower than the clip,
    -- align the viewport's left edge with the clip's start.
    local vstart = timeline_state.get_viewport_start_time()
    local vdur = timeline_state.get_viewport_duration()
    assert(type(vstart) == "number" and type(vdur) == "number" and vdur > 0,
        "get_clip_global_center_for_test: viewport not initialized")
    local clip_end = clip.sequence_start + clip.duration
    if clip.sequence_start < vstart or clip_end > vstart + vdur then
        local new_start
        if clip.duration >= vdur then
            new_start = clip.sequence_start
        else
            new_start = math.floor(clip.sequence_start - (vdur - clip.duration) / 2)
        end
        timeline_state.set_viewport_start_time(new_start)
    end

    local sx = timeline_state.time_to_pixel(clip.sequence_start, w)
    local ex = timeline_state.time_to_pixel(clip.sequence_start + clip.duration, w)
    -- Pick the center of the clip's intersection with the visible
    -- viewport, not the clip's true center. When the clip is wider
    -- than the viewport (post-scroll the viewport sits inside the
    -- clip), the true center is many widget-widths off-screen and
    -- cliclick at those coords lands in empty space outside the
    -- widget. Clamping each edge to [0, w] keeps the click reliably
    -- inside the clip's body.
    local visible_sx = math.max(sx, 0)
    local visible_ex = math.min(ex, w)
    assert(visible_ex > visible_sx, string.format(
        "get_clip_global_center_for_test: clip %s has no visible width "
        .. "(clip px [%d,%d], widget w=%d) — viewport recenter above "
        .. "should have made it visible",
        tostring(clip_id), sx, ex, w))
    local cx = math.floor((visible_sx + visible_ex) / 2)
    local track_y = view.get_track_y_by_id(clip.track_id, h)
    if not track_y or track_y < 0 then return nil, nil end
    local track_h = view.get_track_visual_height(clip.track_id)
    assert(type(track_h) == "number" and track_h > 0,
        "get_clip_global_center_for_test: track height missing for " .. tostring(clip.track_id))
    -- track_y is in content (widget) coordinates; the QScrollArea pans
    -- the widget itself, so MAP_TO_GLOBAL below already lands on the
    -- on-screen position — no scroll term needed.
    local cy = math.floor(track_y + track_h / 2)
    local gx, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, cx, cy)
    return gx, gy
end

--- TEST-ONLY: return a diagnostic string describing every coordinate
--- the test helper computed for the given clip. Used by smoke runner
--- when click_clip's post-condition check fails — the test would
--- otherwise have to reach into module locals (video_view_ref) which
--- the architectural-correctness rule forbids exposing publicly.
--- Format: `widget_size=WxH widget_global=(X,Y) clip_local_x=[sx,ex]
--- track_y=TY track_h=TH local_center=(cx,cy) global_center=(gx,gy)
--- viewport=[vstart,vdur]`
function M.get_clip_click_diagnostic(clip_id)
    assert(clip_id and clip_id ~= "", "get_clip_click_diagnostic: clip_id required")
    local strip = timeline_state.get_tab_strip()
    if not strip then return "no_strip" end
    local clip = strip:clip_by_id(clip_id)
    if not clip then return "no_clip:" .. clip_id end
    local track_type
    for _, t in ipairs(strip:displayed_tracks()) do
        if t.id == clip.track_id then track_type = t.track_type; break end
    end
    if not track_type then return "no_track" end
    local widget, view
    if track_type == "VIDEO" then widget, view = M.video_widget, video_view_ref
    elseif track_type == "AUDIO" then widget, view = M.audio_widget, audio_view_ref
    else return "unknown_track_type:" .. track_type end
    if not widget or not view then return "no_widget_or_view" end
    local w, h = qt_constants.PROPERTIES.GET_SIZE(widget)
    local vstart = timeline_state.get_viewport_start_time()
    local vdur = timeline_state.get_viewport_duration()
    local sx = timeline_state.time_to_pixel(clip.sequence_start, w)
    local ex = timeline_state.time_to_pixel(clip.sequence_start + clip.duration, w)
    local cx = math.floor((sx + ex) / 2)
    local track_y = view.get_track_y_by_id(clip.track_id, h)
    local track_h = view.get_track_visual_height(clip.track_id)
    local cy = (track_y and track_h) and math.floor(track_y + track_h / 2) or -1
    local gx, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, cx, cy)
    local wgx, wgy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, 0, 0)
    return string.format(
        "widget=%dx%d widget_global=(%d,%d) clip_local_x=[%d,%d] track_y=%s track_h=%s local_center=(%d,%d) global_center=(%d,%d) viewport=[%d,%d] track_id=%s",
        w or -1, h or -1, wgx or -1, wgy or -1, sx, ex, tostring(track_y), tostring(track_h),
        cx, cy, gx or -1, gy or -1, vstart or -1, vdur or -1, clip.track_id:sub(1, 8))
end

--- TEST-ONLY: global screen coords for a click that the edge_picker
--- will resolve to a SPECIFIC edge selection on `clip_id`.
---
--- The picker is driven entirely by cursor-x relative to a boundary
--- pixel (see edge_picker.pick_edges):
---   * within ±EDGE_ZONE_PX of a boundary  → some edge selected
---   * within ±ROLL_ZONE_PX/2 of boundary  → ROLL (both neighbor edges)
---   * outside roll center, inside edge   → RIPPLE on the side
---                                          containing the cursor
--- We pick an offset that lands the cursor in the requested zone, then
--- map to global screen coords. The smoke runner's click() does the rest.
---
--- Preconditions enforced loudly:
---   * For ripple, the target clip's visible width must be ≥
---     MIN_EDGE_SELECTABLE_WIDTH_PX or the picker rejects it.
---   * For roll, BOTH neighbor clips at the boundary must meet that
---     width AND a roll partner must exist (clip can't be at the very
---     start/end of the track — no partner edge).
--- If either fails, the helper raises with the measured widths and the
--- required minimum so the test can zoom the viewport accordingly.
---
--- @param clip_id string
--- @param edge_type string "in" | "out"
--- @param trim_type string "ripple" | "roll"
--- @return integer|nil, integer|nil global_x, global_y
function M.get_clip_edge_global_point_for_test(clip_id, edge_type, trim_type)
    assert(clip_id and clip_id ~= "",
        "get_clip_edge_global_point_for_test: clip_id required")
    assert(edge_type == "in" or edge_type == "out",
        "get_clip_edge_global_point_for_test: edge_type must be 'in'|'out', got "
        .. tostring(edge_type))
    assert(trim_type == "ripple" or trim_type == "roll",
        "get_clip_edge_global_point_for_test: trim_type must be 'ripple'|'roll', got "
        .. tostring(trim_type))

    local edge_zone = ui_constants.TIMELINE.EDGE_ZONE_PX
    local roll_zone = ui_constants.TIMELINE.ROLL_ZONE_PX
    local min_width = ui_constants.TIMELINE.MIN_EDGE_SELECTABLE_WIDTH_PX
    assert(edge_zone and roll_zone and min_width,
        "get_clip_edge_global_point_for_test: ui_constants.TIMELINE edge "
        .. "constants missing (EDGE_ZONE_PX/ROLL_ZONE_PX/MIN_EDGE_SELECTABLE_WIDTH_PX)")
    local center_half = math.max(1, math.floor(roll_zone / 2))
    -- Ripple offset: just outside center band but inside edge zone, on the
    -- clip-body side of the boundary. edge_type=in → body to the right,
    -- so cursor +offset; edge_type=out → body to the left, so −offset.
    local ripple_offset = center_half + 1
    assert(ripple_offset < edge_zone, string.format(
        "get_clip_edge_global_point_for_test: ripple_offset (%d) must be "
        .. "< EDGE_ZONE_PX (%d) — picker zone math is wrong",
        ripple_offset, edge_zone))

    local strip = timeline_state.get_tab_strip()
    assert(strip, "get_clip_edge_global_point_for_test: no tab strip")
    local clip = strip:clip_by_id(clip_id)
    assert(clip, "get_clip_edge_global_point_for_test: clip not found: " .. clip_id)

    local track_type
    for _, t in ipairs(strip:displayed_tracks()) do
        if t.id == clip.track_id then track_type = t.track_type; break end
    end
    assert(track_type, "get_clip_edge_global_point_for_test: clip's track "
        .. "not in displayed_tracks (clip_id=" .. clip_id .. ")")

    local widget, view
    if track_type == "VIDEO" then
        widget, view = M.video_widget, video_view_ref
    elseif track_type == "AUDIO" then
        widget, view = M.audio_widget, audio_view_ref
    else
        error("get_clip_edge_global_point_for_test: unknown track_type " .. track_type)
    end
    assert(widget and view,
        "get_clip_edge_global_point_for_test: widget/view not initialized")

    local w, h = qt_constants.PROPERTIES.GET_SIZE(widget)
    assert(w and w > 0 and h and h > 0,
        "get_clip_edge_global_point_for_test: widget not laid out")

    local boundary_frame = (edge_type == "in")
        and clip.sequence_start
        or  (clip.sequence_start + clip.duration)

    -- Find the partner clip at the boundary (same track, adjacent).
    local partner = nil
    for _, c in ipairs(strip:displayed_clips()) do
        if c.track_id == clip.track_id and c.id ~= clip.id then
            if edge_type == "in"
               and (c.sequence_start + (c.duration or 0)) == boundary_frame then
                partner = c; break
            elseif edge_type == "out"
                   and c.sequence_start == boundary_frame then
                partner = c; break
            end
        end
    end

    if trim_type == "roll" then
        assert(partner, string.format(
            "get_clip_edge_global_point_for_test(%s,%s,roll): no partner "
            .. "clip on track at boundary frame %d — clip is at the "
            .. "start/end of the track; roll requires a neighbor edge",
            clip_id:sub(1, 8), edge_type, boundary_frame))
    end

    -- Scroll the viewport so the boundary sits inside the visible area
    -- with edge_zone+2 px margin on each side.
    local vstart = timeline_state.get_viewport_start_time()
    local vdur = timeline_state.get_viewport_duration()
    assert(type(vstart) == "number" and type(vdur) == "number" and vdur > 0,
        "get_clip_edge_global_point_for_test: viewport not initialized")
    local frames_per_px = vdur / w
    local margin_frames = math.ceil((edge_zone + 2) * frames_per_px)
    if boundary_frame - margin_frames < vstart
       or boundary_frame + margin_frames > vstart + vdur then
        timeline_state.set_viewport_start_time(
            math.floor(boundary_frame - vdur / 2))
    end

    -- Width validation. Picker rejects edges whose owning clip's visible
    -- pixel width < MIN_EDGE_SELECTABLE_WIDTH_PX.
    local function clip_visible_width_px(c)
        local sx = timeline_state.time_to_pixel(c.sequence_start, w)
        local ex = timeline_state.time_to_pixel(c.sequence_start + c.duration, w)
        return math.max(0, math.min(ex, w) - math.max(sx, 0))
    end
    local target_width = clip_visible_width_px(clip)
    assert(target_width >= min_width, string.format(
        "get_clip_edge_global_point_for_test(%s,%s,%s): target clip's "
        .. "visible width %dpx < MIN_EDGE_SELECTABLE_WIDTH_PX %dpx. "
        .. "Zoom viewport in (current vdur=%d frames @ %dpx) before "
        .. "calling this helper.",
        clip_id:sub(1, 8), edge_type, trim_type,
        target_width, min_width, vdur, w))
    if trim_type == "roll" then
        local partner_width = clip_visible_width_px(partner)
        assert(partner_width >= min_width, string.format(
            "get_clip_edge_global_point_for_test(%s,%s,roll): partner "
            .. "clip %s visible width %dpx < MIN_EDGE_SELECTABLE_WIDTH_PX "
            .. "%dpx. Zoom viewport in.",
            clip_id:sub(1, 8), edge_type,
            partner.id:sub(1, 8), partner_width, min_width))
    end

    local boundary_px = timeline_state.time_to_pixel(boundary_frame, w)
    local cursor_x
    if trim_type == "roll" then
        cursor_x = math.floor(boundary_px)
    elseif edge_type == "in" then
        cursor_x = math.floor(boundary_px + ripple_offset)
    else
        cursor_x = math.floor(boundary_px - ripple_offset)
    end
    assert(cursor_x >= 0 and cursor_x < w, string.format(
        "get_clip_edge_global_point_for_test: cursor_x %d out of widget "
        .. "bounds [0,%d) — boundary_px=%d", cursor_x, w, boundary_px))

    local track_y = view.get_track_y_by_id(clip.track_id, h)
    assert(track_y and track_y >= 0,
        "get_clip_edge_global_point_for_test: track_y missing for " .. clip.track_id)
    local track_h = view.get_track_visual_height(clip.track_id)
    assert(type(track_h) == "number" and track_h > 0,
        "get_clip_edge_global_point_for_test: track_h missing for " .. clip.track_id)
    local cy = math.floor(track_y + track_h / 2)

    local gx, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, cursor_x, cy)
    return gx, gy
end

return M
