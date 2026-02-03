require("test_env")

-- ============================================================
-- Qt stubs — provide minimal mock implementations
-- ============================================================
local widget_counter = 0
local function make_widget(kind)
    widget_counter = widget_counter + 1
    return {_kind = kind or "widget", _id = widget_counter}
end

-- Stub qt_constants before requiring collapsible_section
package.loaded["core.qt_constants"] = {
    WIDGET = {
        CREATE = function() return make_widget("widget") end,
        CREATE_LABEL = function(text) return make_widget("label") end,
    },
    LAYOUT = {
        CREATE_VBOX = function() return make_widget("vbox") end,
        CREATE_HBOX = function() return make_widget("hbox") end,
        SET_ON_WIDGET = function() end,
        SET_SPACING = function() end,
        SET_MARGINS = function() end,
        ADD_WIDGET = function() end,
    },
    GEOMETRY = {
        SET_SIZE_POLICY = function() end,
    },
    PROPERTIES = {
        SET_STYLE = function() end,
        SET_TEXT = function() end,
    },
    DISPLAY = {
        SHOW = function() end,
        SET_VISIBLE = function() end,
    },
    CONTROL = {
        SET_WIDGET_CLICK_HANDLER = function() end,
    },
}

-- Stub qt_signals
package.loaded["core.qt_signals"] = {
    connect = function() return 1 end,
    disconnect = function() end,
}

-- Stub ui_constants
package.loaded["core.ui_constants"] = {
    COLORS = {
        LABEL_TEXT_COLOR = "#ffffff",
    },
    FONTS = {
        DEFAULT_FONT_SIZE = "12px",
        HEADER_FONT_SIZE = "13px",
    },
    STYLES = {
        DEBUG_COLORS_ENABLED = false,
    },
    LOGGING = { COMPONENT_NAMES = { UI = "ui" } },
}

-- Stub logger
package.loaded["core.logger"] = {
    init = function() end,
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
}

-- Stub globals that collapsible_section uses
_G.qt_set_widget_attribute = function() end
_G.qt_update_widget = function() end

local error_system = require("core.error_system")
local collapsible_section = require("ui.collapsible_section")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Collapsible Section Tests (T24) ===")

-- ============================================================
-- create_section factory — full creation with Qt stubs
-- ============================================================
print("\n--- create_section ---")
do
    local result = collapsible_section.create_section("Test Section", nil)
    check("factory returns table", type(result) == "table")
    check("factory success", result.success == true)
    check("factory has section", result.section ~= nil)
    check("factory return_values", result.return_values ~= nil)
    check("factory section_widget", result.return_values.section_widget ~= nil)
    check("factory content_layout", result.return_values.content_layout ~= nil)
    check("factory section obj", result.return_values.section ~= nil)
end

