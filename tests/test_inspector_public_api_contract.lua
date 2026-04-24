#!/usr/bin/env luajit
-- T004 (partial, pure-Lua-friendly cases): Inspector public API surface.
--
-- contracts/inspector-api.md §5 enumerates nine contract cases. Three
-- of those don't require real Qt widgets and can be tested here:
--   * forbidden-public-exports — exactly three entries on M. Any
--     accidental export (init / set_header_text / save_all_fields /
--     _G.inspector_* hacks) would reopen the legacy-accretion the 012
--     rewrite deleted.
--   * update-selection-ignores-self-source — when the Inspector is
--     itself the source of a selection event, it must early-return
--     (otherwise selection_hub → Inspector → selection_hub infinite-
--     loops). Tested directly on selection_binding.update_selection.
--   * mount-once-per-process — deferred here; requires full Qt stubs.
--     Covered manually by inspector.mount's `assert(ui_state == nil)`
--     guard which any second-mount attempt would trip.
--
-- Scenarios that need real widgets (single/multi/heterogeneous
-- rendering) stay on the deferred integration list.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Minimal package stubs so `require("ui.inspector")` can load its chain
-- without Qt bindings. The facade module itself only requires mount +
-- selection_binding; we don't call mount() here.
package.loaded["core.qt_constants"] = {}
package.loaded["core.qt_signals"] = {}
package.loaded["core.signals"] = {
    connect = function() return 1 end,
    disconnect = function() end,
    emit = function() end,
}

print("=== Inspector public API contract (T004 subset) ===")

-- ----------------------------------------------------------------------
-- Case 0: mount-idempotent-failure.
-- A second mount() on the same process must raise — not silently
-- no-op, not clobber ui_state. Silent-replace would leave the prior
-- mount's widgets + signal handlers dangling (signal_bindings.cpp
-- keeps them alive; Lua's garbage collector can't reach the Qt
-- widgets through the bindings). The assertion has been observed
-- firing in TSO — this test guards that it stays firing.
-- ----------------------------------------------------------------------
-- Stub the downstream mount module so the facade's first mount()
-- succeeds without constructing real Qt widgets. The facade itself
-- stashes the returned ui_state and checks `ui_state == nil` on
-- subsequent calls — that's the invariant under test.
package.loaded["ui.inspector.mount"] = {
    mount = function(_container)
        -- Return a stand-in ui_state. Content doesn't matter; the
        -- facade only asserts non-nil-ness of its stored reference.
        return { mounted = true }
    end,
}
package.loaded["ui.inspector.selection_binding"] = package.loaded["ui.inspector.selection_binding"] or {
    update_selection = function() end,
}
package.loaded["ui.inspector"] = nil
local inspector_reloaded = require("ui.inspector")

inspector_reloaded.mount({ _container = "first" })  -- first mount succeeds

local second_ok, second_err = pcall(inspector_reloaded.mount, { _container = "second" })
assert(not second_ok, "second mount() must raise, not silently no-op")
assert(tostring(second_err):find("already mounted"), string.format(
    "second-mount error must explain why (substring 'already mounted'); got: %s",
    tostring(second_err)))
print("  OK: second mount() raises 'already mounted'")

-- Reload a clean facade for the remaining cases so they don't inherit
-- the mounted state above.
package.loaded["ui.inspector"] = nil
package.loaded["ui.inspector.mount"] = nil

-- ----------------------------------------------------------------------
-- Case 1: forbidden-public-exports.
-- Exactly three functions on the facade. Any extra export reopens the
-- 012 rewrite's elimination of legacy exposures.
-- ----------------------------------------------------------------------
package.loaded["ui.inspector"] = nil
local inspector = require("ui.inspector")

local expected = { mount = true, update_selection = true, get_focus_widgets = true }
local actual_count, unexpected = 0, {}
for k, v in pairs(inspector) do
    actual_count = actual_count + 1
    if not expected[k] then unexpected[#unexpected + 1] = k .. "=" .. type(v) end
end
assert(actual_count == 3, string.format(
    "ui.inspector must export exactly 3 functions; found %d. Extras: %s",
    actual_count, table.concat(unexpected, ", ")))
assert(type(inspector.mount) == "function",             "mount must be a function")
assert(type(inspector.update_selection) == "function",  "update_selection must be a function")
assert(type(inspector.get_focus_widgets) == "function", "get_focus_widgets must be a function")
print("  OK: exactly {mount, update_selection, get_focus_widgets} exported")

-- ----------------------------------------------------------------------
-- Case 2: update-selection-ignores-self-source.
-- The facade's update_selection delegates to selection_binding.
-- selection_binding must early-return when source_panel_id == "inspector".
-- Tested at the selection_binding level since the facade's call path
-- lands there.
-- ----------------------------------------------------------------------
package.loaded["core.command_manager"] = {
    begin_command_event = function() end,
    end_command_event = function() end,
}
package.loaded["core.qt_constants"] = {
    DISPLAY = { SET_VISIBLE = function() end },
    PROPERTIES = { SET_TEXT = function() end },
    CONTROL = { SET_ENABLED = function() end },
}
package.loaded["inspectable"] = {
    clip = function() return nil end, sequence = function() return nil end,
}
package.loaded["ui.inspector.selection_binding"] = nil
local sb = require("ui.inspector.selection_binding")

-- A ui_state in a non-empty, non-default shape so we can detect whether
-- update_selection mutated it. If the self-source early-return fires,
-- the mode stays at the sentinel we installed.
local ui_state = {
    mode = "SENTINEL_should_stay",
    active_schema_view  = nil,
    active_schema_id    = nil,
    active_inspectables = {},
    prev_item_ids        = {},
    prev_schemas_present = {},
    filter_query = "",
    schema_views = {},
    schema = { deactivate = function() end, activate = function() end, apply_filter = function() end },
    header_label = {}, apply_button = {}, bottom_bar = {},
}

sb.update_selection({}, "inspector", ui_state)
assert(ui_state.mode == "SENTINEL_should_stay", string.format(
    "source='inspector' must early-return before any ui_state mutation; " ..
    "mode got clobbered to %q", tostring(ui_state.mode)))
print("  OK: source='inspector' early-returns (no ui_state mutation)")

-- Sanity: source='timeline' DOES route and mutates mode (empty items → empty mode).
sb.update_selection({}, "timeline", ui_state)
assert(ui_state.mode == "empty", string.format(
    "source='timeline' + empty items should set mode='empty'; got %q",
    tostring(ui_state.mode)))
print("  OK: source='timeline' still routes through to mode='empty'")

print("✅ test_inspector_public_api_contract.lua passed")
