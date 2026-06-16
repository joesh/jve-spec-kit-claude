-- Integration: panel_manager maximize/restore drives real QSplitters.
--
-- The old test mocked LAYOUT.GET/SET_SPLITTER_SIZES with a Lua-table
-- store, which meant it tested only panel_manager's bookkeeping — not
-- whether real QSplitter's accepts/preserves the size vectors. The Qt
-- splitter rebalances when total != sum-of-children's hinted sizes,
-- so a real-binding test pins the actual layout invariant.
--
-- Layout mirrors layout.lua:
--   top_splitter (horizontal): browser, source_mon, timeline_mon, inspector
--   main_splitter (vertical):  top_splitter, timeline
-- Splitters are placed in a hosting main window so Qt assigns geometry;
-- without a parent + show(), real GET_SPLITTER_SIZES returns zeros.

print("=== test_panel_maximize.lua ===")

require("test_env")
local panel_manager = require("ui.panel_manager")

local function make_widget()
    local w = qt_constants.WIDGET.CREATE()
    assert(w, "WIDGET.CREATE returned nil")
    return w
end

-- Build the real splitter tree.
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_SIZE(main_window, 1200, 900)

local top_splitter  = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

local browser_w        = make_widget()
local source_mon_w     = make_widget()
local timeline_mon_w   = make_widget()
local inspector_w      = make_widget()
local timeline_w       = make_widget()

qt_constants.LAYOUT.ADD_WIDGET(top_splitter, browser_w)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, source_mon_w)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, timeline_mon_w)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, inspector_w)

qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_w)

qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)
qt_constants.DISPLAY.SHOW(main_window)

-- Establish baseline sizes the test will check restore against. Real Qt
-- may distribute residuals across children — read back the actual values
-- after the set so our "restored" assertion compares against what Qt
-- actually keeps, not what we asked for.
qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter,  {300, 300, 300, 300})
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {450, 450})

local baseline_top  = qt_constants.LAYOUT.GET_SPLITTER_SIZES(top_splitter)
local baseline_main = qt_constants.LAYOUT.GET_SPLITTER_SIZES(main_splitter)

