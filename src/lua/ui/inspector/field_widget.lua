-- Inspector field widget factory.
--
-- One call to M.create_field(parent, field_def, callbacks) builds a
-- label + control pair, installs the appropriate signal handlers, and
-- returns an `entry` object carrying the widget and the per-field state
-- (dirty, error, mixed, pending_value, read_only).
--
-- Responsibilities:
--   - Per field type: STRING, TEXT_AREA, DROPDOWN, INTEGER, DOUBLE, BOOLEAN, TIMECODE
--   - read_only rendering (disabled widget + no commit handler)
--   - Parse validation (INTEGER, DOUBLE, TIMECODE) with dirty/error state
--   - All styling via ui_constants; no inline hex
--   - All Qt binding calls bare (no pcall); failures assert
--
-- Non-goals:
--   - Does not know about commands. It calls callbacks.on_commit(entry) and
--     lets the caller decide what to do.
--   - Does not know about selection state or multi-edit.

local ui_constants   = require("core.ui_constants")
local qt_constants   = require("core.qt_constants")
local qt_signals     = require("core.qt_signals")
local frame_utils    = require("core.frame_utils")
local timecode_input = require("core.timecode_input")
local runtime_mode   = require("core.runtime_mode")
local metadata_schemas = require("ui.metadata_schemas")

local M = {}

local FT = metadata_schemas.FIELD_TYPES
local C  = ui_constants.COLORS
local F  = ui_constants.FONTS

-- ----------------------------------------------------------------------
-- Parse helpers (pure functions; also used by unit tests)
-- ----------------------------------------------------------------------

--- Parse a widget's typed text into its typed value. Returns (value, nil)
--- on success, (nil, err) on parse failure. Empty string is treated as
--- "no change" for non-string fields and returns (nil, nil) — the caller
--- decides whether to clear, skip, or reject.
local function parse_text(field_type, text, frame_rate_provider)
    if field_type == FT.STRING or field_type == FT.TEXT_AREA or field_type == FT.DROPDOWN then
        return text, nil
    end
    if text == nil or text == "" then
        return nil, nil
    end
    if field_type == FT.INTEGER then
        local n = tonumber(text)
        if not n or n ~= math.floor(n) then
            return nil, "not an integer"
        end
        return n, nil
    end
    if field_type == FT.DOUBLE then
        local n = tonumber(text)
        if not n then return nil, "not a number" end
        return n, nil
    end
    if field_type == FT.TIMECODE then
        local rate = frame_rate_provider()
        assert(rate, "field_widget.parse_text: TIMECODE requires a frame rate provider")
        -- Lenient parser: accepts "01:02:03:04" (full), "1:23" (right-
        -- aligned = 1s:23f @ fps), "1234" (bare digits = right-aligned), and
        -- relative entries "+10" / "-2s" / "+1:00". Matches the shorthand
        -- the timeline's timecode entry widget uses, so Inspector behaves
        -- the same way.
        local v, err = timecode_input.parse(text, rate)
        if not v then return nil, err or "invalid timecode" end
        -- Extract integer frames — CLAUDE.md "all coords are integers".
        if type(v) == "table" and v.frames then
            return v.frames, nil
        elseif type(v) == "number" then
            return v, nil
        else
            return nil, "timecode_input.parse returned unexpected type " .. type(v)
        end
    end
    error("field_widget.parse_text: unknown field_type " .. tostring(field_type))
end
M._parse_text = parse_text  -- exposed for unit tests

--- Classify a commit attempt based on parse result. Pure function — unit tested.
--   "error"  → parse failure; keep bad text visible with error border. No write.
--   "revert" → empty input (v=nil, err=nil); treat as "no change" per spec edge
--              case. No write; revert widget to model value.
--   "commit" → valid typed value; dispatch to on_commit.
-- This exists as a named function (not inline in the editingFinished handler)
-- specifically so there's a unit test for the nil-value case — which was the
-- site of a TIMECODE assert crash when a user blurred an empty mark_in field.
local function classify_commit(parsed_value, parse_error)
    if parse_error then return "error" end
    if parsed_value == nil then return "revert" end
    return "commit"
end
M._classify_commit = classify_commit

