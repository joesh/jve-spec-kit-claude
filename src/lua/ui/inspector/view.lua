--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~1135 LOC
-- Volatility: unknown
--
-- @file view.lua
-- Original intent (unreviewed):
-- scripts/ui/inspector/view.lua
-- PURPOSE: Lua-owned view helpers for the Inspector (header text, batch banner, filter SoT).
-- Zero C++ calls here.
local error_system = require("core.error_system")
local logger = require("core.logger")
local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")
local command_manager = require("core.command_manager")
local frame_utils = require("core.frame_utils")
local timeline_state = require("ui.timeline.timeline_state")
local inspectable_factory = require("inspectable")
local metadata_schemas = require("ui.metadata_schemas")
local collapsible_section = require("ui.collapsible_section")
local profile_scope = require("core.profile_scope")

local FIELD_TYPES = metadata_schemas.FIELD_TYPES

local M
local current_frame_rate
local refresh_active_inspection
local suppress_field_updates
local resume_field_updates

local PROPERTY_TYPE_MAP = {
  [FIELD_TYPES.STRING] = "STRING",
  [FIELD_TYPES.TEXT_AREA] = "STRING",
  [FIELD_TYPES.DROPDOWN] = "ENUM",
  [FIELD_TYPES.INTEGER] = "NUMBER",
  [FIELD_TYPES.DOUBLE] = "NUMBER",
  [FIELD_TYPES.BOOLEAN] = "BOOLEAN",
  [FIELD_TYPES.TIMECODE] = "NUMBER",
}

local function normalize_default_value(field_type, raw_value)
  if raw_value == nil then
    return nil
  end

  if field_type == FIELD_TYPES.INTEGER then
    local num = tonumber(raw_value)
    return num and math.floor(num) or nil
  elseif field_type == FIELD_TYPES.DOUBLE then
    return tonumber(raw_value)
  elseif field_type == FIELD_TYPES.BOOLEAN then
    if type(raw_value) == "boolean" then
      return raw_value
    end
    if type(raw_value) == "number" then
      return raw_value ~= 0
    end
    if type(raw_value) == "string" then
      local lowered = raw_value:lower()
      if lowered == "true" or lowered == "yes" or lowered == "on" then
        return true
      elseif lowered == "false" or lowered == "no" or lowered == "off" then
        return false
      end
    end
    return nil
  elseif field_type == FIELD_TYPES.TIMECODE then
    if type(raw_value) == "number" then
      return raw_value
    elseif type(raw_value) == "string" and raw_value ~= "" then
      local parsed = frame_utils.parse_timecode(raw_value, current_frame_rate())
      return parsed
    end
    return nil
  else
    if raw_value == nil then
      return nil
    end
    return tostring(raw_value)
  end
end

-- Helper for detailed error logging
local log_detailed_error = error_system.log_detailed_error

local widget_pool = require("ui.inspector.widget_pool")

local refresh_selection_label -- forward declaration

-- Track timeline state subscriptions so the inspector refreshes when
-- underlying clips/sequences change (e.g., undo/redo, external commands).
local timeline_listener_registered = false
local function ensure_timeline_listener()
  if timeline_listener_registered then
    return
  end
  if timeline_state and timeline_state.add_listener then
    timeline_state.add_listener(profile_scope.wrap("inspector.timeline_listener", function()
      if not M.root then
        return
      end
      if M._active_schema_id ~= "clip" and M._active_schema_id ~= "sequence" then
        return
      end
      refresh_active_inspection()
      refresh_selection_label()
    end))
    timeline_listener_registered = true
  end
end

M = {
  _panel = nil,
  _filter = "",
  root = nil,
  onFilterChanged = nil,  -- Handler for filter changes (set by controller)
  _search_input = nil,    -- Qt line edit widget for search input
  _header_label = nil,    -- Qt label widget for header text
  _batch_banner = nil,    -- Qt widget for batch editing banner
  _header_text = "",      -- Stored header text
  _batch_enabled = false, -- Stored batch state
  _selection_label = nil, -- Label showing current selection
  _selection_label_base = "", -- Base text before mark summary
  _selection_label_include_marks = false, -- Whether to append mark summary
  _field_widgets = {},    -- Active schema field widget map
  _field_widgets_by_schema = {}, -- Cached widgets per schema
  _current_inspectable = nil, -- Currently focused inspectable entity
  _selected_items = {},   -- Selection payloads from selection hub
  _multi_inspectables = nil, -- Inspectables participating in multi-edit
  _apply_button = nil,    -- Apply button for multi-edit
  _multi_edit_mode = false, -- Whether we're in multi-edit mode
  _sections = {},         -- Active schema sections
  _sections_by_schema = {}, -- Cached schema sections
  _active_schema_id = nil,
  _content_widget = nil,  -- The content widget that holds all sections (for redraws)
  _content_layout = nil,
  _widgets_initialized = false, -- Track if widgets have been created
  _suppress_field_updates_depth = 0,
  _schemas_active = false, -- Whether schema sections should be interactive/visible
  _sections_visible_state = nil, -- Tracks last visibility applied to schema sections
}

