#!/usr/bin/env luajit
-- T020 / FR-007a: during play, the engine writes its position to the
-- Model row at most once per second (throttled). After a hypothetical
-- crash, the persisted playhead is ≤1s behind the live position.

require("test_env")
print("=== test_crash_during_play_recovers_within_one_second.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t020.db")

-- Controllable monotonic clock.
local fake_now = 1000.0
_G.qt_monotonic_s = function() return fake_now end

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
src:load("src")
src.state = "playing"

local Sequence = require("models.sequence")

-- Engine exposes a throttled-writeback tick called by the play loop.
assert(type(src._throttled_writeback) == "function" or type(src.throttled_writeback) == "function",
    "engine must expose a throttled-writeback tick for FR-007a")
local tick = src.throttled_writeback or src._throttled_writeback

-- t=0: position 25, first tick writes through.
src._position = 25
tick(src)
assert(Sequence.load("src").playhead_position == 25,
    "first throttled tick must write position 25")

-- Same second: position 50; throttle drops it.
src._position = 50
tick(src)
assert(Sequence.load("src").playhead_position == 25, string.format(
    "FR-007a: writeback within same second must be dropped (frame remains 25); got %s",
    tostring(Sequence.load("src").playhead_position)))

-- Advance ≥1s, tick again with position 100 — must write through.
fake_now = fake_now + 1.001
src._position = 100
tick(src)
assert(Sequence.load("src").playhead_position == 100, string.format(
    "FR-007a: after ≥1s, throttled tick must write position 100; got %s",
    tostring(Sequence.load("src").playhead_position)))

print("✅ test_crash_during_play_recovers_within_one_second.lua passed")