local function format_value(field_type, value, frame_rate_provider)
    if value == nil then return "" end
    if field_type == FT.TIMECODE then
        local rate = frame_rate_provider()
        assert(rate, "field_widget.format_value: TIMECODE requires a frame rate provider")
        return frame_utils.format_timecode(value, rate)
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    return tostring(value)
end
M._format_value = format_value  -- exposed for unit tests

-- ----------------------------------------------------------------------
-- Styling
-- ----------------------------------------------------------------------

local function line_edit_style(read_only, error_state)
    local bg = read_only and C.READONLY_BACKGROUND_COLOR or C.FIELD_BACKGROUND_COLOR
    local fg = read_only and C.FIELD_READ_ONLY_TEXT     or C.FIELD_TEXT_COLOR
    local border = error_state and C.FIELD_ERROR_BORDER or C.FIELD_BORDER_COLOR
    return string.format([[
        QLineEdit {
            background: %s;
            color: %s;
            border: 1px solid %s;
            border-radius: 3px;
            padding: 2px 6px;
            font-size: %s;
        }
        QLineEdit:focus {
            border: 1px solid %s;
            background: %s;
        }
    ]], bg, fg, border, F.DEFAULT_FONT_SIZE, C.FOCUS_BORDER_COLOR, C.FIELD_FOCUS_BACKGROUND_COLOR)
end

local function label_style()
    return string.format([[
        QLabel {
            color: %s;
            font-size: %s;
            padding: 4px 6px 2px 4px;
            min-width: 120px;
        }
    ]], C.LABEL_TEXT_COLOR, F.DEFAULT_FONT_SIZE)
end

-- ----------------------------------------------------------------------
-- Widget creation per field type
-- ----------------------------------------------------------------------

local function create_line_edit_control(read_only)
    local widget = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    assert(widget, "field_widget: CREATE_LINE_EDIT returned nil")
    qt_constants.PROPERTIES.SET_STYLE(widget, line_edit_style(read_only, false))
    -- Explicitly set read-only state either way so tests / audits can verify.
    qt_constants.CONTROL.SET_LINE_EDIT_READ_ONLY(widget, read_only and true or false)
    return widget
end

local function create_text_area_control(read_only)
    local widget = create_line_edit_control(read_only)
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(widget, 60)
    return widget
end

local function create_checkbox_control(default_checked)
    local widget = qt_constants.WIDGET.CREATE_CHECKBOX("")
    assert(widget, "field_widget: CREATE_CHECKBOX returned nil")
    if default_checked ~= nil then
        qt_constants.PROPERTIES.SET_CHECKED(widget, default_checked and true or false)
    end
    return widget
end

local function create_combobox_control(options)
    local widget = qt_constants.WIDGET.CREATE_COMBOBOX()
    assert(widget, "field_widget: CREATE_COMBOBOX returned nil")
    for _, opt in ipairs(options) do
        qt_constants.PROPERTIES.ADD_COMBOBOX_ITEM(widget, opt)
    end
    return widget
end

local function create_control(field_def)
    local ft = field_def.type
    if ft == FT.STRING or ft == FT.INTEGER or ft == FT.DOUBLE or ft == FT.TIMECODE then
        return create_line_edit_control(field_def.read_only), "line_edit"
    elseif ft == FT.TEXT_AREA then
        return create_text_area_control(field_def.read_only), "text_area"
    elseif ft == FT.BOOLEAN then
        return create_checkbox_control(field_def.default), "checkbox"
    elseif ft == FT.DROPDOWN then
        return create_combobox_control(field_def.options), "combobox"
    else
        error("field_widget.create_control: unknown field type " .. tostring(ft))
    end
end

-- ----------------------------------------------------------------------
-- Entry object — the per-field state holder returned to callers
-- ----------------------------------------------------------------------

local Entry = {}
Entry.__index = Entry

function Entry:set_value(value)
    self._programmatic = true
    self._last_model_value = value
    self.dirty = false
    self.error = false
    self.mixed = false
    self.pending_value = nil
    -- Clear the "<mixed>" placeholder left by a prior multi-edit load so
    -- nil-valued fields in single-edit mode don't keep showing "<mixed>"
    -- through the placeholder slot.
    if self.widget_type == "line_edit" or self.widget_type == "text_area" then
        qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(self.widget, "")
    end
    self:_write_widget(value)
    self:_restyle()
    self._programmatic = false
