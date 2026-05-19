-- 004 smoke: keyboard registry loads a TOML keymap and binds shortcuts.
--
-- Acceptance: app boot loads `keymaps/default.jvekeys` and the registry
-- exposes command bindings the UI can iterate (no monolithic event filter;
-- bindings live as data the registry hands to QShortcut at panel mount).

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_004_keyboard_arch_smoke.lua ===")

require("test_env")
local registry = require("core.keyboard_shortcut_registry")

-- The default keymap ships in the repo. Loading it must populate
-- registry.keybindings with at least one entry whose shortcut maps to a
-- known command id (e.g. Space → TogglePlay).
local default_path = require("test_env").resolve_repo_path("keymaps/default.jvekeys")
registry.load_keybindings(default_path)  -- asserts internally on failure

assert(type(registry.keybindings) == "table",
    "registry.keybindings must be a table after load")
local n = 0
for _, arr in pairs(registry.keybindings) do
    for _ in ipairs(arr) do n = n + 1 end
end
assert(n > 0, "registry must have at least one binding after loading default.jvekeys")
print(string.format("  PASS: default keymap loaded — %d bindings", n))

-- TogglePlay is in the JVE default keymap (typically Space); verify it's bound.
local found_play
for _, arr in pairs(registry.keybindings) do
    for _, binding in ipairs(arr) do
        if binding.command_name == "TogglePlay" then
            found_play = binding; break
        end
    end
    if found_play then break end
end
assert(found_play, "TogglePlay must be bound somewhere in the default keymap")
print("  PASS: TogglePlay bound")

print("\n✅ test_004_keyboard_arch_smoke.lua passed")
