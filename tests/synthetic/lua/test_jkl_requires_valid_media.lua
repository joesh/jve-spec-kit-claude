require('test_env')

-- Tests that playback command executors handle missing/invalid media gracefully
-- (not crash when no sequence loaded)

print("=== Test JKL Requires Valid Media ===")

-- Track playback calls
local shuttle_called

-- Mock engine (017: target engine comes from transport.engine_for_target)
local mock_engine = { loaded_sequence_id = nil }
function mock_engine:is_playing() return false end
function mock_engine:play() end
function mock_engine:stop() end
function mock_engine:shuttle(dir) shuttle_called = true end
function mock_engine:slow_play(dir) end

-- Mock transport — singletons-style surface used by command executors.
-- _project_id non-nil means transport is bootstrapped; loaded_sequence_id
-- nil on the engine means "no sequence loaded yet".
package.loaded["core.playback.transport"] = {
    _project_id = "p",
    is_bootstrapped = function() return true end,
    bound_project_id = function() return "p" end,
    engine_for_target = function() return mock_engine end,
}

-- Load playback command module and register executors
local playback_mod = require("core.commands.playback")
local executors = {}
local undoers = {}
local registered = playback_mod.register(executors, undoers, nil)

-- Extract executor from registration
local shuttle_fwd = registered.ShuttleForward.executor
assert(shuttle_fwd, "ShuttleForward executor should be registered")

-- Mock command object (executors receive a command object)
local mock_command = {
    get_all_parameters = function() return {} end,
    set_parameter = function() end,
}

print("\nTest 1: L with no sequence loaded should silently return (not crash)")
shuttle_called = false
local ok, err = pcall(shuttle_fwd, mock_command)
assert(ok, "Executor should NOT crash when no sequence loaded, got: " .. tostring(err))
assert(not shuttle_called, "shuttle should not have been called")
print("  ✓ Silently returns when no sequence loaded")

print("\nTest 2: L with sequence loaded should call shuttle")
mock_engine.loaded_sequence_id = "test_seq"
shuttle_called = false

ok, err = pcall(shuttle_fwd, mock_command)
assert(ok, "Executor should succeed when sequence loaded, got: " .. tostring(err))
assert(shuttle_called, "shuttle should have been called")
print("  ✓ shuttle called when sequence loaded")

print("\nTest 3: K sets k_held, then K+L triggers slow_play")
local slow_play_called
function mock_engine:slow_play(dir) slow_play_called = true end

local shuttle_stop = registered.ShuttleStop.executor
shuttle_stop(mock_command)  -- K press sets k_held
assert(playback_mod.is_k_held(), "k_held should be true after ShuttleStop")

shuttle_called = false
slow_play_called = false
shuttle_fwd(mock_command)  -- L while k_held → slow_play
assert(slow_play_called, "K+L should trigger slow_play")
assert(not shuttle_called, "K+L should not trigger shuttle")
print("  ✓ K+L triggers slow_play instead of shuttle")

-- Clean up k_held state
playback_mod.set_k_held(false)

print("\n✅ test_jkl_requires_valid_media.lua passed")