end

function Entry:get_value()
    if self.widget_type == "checkbox" then
        local checked = qt_constants.PROPERTIES.GET_CHECKED(self.widget)
        return checked and true or false
    elseif self.widget_type == "combobox" then
        return qt_constants.PROPERTIES.GET_TEXT(self.widget)
    else
        local text = qt_constants.PROPERTIES.GET_TEXT(self.widget) or ""
        local v, _ = parse_text(self.field_type, text, self._rate_provider)
        return v
    end
end

function Entry:set_mixed(flag)
    self.mixed = flag and true or false
    if self.widget_type == "line_edit" or self.widget_type == "text_area" then
        if self.mixed then
            qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(self.widget, "<mixed>")
            self._programmatic = true
            qt_constants.PROPERTIES.SET_TEXT(self.widget, "")
            self._programmatic = false
        else
            qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(self.widget, "")
        end
    elseif self.widget_type == "checkbox" and self.mixed then
        -- Tri-state visual deferred (Q5 cosmetic) — fall back to unchecked.
        self._programmatic = true
        qt_constants.PROPERTIES.SET_CHECKED(self.widget, false)
        self._programmatic = false
    end
end

function Entry:set_error(flag)
    self.error = flag and true or false
    self:_restyle()
end

function Entry:clear_dirty()
    self.dirty = false
    self.pending_value = nil
end

function Entry:_write_widget(value)
    if self.widget_type == "checkbox" then
        qt_constants.PROPERTIES.SET_CHECKED(self.widget, value and true or false)
    elseif self.widget_type == "combobox" then
        if value ~= nil then
            qt_constants.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(self.widget, tostring(value))
        end
    else
        qt_constants.PROPERTIES.SET_TEXT(self.widget, format_value(self.field_type, value, self._rate_provider))
    end
end

function Entry:_restyle()
    if self.widget_type == "line_edit" or self.widget_type == "text_area" then
        qt_constants.PROPERTIES.SET_STYLE(self.widget, line_edit_style(self.read_only, self.error))
    end
end

-- ----------------------------------------------------------------------
-- Signal handlers
-- ----------------------------------------------------------------------

local function install_line_edit_handlers(entry, callbacks)
    local text_conn = qt_signals.onTextChanged(entry.widget, function()
        if entry._programmatic then return end
        entry.dirty = true
        local text = qt_constants.PROPERTIES.GET_TEXT(entry.widget) or ""
        local v, err = parse_text(entry.field_type, text, entry._rate_provider)
        if err then
            entry.pending_value = nil
            -- Surface the error even before commit so the UI banner can
            -- update as the user types. Don't touch border until commit —
            -- typing in progress may resolve to valid input.
            if callbacks.on_error then
                callbacks.on_error(entry, err)
            end
        else
            entry.pending_value = v
            if entry.error then
                entry.error = false
                entry:_restyle()
            end
            if callbacks.on_error then
                callbacks.on_error(entry, nil)  -- clear any previous error
            end
        end
    end)
    assert(text_conn, string.format(
        "field_widget: failed to connect textChanged for %q", entry.field_key))

    local commit_conn = qt_signals.connect(entry.widget, "editingFinished", function()
        if entry._programmatic then return end
        if not entry.dirty then return end
        local text = qt_constants.PROPERTIES.GET_TEXT(entry.widget) or ""
        local v, err = parse_text(entry.field_type, text, entry._rate_provider)
        local action = classify_commit(v, err)
        if action == "error" then
            -- Parse failure: keep the bad text visible with red border; do not
            -- write; do not clear dirty. FR-015a/b — blur_revert on selection
            -- change or explicit revert. Also surface the error message in
            -- the banner (belt-and-suspenders — textChanged typically fires
            -- on_error first, but if a paste inserts invalid text directly
            -- before editingFinished, this is the guaranteed notification).
            entry.pending_value = nil
            entry:set_error(true)
            if callbacks.on_error then
                callbacks.on_error(entry, err)
            end
            return
        elseif action == "revert" then
            -- Empty input. Spec edge case: "empty is treated as no change —
            -- empty string is not written for numeric or timecode fields."
            entry:blur_revert()
            return
        end
        -- action == "commit"
        entry.pending_value = v
        entry:set_error(false)
        callbacks.on_commit(entry, v)
    end)
    assert(commit_conn, string.format(
        "field_widget: failed to connect editingFinished for %q", entry.field_key))

    -- Blur revert-on-error: Qt's editingFinished fires on both Enter and
    -- focus-out. If the widget still has an error after editingFinished (which
    -- happens because the handler above set error=true before returning), the
    -- next focus-out cycle will send editingFinished again with the same bad
    -- text. The revert decision belongs to the caller via a focus-out notice.
    -- A dedicated focusOut signal isn't wired, so we rely on an explicit
    -- entry:blur_revert() that the selection_binding invokes on selection change.