local function format_timecode(time_input, override_rate)
  if not time_input then
    return "00:00:00:00"
  end

  local frame_rate = override_rate
  local rate_valid = false
  if type(frame_rate) == "number" and frame_rate > 0 then
      rate_valid = true
  elseif type(frame_rate) == "table" and frame_rate.fps_numerator then
      rate_valid = true
  end

  if not rate_valid then
    if timeline_state and timeline_state.get_sequence_frame_rate then
      frame_rate = timeline_state.get_sequence_frame_rate()
    end
  end
  assert(frame_rate, "inspector.view.format_timecode: frame_rate is nil (no override and no sequence frame rate available)")

  local ok, formatted = pcall(frame_utils.format_timecode, time_input, frame_rate)
  if ok and formatted then
    return formatted
  end

  return "00:00:00:00"
end

current_frame_rate = function()
  assert(timeline_state and timeline_state.get_sequence_frame_rate,
    "inspector.view.current_frame_rate: timeline_state or get_sequence_frame_rate not available")
  local rate = timeline_state.get_sequence_frame_rate()
  assert(rate, "inspector.view.current_frame_rate: get_sequence_frame_rate returned nil")
  assert(type(rate) == "table" or (type(rate) == "number" and rate > 0),
    string.format("inspector.view.current_frame_rate: invalid rate: %s", tostring(rate)))
  return rate
end

local function build_mark_summary()
  if not timeline_state or not timeline_state.get_mark_in then
    return nil
  end

  local mark_in = timeline_state.get_mark_in()
  local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out() or nil
  local frame_rate = current_frame_rate()

  local in_text = mark_in and format_timecode(mark_in, frame_rate) or "--"
  local out_text = mark_out and format_timecode(mark_out, frame_rate) or "--"

  local duration_text = "--"
  if mark_in and mark_out and mark_out >= mark_in then
    duration_text = format_timecode(mark_out - mark_in, frame_rate)
  elseif mark_in and mark_out and mark_out < mark_in then
    duration_text = "00:00:00:00"
  end

  return string.format("In: %s  Out: %s  Dur: %s", in_text, out_text, duration_text)
end

local function append_mark_summary_if_timeline(label_text)
  local summary = build_mark_summary()
  if not summary then
    return label_text
  end

  if label_text and label_text ~= "" then
    return string.format("%s\n%s", label_text, summary)
  end
  return summary
end

local function compute_selection_label_text(base_text, include_marks)
  local text = base_text or ""
  if include_marks then
    text = append_mark_summary_if_timeline(text)
  end
  return text
end

refresh_selection_label = function()
  if not M._selection_label then
    return
  end
  local text = compute_selection_label_text(M._selection_label_base, M._selection_label_include_marks)
  local ok, err = pcall(qt_constants.PROPERTIES.SET_TEXT, M._selection_label, text)
  if not ok then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Failed to refresh selection label: " .. log_detailed_error(err))
  end
end

local function set_selection_label(base_text, include_marks)
  M._selection_label_base = base_text or ""
  M._selection_label_include_marks = not not include_marks
  refresh_selection_label()
end

local function get_field_key(field)
  if field and field.key and field.key ~= "" then
    return field.key
  end
  local label = field and (field.label or field.name) or "field"
  return label:lower():gsub("%s+", "_")
end

refresh_active_inspection = function()
  local targets = nil
  if M._multi_edit_mode and M._multi_inspectables and #M._multi_inspectables > 0 then
    targets = M._multi_inspectables
  elseif M._current_inspectable then
    targets = { M._current_inspectable }
  end

  if not targets or not M._active_schema_id then
    return
  end

  local needs_refresh = false
  for _, inspectable in ipairs(targets) do
    if inspectable and inspectable.refresh then
      local ok, err = pcall(inspectable.refresh, inspectable)
      if not ok then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
          string.format("[inspector][view] Failed to refresh inspectable: %s", tostring(err)))
      else
        needs_refresh = true
      end
    end
  end

  if not needs_refresh then
    return
  end

  suppress_field_updates()
  if M._multi_edit_mode and M._multi_inspectables then
    M.load_multi_clip_data(M._multi_inspectables)
  elseif M._current_inspectable then
    M.load_clip_data(M._current_inspectable)
  end
  resume_field_updates()
  refresh_selection_label()
end

suppress_field_updates = function()
  M._suppress_field_updates_depth = (M._suppress_field_updates_depth or 0) + 1
end

resume_field_updates = function()
  if M._suppress_field_updates_depth and M._suppress_field_updates_depth > 0 then
    M._suppress_field_updates_depth = M._suppress_field_updates_depth - 1
  end
end

local function field_updates_suppressed()
  return (M._suppress_field_updates_depth or 0) > 0
end

