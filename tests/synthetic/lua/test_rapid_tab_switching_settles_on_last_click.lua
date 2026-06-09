#!/usr/bin/env luajit
-- T013 / FR-009a: rapid target changes coalesce to the last value without
-- firing an audio handover. Under the derived-target redesign there is no
-- explicit target write at all — target is a pure projection of UI state.
-- The invariant restated: simply DERIVING the target (e.g., a burst of
-- get_target() calls as UI state flips) must never touch the audio device.

require("test_env")
print("=== test_rapid_tab_switching_settles_on_last_click.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t013.db")

local audio_playback = require("core.media.audio_playback")
local halt_count, acquire_count = 0, 0
local original_halt = audio_playback.halt_current
local original_acq  = audio_playback.acquire_for
audio_playback.halt_current = function(...) halt_count = halt_count + 1; return original_halt(...) end
audio_playback.acquire_for  = function(...) acquire_count = acquire_count + 1; return original_acq(...) end

local transport = require("core.playback.transport")
transport.init("p")

local sim = require("synthetic.helpers.transport_target_sim")
halt_count, acquire_count = 0, 0

-- Eight rapid UI flips in one Lua thread; observe target through get_target()
-- on every flip. Last call wins.
for _, role in ipairs({"record","source","record","source","record","source","record","source"}) do
    if role == "source" then sim.target_source() else sim.target_record() end
    local _ = transport.get_target()
end

assert(transport.get_target() == "source",
    "after rapid UI flips, get_target() must equal the LAST state 'source'")

-- Critical invariant: deriving the target never touches the audio device.
assert(halt_count == 0, string.format(
    "FR-009a: get_target() must NOT trigger audio.halt_current; saw %d calls",
    halt_count))
assert(acquire_count == 0, string.format(
    "FR-009a: get_target() must NOT trigger audio.acquire_for; saw %d calls",
    acquire_count))

transport.shutdown()
require("core.database").shutdown()
print("✅ test_rapid_tab_switching_settles_on_last_click.lua passed")
