#!/usr/bin/env luajit
-- T005 / FR-021: the F key (MatchFrame) must be reachable from every focus
-- context that can carry a selected clip, including timeline_monitor.
-- TSO 2026-05-15 showed `→ unhandled key=70` from timeline_monitor focus
-- because MatchFrame's TOML binding was scoped to @timeline (the panel id),
-- and the user's actual focus was on timeline_monitor (the monitor inside
-- the timeline panel). The 017 keymap rewire makes clip-context commands
-- reachable from every focus.
--
-- Black-box: drive registry.handle_key_event(F, 0, "timeline_monitor")
-- and verify MatchFrame is dispatched. Stub command_manager to capture
-- the dispatched command name.

require("test_env")

print("=== test_match_frame_works_from_every_clip_selecting_focus.lua ===")

local registry = require("core.keyboard_shortcut_registry")

local dispatched = {}
local stub_command_manager = {
    get_executor = function(_) return function() return { success = true } end end,
        get_spec = function() return nil end,
    execute_interactive = function(name, _params)
        dispatched[#dispatched + 1] = name
        return { success = true }
    end,
}
registry.set_command_manager(stub_command_manager)

-- load_keybindings asserts internally on parse failure; here we just rely
-- on it not raising. After return, M.keybindings is populated.
local keymap_path = require("test_env").resolve_repo_path("keymaps/default.jvekeys")
registry.load_keybindings(keymap_path)
assert(next(registry.keybindings) ~= nil,
    "registry.keybindings must be non-empty after load_keybindings")

-- Qt key code for F is 70.
local F_KEY = 70
local NO_MOD = 0

local handled = registry.handle_key_event(F_KEY, NO_MOD, "timeline_monitor")
assert(handled == true, string.format(
    "F-key with active_context='timeline_monitor' was unhandled "
    .. "(FR-021 regression: clip-context commands not reachable from monitor focus). "
    .. "handled=%s dispatched=%s", tostring(handled), table.concat(dispatched, ",")))

assert(#dispatched == 1, string.format(
    "expected exactly one dispatched command, got %d: {%s}",
    #dispatched, table.concat(dispatched, ",")))
assert(dispatched[1] == "MatchFrame", string.format(
    "F-key dispatched '%s', expected 'MatchFrame'", dispatched[1]))

print("✅ test_match_frame_works_from_every_clip_selecting_focus.lua passed")