local function sum(t) local s=0; for _,v in ipairs(t) do s=s+v end; return s end
assert(#baseline_top  == 4, "top splitter must have 4 panels")
assert(#baseline_main == 2, "main splitter must have 2 rows")
assert(sum(baseline_top)  > 0, "top sizes nonzero")
assert(sum(baseline_main) > 0, "main sizes nonzero")

-- Fake focus_manager — panel_manager only needs get_focused_panel(); the
-- focus subsystem itself isn't under test here.
local focused = "source_monitor"
local focus_stub = { get_focused_panel = function() return focused end }

panel_manager.init({
    main_splitter  = main_splitter,
    top_splitter   = top_splitter,
    focus_manager  = focus_stub,
})

-- ── (1) Maximize source_monitor zeroes siblings + timeline row ────────
print("-- (1) Maximize source_monitor --")
focused = "source_monitor"
local ok, err = panel_manager.toggle_maximize(nil)
assert(ok, "toggle_maximize failed: " .. tostring(err))
assert(panel_manager.is_maximized(), "must be maximized")

local top = qt_constants.LAYOUT.GET_SPLITTER_SIZES(top_splitter)
assert(top[1] == 0, "project_browser zero; got " .. top[1])
assert(top[2] >  0, "source_monitor > 0; got "    .. top[2])
assert(top[3] == 0, "timeline_monitor zero; got " .. top[3])
assert(top[4] == 0, "inspector zero; got "        .. top[4])

local main = qt_constants.LAYOUT.GET_SPLITTER_SIZES(main_splitter)
assert(main[2] == 0, "timeline row zero; got " .. main[2])
print("  PASS source_monitor maximized")

-- ── (2) Restore returns to baseline ────────────────────────────────────
print("-- (2) Restore --")
ok = panel_manager.toggle_maximize(nil); assert(ok)
assert(not panel_manager.is_maximized(), "must restore")

top = qt_constants.LAYOUT.GET_SPLITTER_SIZES(top_splitter)
for i = 1, 4 do
    assert(top[i] == baseline_top[i], string.format(
        "top[%d] %d != baseline %d", i, top[i], baseline_top[i]))
end
main = qt_constants.LAYOUT.GET_SPLITTER_SIZES(main_splitter)
for i = 1, 2 do
    assert(main[i] == baseline_main[i], string.format(
        "main[%d] %d != baseline %d", i, main[i], baseline_main[i]))
end
print("  PASS sizes restored")

-- ── (3) Maximize timeline collapses top row ────────────────────────────
print("-- (3) Maximize timeline --")
focused = "timeline"
ok = panel_manager.toggle_maximize(nil); assert(ok)
assert(panel_manager.is_maximized())

main = qt_constants.LAYOUT.GET_SPLITTER_SIZES(main_splitter)
assert(main[1] == 0, "top row zero; got " .. main[1])
assert(main[2] >  0, "timeline > 0; got " .. main[2])

ok = panel_manager.toggle_maximize(nil); assert(ok)
assert(not panel_manager.is_maximized())
print("  PASS timeline maximize/restore")

-- ── (4) get_persistable_sizes returns PRE-maximize while maximized ────
-- This is the regression guard: if persistable returned the live (post-
-- maximize) Qt sizes, saving + reloading would lose the user's layout.
print("-- (4) get_persistable_sizes while maximized --")
focused = "source_monitor"
ok = panel_manager.toggle_maximize(nil); assert(ok)
assert(panel_manager.is_maximized())

top = qt_constants.LAYOUT.GET_SPLITTER_SIZES(top_splitter)
assert(top[1] == 0, "sanity: Qt reports zero for hidden panel")

local persist = panel_manager.get_persistable_sizes()
assert(persist, "get_persistable_sizes returned nil")
for i = 1, 4 do
    assert(persist.top[i] == baseline_top[i], string.format(
        "persist.top[%d] %d != baseline %d", i, persist.top[i], baseline_top[i]))
end
for i = 1, 2 do
    assert(persist.main[i] == baseline_main[i], string.format(
        "persist.main[%d] %d != baseline %d", i, persist.main[i], baseline_main[i]))
end
print("  PASS pre-maximize sizes preserved")

-- ── (5) get_persistable_sizes returns LIVE sizes when not maximized ───
print("-- (5) get_persistable_sizes when not maximized --")
panel_manager.toggle_maximize(nil)  -- restore
assert(not panel_manager.is_maximized())

persist = panel_manager.get_persistable_sizes()
assert(persist, "get_persistable_sizes returned nil")
for i = 1, 4 do
    assert(persist.top[i] == baseline_top[i], string.format(
        "live persist.top[%d] %d != baseline %d", i, persist.top[i], baseline_top[i]))
end
for i = 1, 2 do
    assert(persist.main[i] == baseline_main[i], string.format(
        "live persist.main[%d] %d != baseline %d", i, persist.main[i], baseline_main[i]))
end
print("  PASS live sizes returned")

-- ── (6) restore_or_default: validates saved sizes, falls back to defaults ──
-- This is the single restore contract shared by startup and project switch.
-- The regression it guards: a degenerate/stale saved record must NOT be
-- applied verbatim (that collapses panels), it must reset to defaults.
print("-- (6) restore_or_default validation --")

-- Well-formed record → applied, not defaulted.
local applied, defaulted = panel_manager.restore_or_default(
    { top = {300, 300, 300, 300}, main = {450, 450} })
assert(not defaulted, "valid sizes should not default")
assert(#applied.top == 4 and #applied.main == 2, "applied keeps topology shape")

-- Degenerate record (a collapsed panel) → defaults, defaulted=true.
applied, defaulted = panel_manager.restore_or_default(
    { top = {880, 0, 0, 0}, main = {450, 450} })
assert(defaulted, "collapsed-panel record must fall back to defaults")
for i = 1, 4 do
    assert(applied.top[i] >= 50, "defaulted top panel is visible; got " .. applied.top[i])
end

-- Stale 3-panel record (pre-fourth-panel) → defaults (no migration).
local _, stale_defaulted = panel_manager.restore_or_default(
    { top = {400, 400, 400}, main = {450, 450} })
assert(stale_defaulted, "stale 3-panel record must fall back to defaults, not migrate")

-- No saved record at all → defaults.
applied, defaulted = panel_manager.restore_or_default(nil)
assert(defaulted, "missing record must fall back to defaults")
assert(#applied.top == 4 and #applied.main == 2, "default shape matches topology")
print("  PASS restore_or_default validation")

print("\nPASS test_panel_maximize.lua")