end

local function install_checkbox_handler(entry, callbacks)
    local conn = qt_signals.connect(entry.widget, "clicked", function()
        if entry._programmatic then return end
        entry.dirty = true
        local checked = qt_constants.PROPERTIES.GET_CHECKED(entry.widget)
        entry.pending_value = checked and true or false
        callbacks.on_commit(entry, entry.pending_value)
    end)
    assert(conn, string.format(
        "field_widget: failed to connect clicked for %q", entry.field_key))
end

local function install_combobox_handler(entry, callbacks)
    local conn = qt_signals.connect(entry.widget, "currentIndexChanged", function()
        if entry._programmatic then return end
        entry.dirty = true
        local v = qt_constants.PROPERTIES.GET_TEXT(entry.widget)
        entry.pending_value = v
        callbacks.on_commit(entry, v)
    end)
    if not conn then
        -- Some Qt binding layers use a different signal name; try a fallback.
        conn = qt_signals.connect(entry.widget, "activated", function()
            if entry._programmatic then return end
            entry.dirty = true
            local v = qt_constants.PROPERTIES.GET_TEXT(entry.widget)
            entry.pending_value = v
            callbacks.on_commit(entry, v)
        end)
    end
    assert(conn, string.format(
        "field_widget: failed to connect combobox change for %q", entry.field_key))
end

-- qt_set_focus_handler takes a global function name, so each field
-- needs a distinct slot.
local focus_handler_seq = 0

local function install_field_focus_handler(entry, on_focused)
    assert(entry.row_widget,
        "field_widget.install_field_focus_handler: entry.row_widget required")
    focus_handler_seq = focus_handler_seq + 1
    local handler_name = string.format("inspector_field_focus_%d", focus_handler_seq)
    -- Hand the row widget up so the scroll area can surface the whole
    -- field row (label + control), not just the control.
    _G[handler_name] = function(event)
        assert(event, string.format(
            "field_widget focus handler %q: event is nil", handler_name))
        if event.focus_in then
            on_focused(entry.row_widget)
        end
    end
    qt_set_focus_handler(entry.widget, handler_name)  -- luacheck: globals qt_set_focus_handler
end

function Entry:blur_revert()
    -- Called by selection_binding when selection changes, to discard invalid
    -- in-flight text per FR-015b. Safe to call even if the entry is not dirty.
    if self.error or self.dirty then
        self:set_value(self._last_model_value)
    end
end

-- ----------------------------------------------------------------------
-- Public factory
-- ----------------------------------------------------------------------

