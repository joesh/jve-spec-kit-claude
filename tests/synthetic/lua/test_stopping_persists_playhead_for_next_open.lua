#!/usr/bin/env luajit
-- T019 / FR-007: engine:stop() persists current position to sequences.playhead_position.

require("test_env")
print("=== test_stopping_persists_playhead_for_next_open.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t019.db")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
src:load("src")
src:seek(5000)

-- Simulate transition into 'playing' then stop (engine:stop semantics).
src.state = "playing"
src:stop()

local Sequence = require("models.sequence")
local seq = Sequence.load("src")
assert(seq.playhead_position == 5000, string.format(
    "FR-007: stop must persist position 5000 to model; got %s",
    tostring(seq.playhead_position)))

print("✅ test_stopping_persists_playhead_for_next_open.lua passed")