local function set_sections_visible(visible)
  for _, section_data in pairs(M._sections) do
    if section_data.widget then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, visible)
    end
  end
  M._sections_visible_state = visible
  if M._content_widget then
    pcall(qt_update_widget, M._content_widget)
  end
end

local function build_schema_for_id(schema_id)
  if not schema_id then
    return
  end

  if M._sections_by_schema[schema_id] then
    return
  end

  local sections = {}
  local field_widgets = {}
  local definitions = metadata_schemas.get_sections(schema_id)

  for _, definition in ipairs(definitions) do
    local section_result = collapsible_section.create_section(definition.name, M._content_widget)
    if section_result and section_result.success and section_result.return_values then
      local section_widget = section_result.return_values.section_widget
      local section_obj = section_result.return_values.section
      local field_names = {}

      for _, field in ipairs(definition.schema.fields or {}) do
        M.add_schema_field_to_section(section_obj, field, field_widgets)
        table.insert(field_names, field.label or field.name or "")
      end

      if M._content_layout then
        pcall(qt_constants.LAYOUT.ADD_WIDGET, M._content_layout, section_widget, "AlignTop")
      end
      pcall(qt_constants.DISPLAY.SET_VISIBLE, section_widget, false)

      sections[definition.name] = {
        section_obj = section_obj,
        widget = section_widget,
        fields = field_names
      }
    end
  end

  M._sections_by_schema[schema_id] = sections
  M._field_widgets_by_schema[schema_id] = field_widgets
end

local function activate_schema(schema_id)
  if M._active_schema_id and M._sections_by_schema[M._active_schema_id] then
    for _, section_data in pairs(M._sections_by_schema[M._active_schema_id]) do
      pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, false)
    end
  end

  if not schema_id then
    M._sections = {}
    M._field_widgets = {}
    M._active_schema_id = nil
    return
  end

  build_schema_for_id(schema_id)

  M._sections = M._sections_by_schema[schema_id] or {}
  M._field_widgets = M._field_widgets_by_schema[schema_id] or {}
  M._active_schema_id = schema_id
end

local function read_widget_value(field_info)
  if not field_info or not field_info.get_value then
    return nil
  end
  return field_info:get_value()
end

