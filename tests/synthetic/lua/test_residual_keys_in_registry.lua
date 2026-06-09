#!/usr/bin/env luajit

-- Regression: Comma/Period/E used to live as hardcoded handlers in
-- keyboard_shortcuts.lua and were therefore invisible to the keyboard-
-- customization dialog (the dialog reads from the TOML-driven registry).
-- After moving them onto NudgeSelection / ExtendEdit, the bundled keymap
-- must surface all five bindings via the same registry the dialog reads.
--
-- This test reads the on-disk default keymap directly through the registry
-- and asserts the bindings exist for the right commands. If somebody
-- removes an entry from keymaps/default.jvekeys (or regresses by moving the
-- handlers back into keyboard_shortcuts.lua), this test fails.

require("test_env")

local registry = require("core.keyboard_shortcut_registry")
local kb = require("core.keyboard_constants")

-- Fresh state in case another test polluted the registry.
registry.commands = {}
registry.keybindings = {}

-- Tests run from tests/ directory; the keymap is one level up.
registry.load_keybindings("../keymaps/default.jvekeys")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

local function shortcuts_for(cmd_id)
    return registry.get_command_shortcuts(cmd_id)
end

local function has_combo(scs, key, mods)
    for _, sc in ipairs(scs) do
        if sc.key == key and sc.modifiers == mods then return true end
    end
    return false
end

print("\n=== Residual keys (Comma/Period/E) live in the TOML registry ===")

-- NudgeSelection: four bindings with @timeline context.
local nudge_scs = shortcuts_for("NudgeSelection")
check("NudgeSelection has 4 shortcuts", #nudge_scs == 4)
check("NudgeSelection bound to Comma", has_combo(nudge_scs, kb.KEY.Comma, 0))
check("NudgeSelection bound to Period", has_combo(nudge_scs, kb.KEY.Period, 0))
check("NudgeSelection bound to Shift+Comma",
    has_combo(nudge_scs, kb.KEY.Comma, kb.MOD.Shift))
check("NudgeSelection bound to Shift+Period",
    has_combo(nudge_scs, kb.KEY.Period, kb.MOD.Shift))

-- ExtendEdit: single E binding.
local extend_scs = shortcuts_for("ExtendEdit")
check("ExtendEdit has 1 shortcut", #extend_scs == 1)
check("ExtendEdit bound to E", has_combo(extend_scs, kb.KEY.E, 0))

-- Each binding carries the @timeline context so the dialog can show the
-- scope (and the registry's panel-scoped dispatch can find a container).
local function each_binding_for(cmd_id)
    local out = {}
    for _, bindings in pairs(registry.keybindings) do
        for _, b in ipairs(bindings) do
            if b.command_name == cmd_id then out[#out + 1] = b end
        end
    end
    return out
end

local function all_have_timeline_context(bindings)
    for _, b in ipairs(bindings) do
        local found = false
        for _, ctx in ipairs(b.contexts or {}) do
            if ctx == "timeline" then found = true; break end
        end
        if not found then return false end
    end
    return true
end

check("NudgeSelection bindings carry @timeline context",
    all_have_timeline_context(each_binding_for("NudgeSelection")))
check("ExtendEdit binding carries @timeline context",
    all_have_timeline_context(each_binding_for("ExtendEdit")))

-- The dialog enumerates commands via this registry. Both must appear.
check("NudgeSelection registered in commands map",
    registry.commands["NudgeSelection"] ~= nil)
check("ExtendEdit registered in commands map",
    registry.commands["ExtendEdit"] ~= nil)

-- Each NudgeSelection binding must encode a direction and magnitude (the
-- whole point of moving routing into TOML — magnitude is now configurable).
local function binding_with_named(bindings, k, v)
    for _, b in ipairs(bindings) do
        if b.named_params and b.named_params[k] == v then return b end
    end
    return nil
end

local nudge_bindings = each_binding_for("NudgeSelection")
check("NudgeSelection has direction=-1 magnitude=1 binding",
    binding_with_named(nudge_bindings, "direction", -1)
    and binding_with_named(nudge_bindings, "magnitude", 1))
check("NudgeSelection has direction=+1 magnitude=5 binding",
    binding_with_named(nudge_bindings, "magnitude", 5)
    and binding_with_named(nudge_bindings, "direction", 1))

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_residual_keys_in_registry.lua passed")
