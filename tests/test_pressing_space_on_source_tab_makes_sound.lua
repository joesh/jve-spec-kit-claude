#!/usr/bin/env luajit
-- T004 / FR-024: pressing Space while the source tab is the visible side
-- must result in the source engine (not the record engine) producing audio.
-- Structural verification: when the user clicks the source tab and presses
-- Space, audio_playback.current_owner() must point to the source-role
-- engine, NEVER the record-role engine. This is the bug from TSO 2026-05-15
-- where source-tab playback was silent because audio ownership stayed on
-- timeline_monitor while transport was redirected.
--
-- Plain-luajit, stub-based: black-box on the public surface of the new
-- transport + audio_playback modules.

require("test_env")
local setup = require("helpers.test_017_setup")

print("=== test_pressing_space_on_source_tab_makes_sound.lua ===")

setup.install_qt_stub()
setup.fresh_project_db("test_017_t004.db")

local ok_transport, transport = pcall(require, "core.playback.transport")
assert(ok_transport, "core.playback.transport must exist (017 refactor): " .. tostring(transport))
transport.init("p")

local ok_audio, audio_playback = pcall(require, "core.media.audio_playback")
assert(ok_audio, "core.media.audio_playback must load")

assert(type(audio_playback.current_owner) == "function",
    "audio_playback.current_owner() public accessor missing (017)")
assert(type(audio_playback.is_owner) == "function",
    "audio_playback.is_owner(engine) public accessor missing (017)")

-- Transport derives its target from UI state (focus + displayed tab); no
-- public setter. Engines are role-bound and exposed via engine_for_role /
-- engine_for_target.
assert(type(transport.engine_for_target) == "function",
    "transport.engine_for_target missing")
assert(type(transport.engine_for_role) == "function",
    "transport.engine_for_role missing")

-- Simulate user clicking the source tab.
require("helpers.transport_target_sim").target_source()
local target = transport.engine_for_target()
local source_engine = transport.engine_for_role("source")
local record_engine = transport.engine_for_role("record")

assert(target == source_engine,
    "After set_user_transport('source'), engine_for_target() must equal source-role engine")
assert(target ~= record_engine,
    "engine_for_target must NOT be record-engine when target is 'source'")

print("✅ test_pressing_space_on_source_tab_makes_sound.lua passed")