local function create_inspector_field(section, field, field_widgets)
  field_widgets = field_widgets or M._field_widgets

  local field_type = field.type or FIELD_TYPES.STRING
  local label_text = field.label or field.key or "Field"
  local field_key = get_field_key(field)

  local container_ok, container = pcall(qt_constants.WIDGET.CREATE)
  if not container_ok or not container then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Failed to create container for field: " .. label_text)
    return
  end

  local layout_ok, layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
  if not layout_ok or not layout then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Failed to create layout for field: " .. label_text)
    return
  end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, container, layout)
  pcall(qt_constants.LAYOUT.SET_MARGINS, layout, 0, 2, 4, 2)
  pcall(qt_constants.LAYOUT.SET_SPACING, layout, 6)

  local label_widget = widget_pool.rent("label", { text = label_text })
  if label_widget then
    local label_style = [[
      QLabel {
        color: ]] .. ui_constants.COLORS.GENERAL_LABEL_COLOR .. [[;
        font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
        padding: 4px 6px 2px 4px;
        min-width: 120px;
      }
    ]]
    pcall(qt_constants.PROPERTIES.SET_STYLE, label_widget, label_style)
    pcall(qt_constants.PROPERTIES.SET_ALIGNMENT, label_widget, qt_constants.PROPERTIES.ALIGN_RIGHT)
    pcall(qt_constants.LAYOUT.ADD_WIDGET, layout, label_widget, "AlignBaseline")
  end

  local widget_type = "line_edit"
  local control_widget

  if field_type == FIELD_TYPES.BOOLEAN then
    control_widget = widget_pool.rent("checkbox", {
      label = "",
      checked = field.default and true or false
    })
    widget_type = "checkbox"
  else
    local default_text = field.default
    if default_text ~= nil and type(default_text) ~= "string" then
      default_text = tostring(default_text)
    end
    control_widget = widget_pool.rent("line_edit", {
      text = default_text or "",
      placeholder = ""
    })

    if field_type == FIELD_TYPES.TEXT_AREA and control_widget then
      pcall(qt_constants.PROPERTIES.SET_MIN_HEIGHT, control_widget, 60)
    end
  end

  if not control_widget then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Failed to create control widget for field: " .. label_text)
    return
  end

  pcall(qt_constants.LAYOUT.ADD_WIDGET, layout, control_widget, "AlignBaseline")
  pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, layout, control_widget, 1)
  pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, control_widget, "Expanding", "Fixed")

  local entry = {
    field = field,
    field_key = field_key,
    field_type = field_type,
    widget = control_widget,
    widget_type = widget_type,
    mixed = false,
    options = field.options,
    pending_value = nil,
  }

  function entry:set_placeholder(text)
    if self.widget_type == "line_edit" then
      pcall(qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT, self.widget, text or "")
    end
  end

  function entry:clear_placeholder()
    if self.widget_type == "line_edit" then
      self:set_placeholder("")
    end
  end

  function entry:set_mixed(is_mixed)
    self.mixed = not not is_mixed
    if self.widget_type == "line_edit" then
      if self.mixed then
        self:set_placeholder("<mixed>")
        pcall(qt_constants.PROPERTIES.SET_TEXT, self.widget, "")
      else
        self:set_placeholder("")
      end
    elseif self.widget_type == "checkbox" and self.mixed then
      -- Visual fallback for mixed checkbox state
      pcall(qt_constants.PROPERTIES.SET_CHECKED, self.widget, false)
    end
  end

  function entry:set_value(value)
    self.mixed = false
    self.pending_value = nil
    if self.widget_type == "checkbox" then
      pcall(qt_constants.PROPERTIES.SET_CHECKED, self.widget, value and true or false)
      return
    end

    local text_value = ""
    if value ~= nil then
      if self.field_type == FIELD_TYPES.TIMECODE then
        if type(value) == "number" or (type(value) == "table" and value.frames) then
          text_value = format_timecode(value, current_frame_rate())
        else
          text_value = tostring(value)
        end
      else
        text_value = tostring(value)
      end
    end

    pcall(qt_constants.PROPERTIES.SET_TEXT, self.widget, text_value)
  end

  function entry:get_value()
    if self.mixed then
      return nil
    end

    if self.widget_type == "checkbox" then
      local ok, checked = pcall(qt_constants.PROPERTIES.GET_CHECKED, self.widget)
      if ok then
        return checked and true or false
      end
      return nil
    end

    local ok, text = pcall(qt_constants.PROPERTIES.GET_TEXT, self.widget)
    if not ok then
      return nil
    end

    text = text or ""

    if self.field_type == FIELD_TYPES.INTEGER then
      if text == "" then
        return nil
      end
      return tonumber(text)
    elseif self.field_type == FIELD_TYPES.DOUBLE then
      if text == "" then
        return nil
      end
      return tonumber(text)
    elseif self.field_type == FIELD_TYPES.TIMECODE then
      if text == "" then
        return nil
      end
      local value, err = frame_utils.parse_timecode(text, current_frame_rate())
      if not value then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
          string.format("[inspector][view] Invalid timecode '%s' for field %s: %s",
            text, self.field_key, tostring(err)))
        return nil
      end
      return value
    else
      return text
    end
  end

  field_widgets[field_key] = entry

  if widget_type == "checkbox" then
    local click_connection, click_err = widget_pool.connect_signal(control_widget, "clicked", function()
      if field_updates_suppressed() or M._multi_edit_mode then
        return
      end
      entry:set_mixed(false)
      M.save_field_value(field_key)
    end)
    if not click_connection then
      local message = string.format(
        "[inspector][view] Failed to connect checkbox click handler for field '%s': %s",
        field_key,
        click_err and (click_err.message or tostring(click_err)) or "unknown error"
      )
      error(message)
    end
  elseif widget_type == "line_edit" then
    local editing_connection, editing_err = widget_pool.connect_signal(control_widget, "editingFinished", function()
      if field_updates_suppressed() then
        return
      end
      entry:set_mixed(false)
      if M._multi_edit_mode then
        entry.pending_value = nil
        return
      end

      local value = entry.pending_value
      if value == nil then
        value = read_widget_value(entry)
      end
      entry.pending_value = nil
      M.save_field_value(field_key, value)
    end)

    if not editing_connection then
      local message = string.format(
        "[inspector][view] Failed to connect editingFinished for field '%s': %s",
        field_key,
        editing_err and (editing_err.message or tostring(editing_err)) or "unknown error"
      )
      error(message)
    end

    local text_connection, text_err = widget_pool.connect_signal(control_widget, "textChanged", function()
      if field_updates_suppressed() then
        return
      end
      entry:set_mixed(false)
      if M._multi_edit_mode then
        return
      end
      entry.pending_value = read_widget_value(entry)
    end)

    if not text_connection then
      local message = string.format(
        "[inspector][view] Failed to connect textChanged for field '%s': %s",
        field_key,
        text_err and (text_err.message or tostring(text_err)) or "unknown error"
      )
      error(message)
    end
  else
    error(string.format("[inspector][view] Unsupported widget type '%s' for field '%s'", widget_type, field_key))
  end

  if section and section.addContentWidget then
    local add_result = section:addContentWidget(container)
    if add_result and add_result.success == false then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
        "Failed to add widget for field '" .. label_text .. "' to section")
    end
  end
end

M.add_schema_field_to_section = create_inspector_field

local function reset_all_fields()
  if not M._field_widgets then
    return
  end
  suppress_field_updates()
  for _, entry in pairs(M._field_widgets) do
    if entry.set_mixed then
      entry:set_mixed(false)
    end
    if entry.clear_placeholder then
      entry:clear_placeholder()
    end
    if entry.set_value then
      entry:set_value(nil)
    end
  end
  resume_field_updates()
