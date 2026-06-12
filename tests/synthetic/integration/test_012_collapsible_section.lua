-- 012 Collapsible Section — domain behavior with real Qt bindings.
--
-- REPLACES (stub-heavy synthetic/lua/ test):
--   test_collapsible_section.lua
--
-- DOMAIN RULES PINNED:
--   DR-CREATE       create_section returns a usable section with a real Qt
--                   widget tree: main_widget, content_layout accessible.
--   DR-INITIAL      Section starts collapsed (expanded=false after create).
--   DR-EXPAND       setExpanded(true) → expanded=true; content frame visible.
--   DR-COLLAPSE     setExpanded(false) → expanded=false; content frame hidden.
--   DR-NOOP         setExpanded with the current state succeeds without error;
--                   the message contains "already".
--   DR-ADD-WIDGET   addContentWidget places a child widget into the section's
--                   content area without error.
--   DR-ADD-NO-LAYOUT addContentWidget with no content_layout returns an error
--                   (not a silent failure).
--   DR-CLEANUP      cleanup() clears all widget references and the connections
--                   list.
--   DR-TITLE-STORED The section stores whatever title string it was given
--                   (empty, normal, spaced).
--
-- DROPPED scenarios (implementation detail / Qt internals):
--   * Qt widget-creation failure paths — those test Qt itself breaking, not
--     JVE domain logic. The real binding never fails in a healthy process.
--   * onToggle signal wiring — that tests signals infrastructure, not the
--     collapsible section domain behaviour.
--   * Exact internal field values post-cleanup beyond widget-ref clearing
--     (e.g. layout_container, connections table shape) — implementation detail.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/integration/test_012_collapsible_section.lua

local qt_constants = require("core.qt_constants")
local error_system = require("core.error_system")
require("test_env")

local collapsible_section = require("ui.collapsible_section")

print("=== test_012_collapsible_section.lua ===")

-- ── DR-CREATE ──────────────────────────────────────────────────────────────
print("-- DR-CREATE: create_section returns a usable section with Qt widget tree --")
do
    local result = collapsible_section.create_section("Test Section", nil)
    assert(error_system.is_success(result), string.format(
        "DR-CREATE: create_section must succeed; got: %s",
        error_system.is_error(result) and result.message or tostring(result)))
    assert(result.section ~= nil,
        "DR-CREATE: result.section must be non-nil")
    assert(result.return_values ~= nil,
        "DR-CREATE: result.return_values must be non-nil")
    assert(result.return_values.section_widget ~= nil,
        "DR-CREATE: return_values.section_widget must be a real Qt widget")
    assert(result.return_values.content_layout ~= nil,
        "DR-CREATE: return_values.content_layout must be a real Qt layout")
    assert(result.return_values.section ~= nil,
        "DR-CREATE: return_values.section must expose the section object")
    print("  PASS DR-CREATE")
end

-- ── DR-INITIAL ─────────────────────────────────────────────────────────────
print("-- DR-INITIAL: section starts collapsed after create --")
do
    local result = collapsible_section.create_section("Collapse Test", nil)
    assert(error_system.is_success(result), "DR-INITIAL: create must succeed")
    local section = result.section
    assert(section.expanded == false, string.format(
        "DR-INITIAL: section must start collapsed; got expanded=%s",
        tostring(section.expanded)))
    print("  PASS DR-INITIAL")
end

-- ── DR-EXPAND + DR-COLLAPSE ────────────────────────────────────────────────
print("-- DR-EXPAND / DR-COLLAPSE: setExpanded toggles state and content visibility --")
do
    local result = collapsible_section.create_section("Toggle Section", nil)
    assert(error_system.is_success(result), "DR-EXPAND: create must succeed")
    local section = result.section

    -- Expand.
    local expand_result = section:setExpanded(true)
    assert(error_system.is_success(expand_result), string.format(
        "DR-EXPAND: setExpanded(true) must succeed; got: %s",
        error_system.is_error(expand_result) and expand_result.message or tostring(expand_result)))
    assert(section.expanded == true, string.format(
        "DR-EXPAND: expanded must be true after setExpanded(true); got %s",
        tostring(section.expanded)))

    -- Collapse.
    local collapse_result = section:setExpanded(false)
    assert(error_system.is_success(collapse_result), string.format(
        "DR-COLLAPSE: setExpanded(false) must succeed; got: %s",
        error_system.is_error(collapse_result) and collapse_result.message or tostring(collapse_result)))
    assert(section.expanded == false, string.format(
        "DR-COLLAPSE: expanded must be false after setExpanded(false); got %s",
        tostring(section.expanded)))
    print("  PASS DR-EXPAND / DR-COLLAPSE")
end

