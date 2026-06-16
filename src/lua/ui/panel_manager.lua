--- Panel maximize/restore + SequenceMonitor registry
--
-- @file panel_manager.lua
local qt_constants = require("core.qt_constants")
local ui_constants = require("core.ui_constants")
local panel_layout = require("ui.panel_layout")
local log = require("core.logger").for_area("ui")

local M = {}

local state = {
    main_splitter = nil,
    top_splitter = nil,
    focus_manager = nil,
    maximized = nil,
}

-- SequenceMonitor registry: { [view_id] = SequenceMonitor instance }
local sequence_monitors = {}

local function get_splitter_sizes(splitter)
    if not splitter or not qt_constants.LAYOUT or not qt_constants.LAYOUT.GET_SPLITTER_SIZES then
        return nil
    end
    local ok, sizes = pcall(qt_constants.LAYOUT.GET_SPLITTER_SIZES, splitter)
    if ok then return sizes end
    return nil
end

local function set_splitter_sizes(splitter, sizes)
    -- Both are required: every caller (maximize/restore) computes a concrete
    -- splitter handle + size vector. A nil here is a bootstrap-order bug, not
    -- an optional-arg case — surface it instead of silently skipping the apply.
    assert(splitter, "panel_manager.set_splitter_sizes: splitter required")
    assert(sizes, "panel_manager.set_splitter_sizes: sizes required")
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(splitter, sizes)
end

local function focused_panel(panel_id)
    if panel_id and panel_id ~= "" then
        return panel_id
    end
    if state.focus_manager and state.focus_manager.get_focused_panel then
        return state.focus_manager.get_focused_panel()
    end
    return nil
end

function M.init(opts)
    assert(opts, "panel_manager.init: opts required")
    state.main_splitter = opts.main_splitter
    state.top_splitter = opts.top_splitter
    state.focus_manager = opts.focus_manager
end

local function maximize_top_panel(panel_id)
    if not state.top_splitter or not state.main_splitter then
        return false, "Splitters not initialized"
    end

    local panel_index = panel_layout.top_index(panel_id)
    if not panel_index then
        return false, string.format("Unknown panel '%s'", tostring(panel_id))
    end

    local main_sizes = assert(get_splitter_sizes(state.main_splitter), "panel_manager.maximize_top_panel: failed to get main_splitter sizes")
    local top_sizes = assert(get_splitter_sizes(state.top_splitter), "panel_manager.maximize_top_panel: failed to get top_splitter sizes")
    local total_main = 0
    for _, value in ipairs(main_sizes) do
        total_main = total_main + value
    end
    assert(total_main > 0, "panel_manager.maximize_top_panel: total_main is zero")

    state.maximized = {
        panel_id = panel_id,
        main_sizes = main_sizes,
        top_sizes = top_sizes,
    }

    -- Hide timeline, show top area only
    set_splitter_sizes(state.main_splitter, {total_main, 0})

    local panel_count = #top_sizes
    local new_top_sizes = {}
    for i = 1, panel_count do new_top_sizes[i] = 0 end
    new_top_sizes[panel_index] = total_main
    set_splitter_sizes(state.top_splitter, new_top_sizes)

    return true
end

local function maximize_timeline()
    if not state.main_splitter then
        return false, "Main splitter not initialized"
    end

    local main_sizes = assert(get_splitter_sizes(state.main_splitter), "panel_manager.maximize_timeline: failed to get main_splitter sizes")
    local top_sizes = assert(get_splitter_sizes(state.top_splitter), "panel_manager.maximize_timeline: failed to get top_splitter sizes")
    local total_main = 0
    for _, value in ipairs(main_sizes) do
        total_main = total_main + value
    end
    assert(total_main > 0, "panel_manager.maximize_timeline: total_main is zero")

    state.maximized = {
        panel_id = "timeline",
        main_sizes = main_sizes,
        top_sizes = top_sizes,
    }

    set_splitter_sizes(state.main_splitter, {0, total_main})
    return true
end

local function restore_layout()
    if not state.maximized then return false end

    -- maximize_top_panel / maximize_timeline always snapshot BOTH vectors, so
    -- both are present here by construction; set_splitter_sizes asserts if not.
    set_splitter_sizes(state.main_splitter, state.maximized.main_sizes)
    set_splitter_sizes(state.top_splitter, state.maximized.top_sizes)

    state.maximized = nil
    return true
end

function M.is_maximized()
    return state.maximized ~= nil
end