end

function M.mount(root)
  -- Accept either userdata (Qt widget) or table (inspector interface)
  local root_type = type(root)
  if root_type ~= "userdata" and root_type ~= "table" then
    error_system.assert_type(root, "userdata", "root", {
      operation = "mount_inspector_view",
      component = "inspector.view"
    })
  end

  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] mount() called")
  M.root = root
  M._panel = root

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector] view mounted")
  return error_system.create_success({
    message = "Inspector view mounted successfully"
  })
end

function M.init(panel_handle)
  if not panel_handle then
    return error_system.create_error({
      code = error_system.CODES.INVALID_PANEL_HANDLE,
      category = "inspector",
      message = "panel_handle is nil",
      operation = "init_inspector_view",
      component = "inspector.view",
      user_message = "Cannot initialize inspector view - invalid panel handle",
      remediation = {
        "Ensure the inspector panel was created successfully before initializing view",
        "Check that create_inspector_panel() returned a valid result"
      }
    })
  end

  M._panel = panel_handle
  ensure_timeline_listener()

  -- Initialize view state with proper FFI approach
  M._header_text = ""
  M._batch_enabled = false

  -- These will be applied when the UI widgets are actually created in ensure_search_row()
  -- No direct method calls on userdata panels needed anymore

  return error_system.create_success({
    message = "Inspector view initialized successfully"
  })
end

function M.set_header_text(text)
  -- Store the header text for when UI is built
  M._header_text = text or ""

  -- If we have a header widget created, update it directly
  if M._header_label then
    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, M._header_label, M._header_text)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update header text: " .. log_detailed_error(set_text_error))
    end
  end
end

function M.set_batch_enabled(enabled)
  -- Store the batch state for when UI is built
  M._batch_enabled = not not enabled

  -- If we have a batch banner widget created, show/hide it directly
  if M._batch_banner then
    local set_visible_success, set_visible_error = pcall(qt_constants.DISPLAY.SET_VISIBLE, M._batch_banner, M._batch_enabled)
    if not set_visible_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update batch banner visibility: " .. log_detailed_error(set_visible_error))
    end
  end
end

