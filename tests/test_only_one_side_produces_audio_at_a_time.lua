#!/usr/bin/env luajit
-- T026 / FR-011: at most one engine owns the audio device at any moment.

require("test_env")
print("=== test_only_one_side_produces_audio_at_a_time.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t026.db")

local transport = require("core.playback.transport")
local audio_playback = require("core.media.audio_playback")
transport.init("p")
local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")
src:load("src"); rec:load("rec")

assert(audio_playback.current_owner() == nil, "no owner before any play")

src:play()
assert(audio_playback.is_owner(src), "src owns after src:play")
assert(audio_playback.is_owner(rec) == false, "rec must not co-own")

src:stop()
assert(audio_playback.current_owner() == nil, "stop releases ownership")

rec:play()
assert(audio_playback.is_owner(rec), "rec owns after rec:play")
assert(audio_playback.is_owner(src) == false, "src must not co-own")

print("✅ test_only_one_side_produces_audio_at_a_time.lua passed")
