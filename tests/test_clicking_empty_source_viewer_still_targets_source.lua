#!/usr/bin/env luajit
-- T012 / FR-027a: clicking an empty source viewer still moves the transport
-- target to "source"; subsequent TogglePlay is a clean no-op (no error).

require("test_env")
print("=== test_clicking_empty_source_viewer_still_targets_source.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t012.db")

local transport = require("core.playback.transport")
transport.init("p")

require("helpers.transport_target_sim").target_source()
assert(transport.get_target() == "source")

local src = transport.engine_for_target()
assert(src.loaded_sequence_id == nil, string.format(
    "source engine must have no loaded sequence before any user load (got %s)",
    tostring(src.loaded_sequence_id)))

-- Press Space (TogglePlay) via the command dispatcher. With nothing loaded
-- on the target engine, the command-layer guard makes this a clean no-op.
local command_manager = require("core.command_manager")
command_manager.init("rec", "p")

local result = command_manager.execute("TogglePlay", { project_id = "p" })
assert(result and result.success == true, string.format(
    "FR-027: TogglePlay on empty target must succeed as no-op; got success=%s err=%s",
    tostring(result and result.success), tostring(result and result.error_message)))
assert(src.state == "stopped",
    "engine state must remain 'stopped' after Space-with-nothing-loaded")

transport.shutdown()
require("core.database").shutdown()
print("✅ test_clicking_empty_source_viewer_still_targets_source.lua passed")