--- Create a field widget inside `parent_container`.
--  @param parent_container userdata Qt widget that owns this field row
--  @param field_def        table from metadata_schemas (key, label, type, ...)
--  @param callbacks        table  { on_commit = function(entry, parsed_value),
--                                    frame_rate = function() → rate }
--  @return entry           table  per-field state + methods
function M.create_field(parent_container, field_def, callbacks)
    assert(parent_container, "field_widget.create_field: parent_container required")
    assert(type(field_def) == "table", "field_widget.create_field: field_def required")
    assert(field_def.key and field_def.key ~= "",
        "field_widget.create_field: field_def.key required")
    assert(field_def.label and field_def.label ~= "",
        string.format("field_widget.create_field %q: label required", field_def.key))
    assert(type(callbacks) == "table", "field_widget.create_field: callbacks required")
    assert(type(callbacks.on_commit) == "function",
        "field_widget.create_field: callbacks.on_commit required")
    assert(type(callbacks.frame_rate) == "function",
        "field_widget.create_field: callbacks.frame_rate required")

    -- Build row container: horizontal label + control.
    local row = qt_constants.WIDGET.CREATE()
    assert(row, "field_widget: WIDGET.CREATE returned nil")
    local layout = qt_constants.LAYOUT.CREATE_HBOX()
    assert(layout, "field_widget: CREATE_HBOX returned nil")
    qt_constants.LAYOUT.SET_ON_WIDGET(row, layout)
    qt_constants.LAYOUT.SET_MARGINS(layout,
        ui_constants.LAYOUT.FIELD_MARGIN_LEFT,
        ui_constants.LAYOUT.FIELD_MARGIN_TOP,
        ui_constants.LAYOUT.FIELD_MARGIN_RIGHT,
        ui_constants.LAYOUT.FIELD_MARGIN_BOTTOM)
    qt_constants.LAYOUT.SET_SPACING(layout, ui_constants.LAYOUT.FIELD_SPACING)

    local label = qt_constants.WIDGET.CREATE_LABEL(field_def.label)
    assert(label, "field_widget: CREATE_LABEL returned nil")
    qt_constants.PROPERTIES.SET_STYLE(label, label_style())
    qt_constants.PROPERTIES.SET_ALIGNMENT(label, qt_constants.PROPERTIES.ALIGN_RIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(layout, label)

    local control, widget_type = create_control(field_def)
    qt_constants.LAYOUT.ADD_WIDGET(layout, control)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(layout, control, 1)
    qt_constants.GEOMETRY.SET_SIZE_POLICY(control, "Expanding", "Fixed")

    local entry = setmetatable({
        field_key      = field_def.key,
        field_type     = field_def.type,
        property_type  = metadata_schemas.get_property_type(field_def.type),
        read_only      = field_def.read_only and true or false,
        -- Default true — only explicitly false-marked fields skip
        -- multi-edit Apply (see metadata_schemas.field).
        multi_editable = field_def.multi_editable ~= false,
        widget         = control,
        widget_type    = widget_type,
        row_widget     = row,
        default_value  = field_def.default,
        options        = field_def.options,
        dirty          = false,
        error          = false,
        mixed          = false,
        pending_value  = nil,
        _programmatic  = false,
        _last_model_value = nil,
        _rate_provider = callbacks.frame_rate,
    }, Entry)

    -- Attach row to parent. Supports either a layout or a container with layout.
    if callbacks.attach_row then
        callbacks.attach_row(row)
    end

    if entry.read_only then
        -- Read-only widgets should not accept keyboard focus — Tab/Shift+Tab
        -- must skip them so the user only lands on editable fields. For
        -- BOOLEAN (QCheckBox) we ALSO disable the widget entirely, because
        -- Qt's QCheckBox has no read-only property — setEnabled(false) is
        -- the only way to reject click toggles. For line_edits we keep
        -- the widget enabled (preserves the normal text-readable look; the
        -- widget is already set to setReadOnly(true) at construction).
        -- luacheck: globals qt_set_focus_policy
        if qt_set_focus_policy then
            qt_set_focus_policy(control, "NoFocus")
        end
        if widget_type == "checkbox" then
            qt_constants.CONTROL.SET_ENABLED(control, false)
        end
    else
        if widget_type == "line_edit" or widget_type == "text_area" then
            install_line_edit_handlers(entry, callbacks)
        elseif widget_type == "checkbox" then
            install_checkbox_handler(entry, callbacks)
        elseif widget_type == "combobox" then
            install_combobox_handler(entry, callbacks)
        else
            error("field_widget: unhandled widget_type " .. tostring(widget_type))
        end
        -- Tab-cycling off-screen: parent scrolls focused field into view.
        -- luacheck: globals qt_set_focus_handler
        if callbacks.on_field_focused then
            runtime_mode.assert_production(qt_set_focus_handler,
                "field_widget: qt_set_focus_handler binding missing")
            if qt_set_focus_handler then
                install_field_focus_handler(entry, callbacks.on_field_focused)
            end
        end
    end

    return entry
end

return M
