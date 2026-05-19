#!/usr/bin/env luajit
-- T033 / FR-027: pressing Space while the target engine has no loaded
-- sequence is a clean no-op at the command-dispatch layer. The engine's
-- play() must NEVER be reached with loaded_sequence_id == nil.

require("test_env")
print("=== test_pressing_space_with_nothing_loaded_does_nothing.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t033.db")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
assert(src.loaded_sequence_id == nil)

require("helpers.transport_target_sim").target_source()

-- Booby-trap engine.play so we can detect if it ever gets called.
local play_called = false
local orig_play = src.play
src.play = function(self) play_called = true; orig_play(self) end

local command_manager = require("core.command_manager")
command_manager.init("rec", "p")

local result = command_manager.execute("TogglePlay", { project_id = "p" })
assert(result and result.success == true, string.format(
    "FR-027: TogglePlay with empty target must succeed as no-op; got %s",
    tostring(result and result.error_message)))
assert(play_called == false, string.format(
    "FR-027: engine.play() must NOT be called when loaded_sequence_id is nil; "
    .. "command layer must filter before reaching the engine"))
assert(src.state == "stopped",
    "engine state must remain 'stopped'")

print("✅ test_pressing_space_with_nothing_loaded_does_nothing.lua passed")