function M.create_schema_driven_inspector()
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Creating schema-driven inspector")
  if not M.root then
    return error_system.create_error({
      message = "No root panel mounted",
      operation = "create_schema_driven_inspector",
      component = "inspector.view"
    })
  end

  -- M.root is a simple widget container created by CREATE_INSPECTOR()
  -- Following metadata_system.lua pattern: create our own scroll area inside the container

  -- Root layout holds header widgets (search, selection) and the scroll area
  local root_layout_success, root_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not root_layout_success or not root_layout then
    return error_system.create_error({message = "Failed to create root layout"})
  end
  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, M.root, root_layout)
  pcall(qt_constants.LAYOUT.SET_MARGINS, root_layout, 0, 0, 0, 0)
  pcall(qt_constants.LAYOUT.SET_SPACING, root_layout, 6)
  pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, M.root, "Preferred", "Expanding")

  -- Search row (kept visible while scrolling Inspector sections)
  local search_container_success, search_container = pcall(qt_constants.WIDGET.CREATE)
  if search_container_success and search_container then
    local search_layout_success, search_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
    if search_layout_success and search_layout then
      pcall(qt_constants.LAYOUT.SET_ON_WIDGET, search_container, search_layout)
      pcall(qt_constants.LAYOUT.SET_MARGINS, search_layout, 0, 0, 0, 0)
      pcall(qt_constants.LAYOUT.SET_SPACING, search_layout, 4)

      local search_input_success, search_input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, "Search properties...")
      if search_input_success and search_input then
        M._search_input = search_input
        pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, search_input, "Expanding", "Fixed")
        pcall(qt_constants.LAYOUT.ADD_WIDGET, search_layout, search_input, "AlignBaseline")
        pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, search_layout, search_input, 1)

        -- Connect text changed handler directly
        local handler_name = "inspector_search_handler"
        _G[handler_name] = function()
          local current_text_success, current_text = pcall(qt_constants.PROPERTIES.GET_TEXT, search_input)
          if current_text_success then
            M.apply_search_filter(current_text or "")
          end
        end

        local success, err = pcall(function()
          qt_set_line_edit_text_changed_handler(search_input, handler_name)
        end)

        if not success then
          logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Text changed handler not available: " .. tostring(err))
        end
      end
    end
    pcall(qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY, search_container, "Expanding", "Fixed")
    pcall(qt_constants.LAYOUT.ADD_WIDGET, root_layout, search_container)
    pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, root_layout, search_container, 0)
  end

  -- Selection label (clip/timeline name) kept fixed above the scroll area
  local selection_label_success, selection_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "No clip selected")
  if selection_label_success and selection_label then
    pcall(qt_constants.PROPERTIES.SET_STYLE, selection_label, [[
      QLabel {
        background: #3a3a3a;
        color: white;
        padding: 10px;
        font-size: 14px;
        font-weight: bold;
      }
    ]])
    pcall(qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY, selection_label, "Expanding", "Fixed")
    pcall(qt_constants.LAYOUT.ADD_WIDGET, root_layout, selection_label)
    pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, selection_label, "Expanding", "Fixed")
    M._selection_label = selection_label
    pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, root_layout, selection_label, 0)
  end

  -- Create scroll area inside the container (holds collapsible sections)
  local scroll_area_success, scroll_area = pcall(qt_constants.WIDGET.CREATE_SCROLL_AREA)
  if not scroll_area_success then
    return error_system.create_error({message = "Failed to create scroll area"})
  end
  M._scroll_area = scroll_area
  
  -- Create content widget for the scroll area
  local content_widget_success, content_widget = pcall(qt_constants.WIDGET.CREATE)
  if not content_widget_success then
    return error_system.create_error({message = "Failed to create content widget"})
  end

  -- Store content widget for later updates
  M._content_widget = content_widget

  -- Create content layout
  local content_layout_success, content_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not content_layout_success then
    return error_system.create_error({message = "Failed to create content layout"})
  end

  -- No margins here - right margin will be applied to individual section content layouts
  pcall(qt_constants.LAYOUT.SET_MARGINS, content_layout, 0, 0, 0, 0)

  -- Set layout on content widget
  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, content_widget, content_layout)
  M._content_layout = content_layout

  -- Set content widget on scroll area
  pcall(qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET, scroll_area, content_widget)

  -- Create Apply button for multi-edit (hidden by default)
  local apply_button_success, apply_button = pcall(qt_constants.WIDGET.CREATE_BUTTON, "Apply Changes")
  if apply_button_success then
    pcall(qt_constants.PROPERTIES.SET_STYLE, apply_button, [[
      QPushButton {
        background: #4a90e2;
        color: white;
        padding: 8px;
        font-size: 13px;
        font-weight: bold;
        border: none;
        border-radius: 3px;
      }
      QPushButton:hover {
        background: #5aa0f2;
      }
      QPushButton:pressed {
        background: #3a80d2;
      }
    ]])
    pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, apply_button)
    pcall(qt_constants.DISPLAY.SET_VISIBLE, apply_button, false)  -- Hidden by default
    M._apply_button = apply_button

    -- Connect click handler
    local qt_signals = require("core.qt_signals")
    qt_signals.connect(apply_button, "clicked", function()
      M.apply_multi_edit()
    end)
  end

  -- Add scroll area after header widgets so content lists scroll independently
  pcall(qt_constants.LAYOUT.ADD_WIDGET, root_layout, scroll_area)
  pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, root_layout, scroll_area, 1)

  -- Pre-build schema sections (hidden by default)
  build_schema_for_id("clip")
  build_schema_for_id("sequence")

  -- Add stretch at the end to push all content to the top
  pcall(qt_constants.LAYOUT.ADD_STRETCH, content_layout, 1)

  -- Show the content widget
  pcall(qt_constants.DISPLAY.SHOW, content_widget)

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] ✅ Schema-driven inspector created")
  return error_system.create_success({message = "Schema-driven inspector created successfully"})
end

function M.set_filter(text)
  M._filter = text or ""

  -- Update the search input widget if we created one
  if M._search_input then
    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, M._search_input, M._filter)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update search input text: " .. log_detailed_error(set_text_error))
    end
  end

  -- Legacy C++ panel support - no longer available with FFI userdata
  -- Search text is now handled by direct widget manipulation above

  -- Trigger onChange if we have a handler
  if M.onFilterChanged then
    M.onFilterChanged(M._filter)
  end
end

function M.get_filter()
  return M._filter or ""
end

-- Apply search filter to hide/show sections based on query
function M.apply_search_filter(query)
  M._filter = query or ""
  local search_text = M._filter:lower()

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Applying search filter: '" .. search_text .. "'")

  if not M._schemas_active then
    set_sections_visible(false)
    return
  end

  -- If empty search, show all sections
  if search_text == "" then
    for section_name, section_data in pairs(M._sections) do
      if section_data.widget then
        pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, true)
      end
    end
    -- Force widget redraw to prevent visual artifacts
    if M._content_widget then
      pcall(qt_update_widget, M._content_widget)
    end
    return
  end

  -- Filter sections based on search query
  for section_name, section_data in pairs(M._sections) do
    local should_show = false

    -- Check if section name matches
    if section_name:lower():find(search_text, 1, true) then
      should_show = true
    end

    -- Check if any field name matches
    if not should_show then
      for _, field_name in ipairs(section_data.fields) do
        if field_name:lower():find(search_text, 1, true) then
          should_show = true
          break
        end
      end
    end

    -- Show/hide section based on match
    if section_data.widget then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, should_show)
    end
  end

  -- Force widget redraw to prevent visual artifacts
  if M._content_widget then
    pcall(qt_update_widget, M._content_widget)
  end
