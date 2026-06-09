#!/usr/bin/env luajit

-- Registry disk-backed preset workflow.
-- Black-box behavior: a preset saved to disk can be reloaded into a registry
-- whose state has been mutated; reload restores the saved state exactly.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua"

local registry = require("core.keyboard_shortcut_registry")
local store = require("core.user_keymap_store")

local function fail(label, message)
    io.stderr:write(string.format("%s: %s\n", label, message or "failed"))
    os.exit(1)
end

local function assert_true(label, cond)
    if not cond then fail(label, "expected truthy") end
end

local function assert_equals(label, actual, expected)
    if actual ~= expected then
        fail(label, string.format("expected %s, got %s",
            tostring(expected), tostring(actual)))
    end
end

local function setup()
    local base = string.format("/tmp/jve_registry_disk_%d", os.time())
    os.execute("rm -rf " .. base)
    store.set_base_dir(base)

    registry.commands = {}
    registry.keybindings = {}
    registry.presets = {}
    registry.current_preset = "Default"
    registry.loaded_toml_path = nil
end

-- Build a minimal known TOML and load it as if it were the default.
local function load_seed_toml()
    local seed = "/tmp/jve_seed_keymap.jvekeys"
    local f = assert(io.open(seed, "w"))
    f:write([[
[Application]
"Cmd+Z" = "Undo"
"Cmd+Y" = "Redo"

[Transport]
"Space" = "TogglePlay @timeline"
]])
    f:close()
    registry.load_keybindings(seed)
end

local function bindings_count()
    local n = 0
    for _, list in pairs(registry.keybindings) do n = n + #list end
    return n
end

local function combo_command(combo_string)
    -- Look up which command a combo string maps to (after parse normalization)
    local sc = registry.parse_shortcut(combo_string)
    if not sc then return nil end
    local key = string.format("%d_%d", sc.key, sc.modifiers)
    local list = registry.keybindings[key]
    if not list or #list == 0 then return nil end
    return list[1].command_name
end

-- Test 1: serialize then re-parse yields equivalent binding set
local function test_round_trip()
    setup()
    load_seed_toml()
    local before_count = bindings_count()
    assert_equals("seed has 3", before_count, 3)

    local toml = registry.serialize_to_toml()
    assert_true("non-empty toml", toml and #toml > 0)

    -- Wipe and re-parse from the serialized form
    registry.keybindings = {}
    local tmp = "/tmp/jve_round_trip.jvekeys"
    local f = assert(io.open(tmp, "w")); f:write(toml); f:close()
    registry.load_keybindings(tmp)

    assert_equals("count preserved", bindings_count(), before_count)
    assert_equals("Undo preserved", combo_command("Cmd+Z"), "Undo")
    assert_equals("Redo preserved", combo_command("Cmd+Y"), "Redo")
    assert_equals("TogglePlay preserved", combo_command("Space"), "TogglePlay")
end

-- Test 2: save_preset writes to disk; load_preset on a different state restores
local function test_save_load_disk()
    setup()
    load_seed_toml()

    local ok = registry.save_preset("MyKit")
    assert_true("save_preset returns truthy", ok)
    assert_true("preset on disk", store.exists("MyKit"))

    -- Mutate registry state — wipe entirely
    registry.keybindings = {}
    assert_equals("wiped", bindings_count(), 0)

    -- Load preset back
    local loaded, err = registry.load_preset("MyKit")
    assert_true("load_preset ok: " .. tostring(err), loaded)

    -- Verify state restored
    assert_equals("restored count", bindings_count(), 3)
    assert_equals("restored Undo", combo_command("Cmd+Z"), "Undo")
    assert_equals("active preset name", registry.current_preset, "MyKit")
end

-- Test 3: list_presets includes Default sentinel + on-disk presets
local function test_list_presets()
    setup()
    load_seed_toml()
    registry.save_preset("Alpha")
    registry.save_preset("Bravo")

    local presets = registry.list_presets()
    -- Convert to lookup
    local has = {}
    for _, name in ipairs(presets) do has[name] = true end
    assert_true("Default included", has["Default"])
    assert_true("Alpha included", has["Alpha"])
    assert_true("Bravo included", has["Bravo"])
end

-- Test 4: contexts and category survive round-trip (Cut is panel-scoped)
local function test_context_survives()
    setup()
    local seed = "/tmp/jve_ctx_keymap.jvekeys"
    local f = assert(io.open(seed, "w"))
    f:write([[
[Application]
"Cmd+X" = "Cut @timeline"
]])
    f:close()
    registry.load_keybindings(seed)

    registry.save_preset("CtxKit")
    registry.keybindings = {}
    assert(registry.load_preset("CtxKit"))

    local sc = registry.parse_shortcut("Cmd+X")
    local list = registry.keybindings[string.format("%d_%d", sc.key, sc.modifiers)]
    assert_equals("Cut restored", list[1].command_name, "Cut")
    assert_equals("context restored", list[1].contexts[1], "timeline")
    assert_equals("category restored", list[1].category, "Application")
end

-- Test 5: active-preset pointer is honored
local function test_active_pointer()
    setup()
    load_seed_toml()
    registry.save_preset("Chosen")
    registry.set_active_preset("Chosen")
    assert_equals("get matches set", registry.get_active_preset(), "Chosen")

    registry.set_active_preset(nil)
    assert_equals("cleared", registry.get_active_preset(), nil)
end

test_round_trip()
test_save_load_disk()
test_list_presets()
test_context_survives()
test_active_pointer()

print("✅ test_registry_disk_presets.lua passed")
