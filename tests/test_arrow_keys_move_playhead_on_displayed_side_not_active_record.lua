#!/usr/bin/env luajit
-- T031 / FR-020 movement-class: arrow keys / Home / End / mark commands
-- act on the displayed side (transport.engine_for_target().loaded_sequence_id),
-- never on the active record sequence when those differ.

require("test_env")
print("=== test_arrow_keys_move_playhead_on_displayed_side_not_active_record.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t031.db")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")
src:load("src"); rec:load("rec")
src:seek(50)
rec:seek(200)

local command_manager = require("core.command_manager")
command_manager.init("rec", "p")

-- Active sequence = 'rec' (the timeline). User clicks source tab — display
-- target is now 'source'.
require("helpers.transport_target_sim").target_source()

local result = command_manager.execute("MovePlayhead", { project_id = "p", _positional = { "1f" } })
assert(result and result.success, string.format(
    "MovePlayhead must succeed: %s", tostring(result and result.error_message)))

-- The source engine's position must advance; record's must not.
assert(src:get_position() == 51, string.format(
    "FR-020: movement key with target=source must move source-engine; got %s",
    tostring(src:get_position())))
assert(rec:get_position() == 200, string.format(
    "FR-020: record-engine must be untouched when target=source; got %s",
    tostring(rec:get_position())))

local Sequence = require("models.sequence")
assert(Sequence.load("src").playhead_position == 51,
    "MovePlayhead must persist position on source sequence row")

print("✅ test_arrow_keys_move_playhead_on_displayed_side_not_active_record.lua passed")