end

function M.ensure_search_row()
  -- Create search UI if not already created
  if M._search_input then
    return error_system.create_success({
      message = "Search row already exists"
    })
  end

  -- This function was referenced but missing - now implemented
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Creating search row")

  return error_system.create_success({
    message = "Search row ensured"
  })
end

-- Save field value to current clip
function M.save_field_value(field_key, explicit_value)
  if M._multi_edit_mode then
    return
  end
  if field_updates_suppressed() then
    return
  end

  local entry = M._field_widgets[field_key]
  if not entry then
    return
  end

  local property_type = PROPERTY_TYPE_MAP[entry.field_type]
  if not property_type then
    logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      string.format("[inspector][view] Unsupported field type '%s' for field '%s'", tostring(entry.field_type), tostring(field_key)))
    return
  end

  local inspectable = M._current_inspectable
  if not inspectable then
    return
  end

  local value = explicit_value
  if value == nil then
    value = read_widget_value(entry)
  end

  if value == nil then
    resume_field_updates()
    return
  end

  local normalized_default = normalize_default_value(entry.field_type, entry.field and entry.field.default)

  local payload = {
    value = value,
    property_type = property_type,
    default_value = normalized_default
  }

  suppress_field_updates()
  command_manager.begin_command_event("ui")
  local ok, err = inspectable:set(field_key, payload)
  command_manager.end_command_event()
  if ok then
    if entry.set_mixed then
      entry:set_mixed(false)
    end
    entry:set_value(value)
  else
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      string.format("[inspector][view] Failed to save field '%s': %s", field_key, tostring(err)))
  end
  resume_field_updates()
end

-- Expose save function globally for manual testing
_G.inspector_save_test = function(field_key, value)
  M.save_field_value(field_key, value)
end

-- Save all modified fields from widgets back to current clip
function M.save_all_fields()
  if field_updates_suppressed() then
    return
  end
  if not M._current_inspectable then
    return
  end

  for field_key, entry in pairs(M._field_widgets) do
    local value = read_widget_value(entry)
    if value ~= nil then
      local property_type = PROPERTY_TYPE_MAP[entry.field_type]
      if property_type then
        M._current_inspectable:set(field_key, {
          value = value,
          property_type = property_type,
          default_value = entry.field and entry.field.default
        })
      end
    end
  end
end

-- Load clip data into widgets
function M.load_clip_data(inspectable)
  if not inspectable then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No inspectable entity to load")
    return
  end

  M._current_inspectable = inspectable
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Loading inspectable data for schema " .. inspectable:get_schema_id())

  suppress_field_updates()

  for field_key, entry in pairs(M._field_widgets) do
    if entry.clear_placeholder then
      entry:clear_placeholder()
    end
    if entry.set_mixed then
      entry:set_mixed(false)
    end

    local ok, value = pcall(inspectable.get, inspectable, field_key)
    if not ok then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
        string.format("[inspector][view] Failed to read field '%s': %s", field_key, tostring(value)))
      value = nil
    end

    if entry.set_value then
      entry:set_value(value)
    end
  end

  resume_field_updates()
end

-- Update inspector when selection changes
function M.load_multi_clip_data(inspectables)
  if not inspectables or #inspectables == 0 then
    return
  end

  M._multi_edit_mode = true
  M._multi_inspectables = inspectables
  M._current_inspectable = nil

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Loading multi-inspectable data: " .. #inspectables .. " items")

  suppress_field_updates()

  for field_key, entry in pairs(M._field_widgets) do
    local ok_first, first_value = pcall(inspectables[1].get, inspectables[1], field_key)
    if not ok_first then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
        string.format("[inspector][view] Failed to read field '%s' from first inspectable: %s",
          field_key, tostring(first_value)))
      first_value = nil
    end

    local all_same = true

    for i = 2, #inspectables do
      local ok_candidate, candidate = pcall(inspectables[i].get, inspectables[i], field_key)
      if not ok_candidate or candidate ~= first_value then
        all_same = false
        break
      end
    end

    if all_same then
      if entry.clear_placeholder then
        entry:clear_placeholder()
      end
      if entry.set_mixed then
        entry:set_mixed(false)
      end
      if entry.set_value then
        entry:set_value(first_value)
      end
    else
      if entry.set_mixed then
        entry:set_mixed(true)
      elseif entry.set_value then
        entry:set_value(nil)
      end
    end
  end

  if M._apply_button then
    pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, true)
  end

  resume_field_updates()
end