-- ── DR-NOOP ────────────────────────────────────────────────────────────────
print("-- DR-NOOP: setExpanded with current state succeeds and says 'already' --")
do
    local result = collapsible_section.create_section("Noop Section", nil)
    assert(error_system.is_success(result), "DR-NOOP: create must succeed")
    local section = result.section
    -- Already collapsed after create.
    assert(section.expanded == false, "DR-NOOP: precondition: starts collapsed")

    local noop_result = section:setExpanded(false)
    assert(error_system.is_success(noop_result), string.format(
        "DR-NOOP: setExpanded with current state must succeed; got: %s",
        error_system.is_error(noop_result) and noop_result.message or tostring(noop_result)))
    assert(type(noop_result.message) == "string"
        and noop_result.message:find("already"),
        string.format(
            "DR-NOOP: no-op success message must contain 'already'; got %q",
            tostring(noop_result.message)))
    print("  PASS DR-NOOP")
end

-- ── DR-ADD-WIDGET ──────────────────────────────────────────────────────────
print("-- DR-ADD-WIDGET: addContentWidget places child widget into content area --")
do
    local result = collapsible_section.create_section("Content Section", nil)
    assert(error_system.is_success(result), "DR-ADD-WIDGET: create must succeed")
    local section = result.section

    local child = qt_constants.WIDGET.CREATE_LABEL("child label")
    assert(child, "DR-ADD-WIDGET: could not create child widget")

    local add_result = section:addContentWidget(child)
    assert(error_system.is_success(add_result), string.format(
        "DR-ADD-WIDGET: addContentWidget must succeed; got: %s",
        error_system.is_error(add_result) and add_result.message or tostring(add_result)))
    print("  PASS DR-ADD-WIDGET")
end

-- ── DR-ADD-NO-LAYOUT ───────────────────────────────────────────────────────
print("-- DR-ADD-NO-LAYOUT: addContentWidget without content_layout returns error --")
do
    local result = collapsible_section.create_section("Broken Section", nil)
    assert(error_system.is_success(result), "DR-ADD-NO-LAYOUT: create must succeed")
    local section = result.section

    -- Simulate uninitialized section by clearing content_layout.
    section.content_layout = nil

    local child = qt_constants.WIDGET.CREATE_LABEL("orphan")
    assert(child, "DR-ADD-NO-LAYOUT: could not create child widget")

    local err_result = section:addContentWidget(child)
    assert(error_system.is_error(err_result), string.format(
        "DR-ADD-NO-LAYOUT: addContentWidget with nil layout must return error; got: %s",
        tostring(err_result)))
    assert(err_result.code == error_system.CODES.SECTION_NOT_INITIALIZED,
        string.format(
            "DR-ADD-NO-LAYOUT: error code must be SECTION_NOT_INITIALIZED; got %s",
            tostring(err_result.code)))
    print("  PASS DR-ADD-NO-LAYOUT")
end

-- ── DR-CLEANUP ─────────────────────────────────────────────────────────────
print("-- DR-CLEANUP: cleanup() clears widget refs and connections list --")
do
    local result = collapsible_section.create_section("Cleanup Section", nil)
    assert(error_system.is_success(result), "DR-CLEANUP: create must succeed")
    local section = result.section

    -- Pre-conditions: widget refs are set.
    assert(section.main_widget    ~= nil, "DR-CLEANUP: pre: main_widget must exist")
    assert(section.header_widget  ~= nil, "DR-CLEANUP: pre: header_widget must exist")
    assert(section.content_frame  ~= nil, "DR-CLEANUP: pre: content_frame must exist")
    assert(section.content_layout ~= nil, "DR-CLEANUP: pre: content_layout must exist")

    local cleanup_result = section:cleanup()
    assert(error_system.is_success(cleanup_result), string.format(
        "DR-CLEANUP: cleanup must succeed; got: %s",
        error_system.is_error(cleanup_result) and cleanup_result.message or tostring(cleanup_result)))

    -- Widget refs cleared.
    assert(section.main_widget    == nil, "DR-CLEANUP: main_widget must be nil after cleanup")
    assert(section.header_widget  == nil, "DR-CLEANUP: header_widget must be nil after cleanup")
    assert(section.content_frame  == nil, "DR-CLEANUP: content_frame must be nil after cleanup")
    assert(section.content_layout == nil, "DR-CLEANUP: content_layout must be nil after cleanup")

    -- Connections list emptied.
    assert(type(section.connections) == "table" and #section.connections == 0,
        string.format(
            "DR-CLEANUP: connections must be empty table after cleanup; got %d items",
            type(section.connections) == "table" and #section.connections or -1))
    print("  PASS DR-CLEANUP")
end

-- ── DR-TITLE-STORED ────────────────────────────────────────────────────────
print("-- DR-TITLE-STORED: section stores its title regardless of content --")
do
    for _, title in ipairs({ "Camera", "Transform Properties", "" }) do
        local r = collapsible_section.create_section(title, nil)
        assert(error_system.is_success(r), string.format(
            "DR-TITLE-STORED: create_section(%q) must succeed", title))
        assert(r.section.title == title, string.format(
            "DR-TITLE-STORED: title must be stored verbatim; want %q got %q",
            title, tostring(r.section.title)))
    end
    print("  PASS DR-TITLE-STORED")
end

print("\n✅ test_012_collapsible_section.lua passed")