-- ============================================================
-- CollapsibleSection.new — state initialization
-- ============================================================
print("\n--- new() state ---")
do
    local result = collapsible_section.create_section("My Section", "parent_widget")
    local section = result.section

    check("title stored", section.title == "My Section")
    check("parent_widget stored", section.parent_widget == "parent_widget")
    check("connections empty", type(section.connections) == "table" and #section.connections == 0)
    check("section_enabled default true", section.section_enabled == true)
    check("bypassed default false", section.bypassed == false)
end

do
    -- nil expanded → defaults to true, but create() calls setExpanded(false)
    local result = collapsible_section.create_section("Collapsed", nil)
    local section = result.section
    check("expanded false after create", section.expanded == false)
end

-- ============================================================
-- setExpanded — toggle logic
-- ============================================================
print("\n--- setExpanded ---")
do
    local result = collapsible_section.create_section("Toggle Test", nil)
    local section = result.section

    -- After create, expanded = false
    check("initial collapsed", section.expanded == false)

    -- Expand
    local expand_result = section:setExpanded(true)
    check("expand success", error_system.is_success(expand_result))
    check("now expanded", section.expanded == true)

    -- Collapse
    local collapse_result = section:setExpanded(false)
    check("collapse success", error_system.is_success(collapse_result))
    check("now collapsed", section.expanded == false)

    -- Same state → no-op success
    local noop_result = section:setExpanded(false)
    check("noop success", error_system.is_success(noop_result))
    check("noop message", noop_result.message:find("already") ~= nil)
end

-- ============================================================
-- addContentWidget — requires content_layout
-- ============================================================
print("\n--- addContentWidget ---")
do
    local result = collapsible_section.create_section("Content Test", nil)
    local section = result.section

    -- Add widget succeeds when content_layout exists
    local add_result = section:addContentWidget(make_widget("child"))
    check("addContentWidget success", error_system.is_success(add_result))

    -- Nil content_layout → error
    local broken_section = result.section
    broken_section.content_layout = nil
    local err_result = broken_section:addContentWidget(make_widget("child2"))
    check("addContentWidget nil layout error", error_system.is_error(err_result))
    check("addContentWidget error code", err_result.code == error_system.CODES.SECTION_NOT_INITIALIZED)
end

-- ============================================================
-- cleanup — clears widget refs and connections
-- ============================================================
print("\n--- cleanup ---")
do
    local result = collapsible_section.create_section("Cleanup Test", nil)
    local section = result.section

    -- Verify widgets exist before cleanup
    check("pre-cleanup main_widget", section.main_widget ~= nil)
    check("pre-cleanup header_widget", section.header_widget ~= nil)
    check("pre-cleanup content_frame", section.content_frame ~= nil)
    check("pre-cleanup content_layout", section.content_layout ~= nil)

    local cleanup_result = section:cleanup()
    check("cleanup success", error_system.is_success(cleanup_result))
    check("post-cleanup main_widget nil", section.main_widget == nil)
    check("post-cleanup header_widget nil", section.header_widget == nil)
    check("post-cleanup enabled_dot nil", section.enabled_dot == nil)
    check("post-cleanup title_label nil", section.title_label == nil)
    check("post-cleanup content_frame nil", section.content_frame == nil)
    check("post-cleanup content_layout nil", section.content_layout == nil)
    check("post-cleanup disclosure_triangle nil", section.disclosure_triangle == nil)
    check("post-cleanup connections empty", #section.connections == 0)
end

-- ============================================================
-- onToggle — delegates to signals.connect
-- ============================================================
print("\n--- onToggle ---")
do
    local handler_fn = function() end
    local connection_id = collapsible_section.onToggle(handler_fn)
    check("onToggle returns connection", connection_id ~= nil)
end

-- ============================================================
-- create_section with title variations
-- ============================================================
print("\n--- title variations ---")
do
    local r1 = collapsible_section.create_section("Camera", nil)
    check("normal title", r1.success == true and r1.section.title == "Camera")

    local r2 = collapsible_section.create_section("Transform Properties", nil)
    check("spaced title", r2.success == true and r2.section.title == "Transform Properties")

    local r3 = collapsible_section.create_section("", nil)
    check("empty title", r3.success == true and r3.section.title == "")
end

-- ============================================================
-- Qt failure paths — widget creation fails
-- ============================================================
print("\n--- Qt failure: main widget ---")
do
    -- Temporarily make WIDGET.CREATE fail
    local orig = package.loaded["core.qt_constants"].WIDGET.CREATE
    package.loaded["core.qt_constants"].WIDGET.CREATE = function() error("Qt crash") end

    local result = collapsible_section.create_section("Fail Test", nil)
    check("create fails on widget error", error_system.is_error(result))
    check("failure code", result.code == error_system.CODES.QT_WIDGET_CREATION_FAILED)

    package.loaded["core.qt_constants"].WIDGET.CREATE = orig
end

print("\n--- Qt failure: layout creation ---")
do
    local orig = package.loaded["core.qt_constants"].LAYOUT.CREATE_VBOX
    package.loaded["core.qt_constants"].LAYOUT.CREATE_VBOX = function() error("layout crash") end

    local result = collapsible_section.create_section("Layout Fail", nil)
    check("create fails on layout error", error_system.is_error(result))

    package.loaded["core.qt_constants"].LAYOUT.CREATE_VBOX = orig
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Collapsible Section: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_collapsible_section.lua passed")