--- Return splitter sizes suitable for persistence, or nil if there's
-- nothing to snapshot yet (UI not bootstrapped — e.g. a project swap
-- driven from the debug-terminal socket or a `--test` script before
-- ui/layout.lua wires the splitters). Callers in OpenProject's
-- post_open_init already gate on this returning nil. Matches the
-- `if timeline_panel and ...` pattern used elsewhere in this snapshot
-- phase; a query for non-existent state should return nil, not assert.
-- `restore_or_default` follows the same rule: it also no-ops (returns nil)
-- when the UI isn't bootstrapped, since OpenProject can run before the
-- splitters are wired (out-of-band socket open / headless --test).
function M.get_persistable_sizes()
    if not state.main_splitter then return nil end
    if state.maximized then
        return {
            top = state.maximized.top_sizes,
            main = state.maximized.main_sizes,
        }
    end
    return {
        top = get_splitter_sizes(state.top_splitter),
        main = get_splitter_sizes(state.main_splitter),
    }
end

--- Apply saved splitter sizes if they validate against the panel topology
-- and are non-degenerate; otherwise apply the topology defaults. This is the
-- single restore contract for BOTH startup (ui/layout.lua) and project switch
-- (core/commands/open_project.lua) — the two previously had divergent
-- validation (one checked counts + minimum width, the other accepted any
-- vector of length >= 2, letting degenerate sizes collapse panels on switch).
-- Returns nil when the UI isn't bootstrapped yet (an out-of-band OpenProject
-- via the debug-terminal socket, or a headless --test that opens a project
-- without wiring the splitters). That's a no-op, not an error — same contract
-- as get_persistable_sizes returning nil; the caller skips persistence.
-- @return applied table|nil  the sizes actually applied (saved or defaults), or nil if not bootstrapped
-- @return defaulted boolean  true when saved was rejected and defaults used
function M.restore_or_default(saved_sizes)
    if not state.main_splitter then return nil end

    local ok, why = panel_layout.validate_sizes(saved_sizes, ui_constants.WINDOW.MIN_PANEL_PX)
    if ok then
        set_splitter_sizes(state.top_splitter, saved_sizes.top)
        set_splitter_sizes(state.main_splitter, saved_sizes.main)
        return saved_sizes, false
    end

    if saved_sizes ~= nil then
        log.warn("Discarding invalid splitter sizes (%s); applying defaults", tostring(why))
    end
    local defaults = {
        top = panel_layout.default_top_sizes(),
        main = panel_layout.default_main_sizes(),
    }
    set_splitter_sizes(state.top_splitter, defaults.top)
    set_splitter_sizes(state.main_splitter, defaults.main)
    return defaults, true
end

function M.toggle_maximize(panel_id)
    if not state.main_splitter then
        return false, "Panel manager not initialized"
    end

    local target_panel = focused_panel(panel_id)
    if not target_panel then
        return false, "No focused panel"
    end

    if state.maximized then
        if not panel_id or state.maximized.panel_id == target_panel then
            return restore_layout(), nil
        end
        restore_layout()
    end

    if target_panel == "timeline" then
        return maximize_timeline()
    else
        return maximize_top_panel(target_panel)
    end
end

--------------------------------------------------------------------------------
-- SequenceMonitor Registry
--------------------------------------------------------------------------------

--- Register a SequenceMonitor instance.
-- @param view_id string  "source_monitor" or "timeline_monitor"
-- @param sm SequenceMonitor instance
function M.register_sequence_monitor(view_id, sm)
    assert(view_id and view_id ~= "",
        "panel_manager.register_sequence_monitor: view_id required")
    assert(sm, string.format(
        "panel_manager.register_sequence_monitor: sm required for '%s'", view_id))
    sequence_monitors[view_id] = sm
    log.event("registered sequence monitor '%s'", view_id)
end

--- Get a SequenceMonitor by view_id.
-- @param view_id string  "source_monitor" or "timeline_monitor"
-- @return SequenceMonitor
function M.get_sequence_monitor(view_id)
    assert(view_id and view_id ~= "",
        "panel_manager.get_sequence_monitor: view_id required")
    local sm = sequence_monitors[view_id]
    assert(sm, string.format(
        "panel_manager.get_sequence_monitor: no monitor registered for '%s'", view_id))
    return sm
end

--- Get the SequenceMonitor for the currently focused panel.
-- Falls back to timeline_monitor if focused panel is not a sequence monitor.
-- @return SequenceMonitor|nil
function M.get_active_sequence_monitor()
    local panel_id = focused_panel(nil)

    -- Map focus panel names to view_ids
    if panel_id == "source_monitor" then
        return sequence_monitors["source_monitor"]
    elseif panel_id == "timeline_monitor" or panel_id == "timeline" then
        return sequence_monitors["timeline_monitor"]
    end

    -- Non-monitor panel focused (browser, inspector) — return timeline_monitor
    return sequence_monitors["timeline_monitor"]
end

return M
