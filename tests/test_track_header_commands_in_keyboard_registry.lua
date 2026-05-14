#!/usr/bin/env luajit

-- Regression: every track-header button must be reachable from the keyboard
-- shortcut editor. Without this only menu items appeared in the dialog —
-- track-header commands have no menu entry, so the user could not bind a
-- shortcut to them and the corresponding button was keyboard-unreachable
-- (Joe 2026-05-14).
--
-- Domain behavior: loading a command whose SPEC declares keyboard metadata
-- surfaces it under `get_commands_by_category` (the API the customisation
-- dialog reads from). The metadata lives on the command's own SPEC — no
-- separate hand-maintained list. Loading is idempotent.

require("test_env")

print("=== test_track_header_commands_in_keyboard_registry.lua ===")

local database         = require("core.database")
local command_registry = require("core.command_registry")
local registry         = require("core.keyboard_shortcut_registry")

local DB = "/tmp/jve/test_track_header_kbsr.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
command_registry.init(database.get_connection(), function() end)

local EXPECTED_CATEGORY = "Timeline ▸ Track Header"
local EXPECTED = {
    "ToggleTrackPreference", "SetSyncMode", "SetPatch",
    "ToggleTrackWaveformDisplay", "SetTrackMixValue",
}

-- Sibling tests may have populated kbsr; clear so the pre-condition holds.
for k in pairs(registry.commands) do registry.commands[k] = nil end
-- Modules may already be cached by Lua require; the kbsr registration only
-- happens at register_executor time. Clear command_specs so the hook re-fires.
for _, id in ipairs(EXPECTED) do
    command_registry.unregister_executor(id)
end

assert(registry.commands["ToggleTrackWaveformDisplay"] == nil,
    "test setup: pre-condition failed — registry wasn't reset")

-- The customisation dialog's `show` calls this exact path. Test the
-- domain behavior: after the user opens the dialog, every track-header
-- command appears under the header category.
command_registry.load_all_command_modules()

local by_category = registry.get_commands_by_category()
local cat_entries = by_category[EXPECTED_CATEGORY]
assert(type(cat_entries) == "table" and #cat_entries > 0, string.format(
    "FAIL: category %q missing from get_commands_by_category() output — "
    .. "the customisation dialog reads from this map, so an absent category "
    .. "means invisible commands.", EXPECTED_CATEGORY))

local in_category = {}
for _, c in ipairs(cat_entries) do in_category[c.id] = true end

for _, id in ipairs(EXPECTED) do
    assert(registry.commands[id], string.format(
        "FAIL: command %q not registered — the header button it backs "
        .. "cannot be bound to a keyboard shortcut.", id))
    assert(in_category[id], string.format(
        "FAIL: command %q registered but not surfaced under %q",
        id, EXPECTED_CATEGORY))
    local entry = registry.commands[id]
    assert(type(entry.name) == "string" and entry.name ~= "",
        "FAIL: command " .. id .. " registered without a display name")
    assert(type(entry.description) == "string",
        "FAIL: command " .. id .. " registered without a description")
end

-- Idempotency: reloading a module must not double-register.
for _, id in ipairs(EXPECTED) do
    command_registry.load_command_module(id)
end
local cat2 = registry.get_commands_by_category()[EXPECTED_CATEGORY]
assert(#cat2 == #cat_entries, string.format(
    "FAIL: reloading commands produced duplicates: %d → %d entries",
    #cat_entries, #cat2))

print(string.format("  %d header commands registered under %q — OK",
    #EXPECTED, EXPECTED_CATEGORY))
print("\n✅ test_track_header_commands_in_keyboard_registry.lua passed")