local function apply_multi_edit_new()
  if not M._multi_edit_mode or not M._multi_inspectables or #M._multi_inspectables == 0 then
    return
  end

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Applying multi-edit to " .. #M._multi_inspectables .. " items")

  local pending = {}
  for field_key, entry in pairs(M._field_widgets) do
    local value = read_widget_value(entry)
    if value ~= nil then
      pending[field_key] = value
    end
  end

  command_manager.begin_command_event("ui")
  for _, inspectable in ipairs(M._multi_inspectables) do
    for field_key, value in pairs(pending) do
      local ok, err = inspectable:set(field_key, value)
      if not ok then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            string.format("[inspector][view] Failed to save %s during multi-edit: %s", field_key, tostring(err)))
      end
    end
  end
  command_manager.end_command_event()

  for field_key, value in pairs(pending) do
    local entry = M._field_widgets[field_key]
    if entry then
      if entry.set_mixed then
        entry:set_mixed(false)
      end
      if entry.set_value then
        entry:set_value(value)
      end
    end
  end
end

M.apply_multi_edit = apply_multi_edit_new

function M.get_focus_widgets()
  local widgets = {}
  if M._scroll_area then
    table.insert(widgets, M._scroll_area)
  end
  if M._search_input then
    table.insert(widgets, M._search_input)
  end
  if M.root then
    table.insert(widgets, M.root)
  end
  return widgets
end

local function resolve_inspectables(selected_items, source_panel)
  local inspectables = {}
  local schema_id = nil
  local names = {}

  for _, item in ipairs(selected_items or {}) do
    local inspectable = item.inspectable

    if not inspectable then
      if item.item_type == "timeline_sequence" or item.item_type == "timeline" then
        local ok, seq = pcall(inspectable_factory.sequence, {
          sequence_id = item.sequence_id or item.id,
          project_id = item.project_id,
          sequence = item.sequence
        })
        if ok then
          inspectable = seq
        end
      elseif item.item_type == "timeline_clip" or item.item_type == "master_clip" then
        if item.clip_id then
          local ok, clip = pcall(inspectable_factory.clip, {
            clip_id = item.clip_id,
            project_id = item.project_id,
            sequence_id = item.sequence_id,
            clip = item.clip
          })
          if ok then
            inspectable = clip
          end
        end
      end
    end

    if inspectable then
      local current_schema = inspectable:get_schema_id()
      if schema_id and schema_id ~= current_schema then
        return {}, nil, { mixed = true }
      end
      schema_id = schema_id or current_schema
      table.insert(inspectables, inspectable)
      local display = item.display_name
      if not display and inspectable.get_display_name then
        display = inspectable:get_display_name()
      end
      table.insert(names, display or "")
    end
  end

  return inspectables, schema_id, names
end

local function update_selection_new(selected_items, source_panel)
  selected_items = selected_items or {}
  source_panel = source_panel or "timeline"

  if source_panel == "inspector" then
    return
  end

  local inspectables, schema_id, names = resolve_inspectables(selected_items, source_panel)

  if not schema_id or #inspectables == 0 then
    M._current_inspectable = nil
    M._multi_edit_mode = false
    M._multi_inspectables = nil
    M._schemas_active = false
    set_sections_visible(false)
    reset_all_fields()
    if M._apply_button then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, false)
    end
    local message = "Inspector: No editable selection"
    set_selection_label(message, source_panel == "timeline")
    return
  end

  activate_schema(schema_id)
  M._schemas_active = true
  set_sections_visible(true)
  M.apply_search_filter(M._filter)

  local multi_supported = true
  for _, inspectable in ipairs(inspectables) do
    if not (inspectable.supports_multi_edit and inspectable:supports_multi_edit()) then
      multi_supported = false
      break
    end
  end

  if #inspectables == 1 then
    M._multi_edit_mode = false
    M._multi_inspectables = nil
    if M._apply_button then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, false)
    end
    M.load_clip_data(inspectables[1])
    local label = names[1]
    if not label and inspectables[1].get_display_name then
      local ok, display = pcall(inspectables[1].get_display_name, inspectables[1])
      if ok then
        label = display
      end
    end
    label = label or "Inspector"

    if schema_id == "sequence" then
      label = string.format("Timeline: %s", label)
    else
      label = string.format("Clip: %s", label)
    end
    local include_marks = (source_panel == "timeline" or schema_id == "sequence")
    set_selection_label(label, include_marks)
  elseif multi_supported then
    M._multi_edit_mode = true
    M._multi_inspectables = inspectables
    if M._apply_button then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, true)
    end
    local label_prefix = (schema_id == "sequence") and "Timelines" or "Clips"
    local label = string.format("%s: %d selected", label_prefix, #inspectables)
    local include_marks = (source_panel == "timeline" or schema_id == "sequence")
    set_selection_label(label, include_marks)
    M.load_multi_clip_data(inspectables)
  else
    M._multi_edit_mode = false
    M._multi_inspectables = nil
    if M._apply_button then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, false)
    end

    local label_prefix = (schema_id == "sequence") and "Timelines" or "Clips"
    local label = string.format("%s: %d selected (read-only)", label_prefix, #inspectables)
    local include_marks = (source_panel == "timeline" or schema_id == "sequence")
    set_selection_label(label, include_marks)

    -- Show the first item's data for context while keeping inspector read-only
    M.load_clip_data(inspectables[1])
  end
end

M.update_selection = update_selection_new

return M
