#!/usr/bin/env luajit
-- T030 / FR-020 transport-class: Space (TogglePlay) routes to the engine
-- for the user-selected transport target — not via focus or panel state.

require("test_env")
print("=== test_space_acts_on_the_side_user_just_clicked.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t030.db")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")
src:load("src"); rec:load("rec")

local command_manager = require("core.command_manager")
command_manager.init("rec", "p")

-- Click source tab → set transport target.
require("synthetic.helpers.transport_target_sim").target_source()
local r1 = command_manager.execute("TogglePlay", { project_id = "p" })
assert(r1 and r1.success, "TogglePlay must succeed")
assert(src.state == "playing", "FR-020: target=source → source engine plays")
assert(rec.state == "stopped", "FR-020: record engine must remain stopped")

-- Stop, then click record tab; Space drives record.
command_manager.execute("TogglePlay", { project_id = "p" })
require("synthetic.helpers.transport_target_sim").target_record()
command_manager.execute("TogglePlay", { project_id = "p" })
assert(rec.state == "playing", "FR-020: target=record → record engine plays")
assert(src.state == "stopped", "FR-020: source must be stopped now")

print("✅ test_space_acts_on_the_side_user_just_clicked.lua passed")
