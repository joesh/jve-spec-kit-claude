-- 012 Inspector Widget State — read-only properties, placeholder, commit
--   classification, scroll-area focus policy.
--
-- REPLACES (stub-heavy synthetic/lua/ tests):
--   test_inspector_commit_classification.lua
--   test_inspector_read_only_widget_state.lua
--   test_inspector_scroll_area_no_focus.lua
--   test_inspector_set_value_clears_placeholder.lua
--
-- DOMAIN RULES PINNED:
--   DR-CLASSIFY     Empty-input for a TIMECODE field is classified as "revert"
--                   (not "commit") so it can't trigger the TIMECODE assert that
--                   fires on nil. Parse error → "error". Valid value → "commit".
--                   (spec edge case: "Field commit while focused field is empty
--                   is treated as 'no change'")
--   DR-RO-BOOL      A read_only BOOLEAN field widget is disabled (click rejected
--                   at Qt level) AND has NoFocus policy (Tab skips it). (FR-010a)
--   DR-RO-STRING    A read_only STRING field widget has NoFocus (Tab skips) but
--                   is NOT disabled — preserves the readable text look. (FR-010a)
--   DR-EDITABLE     Editable field widgets are neither disabled nor set to NoFocus.
--   DR-MIXED-CLEAR  Entry:set_value after Entry:set_mixed(true) clears the
--                   <mixed> placeholder. set_value(nil) also clears it. (FR-014)
--   DR-SCROLL-NOFOCUS  The Inspector's QScrollArea has NoFocus policy on mount
--                      so it does not appear in the Tab chain between the search
--                      input and the first field.
--
-- DROPPED scenarios (implementation details, not domain behavior):
--   * Exact internal field checks for TIMECODE read_only — same rule as STRING.
--   * Qt widget-creation failure paths — testing Qt itself, not JVE domain logic.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/integration/inspector/test_012_inspector_widget_state.lua

local qt_constants = require("core.qt_constants")
require("test_env")

print("=== test_012_inspector_widget_state.lua ===")

-- ── DR-CLASSIFY ────────────────────────────────────────────────────────────
print("-- DR-CLASSIFY: _classify_commit classification for empty/error/valid input --")
do
    -- Load field_widget directly — no DB, no selection state needed; the
    -- classify function is pure and has no Qt side effects at call time.
    local field_widget = require("ui.inspector.field_widget")
    assert(type(field_widget._classify_commit) == "function",
        "DR-CLASSIFY: field_widget._classify_commit must be exposed")

    -- Valid typed value → commit.
    assert(field_widget._classify_commit(42, nil) == "commit",
        "DR-CLASSIFY: valid integer must classify as 'commit'")
    assert(field_widget._classify_commit("abc", nil) == "commit",
        "DR-CLASSIFY: valid string must classify as 'commit'")
    assert(field_widget._classify_commit(240, nil) == "commit",
        "DR-CLASSIFY: valid TIMECODE frame count must classify as 'commit'")

    -- Empty input (both value and error are nil) → revert.
    -- This is the exact crash-prevention path: the editingFinished handler blurs
    -- an empty TIMECODE field → parse returns (nil,nil) → must NOT reach
    -- on_commit with nil, which would assert in the TIMECODE writer.
    assert(field_widget._classify_commit(nil, nil) == "revert", string.format(
        "DR-CLASSIFY: nil value + nil error must classify as 'revert'; got %q",
        tostring(field_widget._classify_commit(nil, nil))))

    -- Parse error → "error" (keep bad text with error border).
    assert(field_widget._classify_commit(nil, "not a number") == "error",
        "DR-CLASSIFY: parse error must classify as 'error'")
    assert(field_widget._classify_commit(nil, "invalid timecode") == "error",
        "DR-CLASSIFY: timecode parse failure must classify as 'error'")

    -- Crucially: nil value must NEVER be "commit" regardless of error arg.
    for _, err_val in ipairs({ nil, false }) do
        local got = field_widget._classify_commit(nil, err_val)
        assert(got ~= "commit", string.format(
            "DR-CLASSIFY: nil value must never classify as 'commit' (err=%s); got %q — "
            .. "this would recreate the mark_in TIMECODE crash",
            tostring(err_val), tostring(got)))
    end
    print("  PASS DR-CLASSIFY")
end

-- ── Helpers for field_widget tests ─────────────────────────────────────────

-- Intercept qt_set_focus_policy calls so we can observe what policy was set
-- on which widget, without reading it back (no GET_FOCUS_POLICY binding).
local focus_policies = {}
local orig_qt_set_focus_policy = qt_set_focus_policy  -- luacheck: globals qt_set_focus_policy
local function track_focus_policy(w, p) focus_policies[w] = p end
-- Pass-through instrumentation: call real binding AND record.
qt_set_focus_policy = function(w, p)                  -- luacheck: globals qt_set_focus_policy
    track_focus_policy(w, p)
    if orig_qt_set_focus_policy then
        orig_qt_set_focus_policy(w, p)
    end
end

-- Intercept SET_ENABLED on CONTROL to observe enable state.
local enabled_state = {}
local orig_set_enabled = qt_constants.CONTROL.SET_ENABLED
qt_constants.CONTROL.SET_ENABLED = function(w, v)
    enabled_state[w] = v
    orig_set_enabled(w, v)
end

local function clear_observations()
    for k in pairs(focus_policies) do focus_policies[k] = nil end
    for k in pairs(enabled_state) do enabled_state[k] = nil end
end

local metadata_schemas = require("ui.metadata_schemas")
local field_widget = require("ui.inspector.field_widget")

-- Dummy sequence provider (TIMECODE fields need it; others ignore it).
local function seq_provider()
    return { frame_rate = { fps_numerator = 25, fps_denominator = 1 }, start_timecode_frame = 0 }
end

local callbacks = { sequence = seq_provider, on_commit = function() end }

-- ── DR-RO-BOOL ─────────────────────────────────────────────────────────────
print("-- DR-RO-BOOL: read_only BOOLEAN → disabled + NoFocus --")
do
    clear_observations()
    local entry = field_widget.create_field({}, {
        key = "offline", label = "Offline",
        type = metadata_schemas.FIELD_TYPES.BOOLEAN, read_only = true,
    }, callbacks)
    assert(entry and entry.widget, "DR-RO-BOOL: create_field must return entry with widget")
    assert(enabled_state[entry.widget] == false, string.format(
        "DR-RO-BOOL: read_only BOOLEAN widget must be setEnabled(false); got %s",
        tostring(enabled_state[entry.widget])))
    assert(focus_policies[entry.widget] == "NoFocus", string.format(
        "DR-RO-BOOL: read_only BOOLEAN widget must have NoFocus policy; got %q",
        tostring(focus_policies[entry.widget])))
    print("  PASS DR-RO-BOOL")
end

-- ── DR-RO-STRING ───────────────────────────────────────────────────────────
print("-- DR-RO-STRING: read_only STRING → NoFocus but NOT disabled --")
do
    clear_observations()
    local entry = field_widget.create_field({}, {
        key = "media_id", label = "Media ID",
        type = metadata_schemas.FIELD_TYPES.STRING, read_only = true,
    }, callbacks)
    assert(entry and entry.widget, "DR-RO-STRING: create_field must return entry with widget")
    assert(focus_policies[entry.widget] == "NoFocus", string.format(
        "DR-RO-STRING: read_only STRING widget must have NoFocus policy; got %q",
        tostring(focus_policies[entry.widget])))
    -- NOT disabled — preserves readable text styling (grey disabled look is wrong for NLE).
    assert(enabled_state[entry.widget] ~= false, string.format(
        "DR-RO-STRING: read_only STRING widget must NOT be setEnabled(false); got %s",
        tostring(enabled_state[entry.widget])))
    print("  PASS DR-RO-STRING")
end

-- ── DR-EDITABLE ────────────────────────────────────────────────────────────
print("-- DR-EDITABLE: editable fields are neither disabled nor NoFocus --")
do
    for _, ft_name in ipairs({ "STRING", "BOOLEAN" }) do
        clear_observations()
        local ft = metadata_schemas.FIELD_TYPES[ft_name]
        assert(ft, "DR-EDITABLE: unknown field type " .. ft_name)
        local entry = field_widget.create_field({}, {
            key = "editable_field_" .. ft_name, label = "Editable",
            type = ft,  -- no read_only flag → defaults false
        }, callbacks)
        assert(entry and entry.widget,
            "DR-EDITABLE: create_field must return entry with widget for " .. ft_name)
        assert(enabled_state[entry.widget] ~= false, string.format(
            "DR-EDITABLE %s: editable widget must not be setEnabled(false); got %s",
            ft_name, tostring(enabled_state[entry.widget])))
        assert(focus_policies[entry.widget] ~= "NoFocus", string.format(
            "DR-EDITABLE %s: editable widget must not have NoFocus; got %q",
            ft_name, tostring(focus_policies[entry.widget])))
    end
    print("  PASS DR-EDITABLE")
end

-- Restore instrumented functions.
qt_set_focus_policy = orig_qt_set_focus_policy  -- luacheck: globals qt_set_focus_policy
qt_constants.CONTROL.SET_ENABLED = orig_set_enabled

-- ── DR-MIXED-CLEAR ─────────────────────────────────────────────────────────
print("-- DR-MIXED-CLEAR: set_value clears <mixed> placeholder (FR-014) --")
do
    -- Intercept SET_PLACEHOLDER_TEXT to observe calls.
    local last_placeholder
    local orig_spt = qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT
    qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT = function(w, v)
        last_placeholder = v
        orig_spt(w, v)
    end

    local entry = field_widget.create_field({}, {
        key = "name", label = "Name",
        type = metadata_schemas.FIELD_TYPES.STRING,
    }, callbacks)
    assert(entry and entry.widget, "DR-MIXED-CLEAR: create_field must return entry with widget")

    -- 1. set_mixed(true) must write the <mixed> placeholder.
    entry:set_mixed(true)
    assert(last_placeholder == "<mixed>", string.format(
        "DR-MIXED-CLEAR: set_mixed(true) must write <mixed> placeholder; got %q",
        tostring(last_placeholder)))

    -- 2. set_value(nil) must clear the placeholder (and not leave <mixed> visible).
    last_placeholder = nil
    entry:set_value(nil)
    assert(last_placeholder == "" or last_placeholder == nil, string.format(
        "DR-MIXED-CLEAR: set_value(nil) must clear placeholder; got %q",
        tostring(last_placeholder)))

    -- 3. set_mixed(true) again, then set_value with a real value.
    entry:set_mixed(true)
    assert(last_placeholder == "<mixed>", "DR-MIXED-CLEAR: precondition: set_mixed again")
    last_placeholder = nil
    entry:set_value("NewName")
    assert(last_placeholder == "" or last_placeholder == nil, string.format(
        "DR-MIXED-CLEAR: set_value(value) must clear placeholder; got %q",
        tostring(last_placeholder)))
    assert(entry.mixed == false,
        "DR-MIXED-CLEAR: set_value must clear the mixed flag on the entry")

    -- 4. TIMECODE field: same placeholder-clear behavior.
    local tc_entry = field_widget.create_field({}, {
        key = "mark_in_frame", label = "Mark In",
        type = metadata_schemas.FIELD_TYPES.TIMECODE,
    }, callbacks)
    tc_entry:set_mixed(true)
    assert(last_placeholder == "<mixed>", "DR-MIXED-CLEAR: TIMECODE set_mixed(true) must set placeholder")
    last_placeholder = nil
    tc_entry:set_value(nil)
    assert(last_placeholder == "" or last_placeholder == nil, string.format(
        "DR-MIXED-CLEAR: TIMECODE set_value(nil) must clear <mixed> placeholder; got %q",
        tostring(last_placeholder)))

    qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT = orig_spt
    print("  PASS DR-MIXED-CLEAR")
end

-- ── DR-SCROLL-NOFOCUS ──────────────────────────────────────────────────────
print("-- DR-SCROLL-NOFOCUS: Inspector scroll area has NoFocus policy on mount --")
do
    -- Pass-through instrumentation: record focus policy per widget.
    local scroll_policies = {}
    local orig_fp = qt_set_focus_policy  -- luacheck: globals qt_set_focus_policy
    qt_set_focus_policy = function(w, p)  -- luacheck: globals qt_set_focus_policy
        scroll_policies[w] = p
        if orig_fp then orig_fp(w, p) end
    end

    local container = qt_constants.WIDGET.CREATE()
    assert(container, "DR-SCROLL-NOFOCUS: could not create container widget")

    -- Force a fresh mount to observe the scroll area creation.
    package.loaded["ui.inspector.mount"] = nil
    package.loaded["ui.inspector"] = nil
    local inspector = require("ui.inspector")
    inspector.mount(container)

    qt_set_focus_policy = orig_fp  -- luacheck: globals qt_set_focus_policy

    -- At least one widget must have been set to NoFocus. The mount
    -- creates the scroll area and immediately calls qt_set_focus_policy(sa, "NoFocus").
    local found_nofocus = false
    for _, p in pairs(scroll_policies) do
        if p == "NoFocus" then found_nofocus = true; break end
    end
    assert(found_nofocus,
        "DR-SCROLL-NOFOCUS: Inspector mount must set NoFocus on the scroll area; "
        .. "no widget received NoFocus during mount")
    print("  PASS DR-SCROLL-NOFOCUS")
end

print("\n✅ test_012_inspector_widget_state.lua passed")
