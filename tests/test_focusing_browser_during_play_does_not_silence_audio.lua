#!/usr/bin/env luajit
-- T015 / FR-009: focus changes do NOT affect audio ownership.
-- Today's focus_change handler in layout.lua calls activate/deactivate_audio
-- on monitor engines. After 017 that block is deleted: focus is purely
-- input routing.

require("test_env")
print("=== test_focusing_browser_during_play_does_not_silence_audio.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t015.db")

local audio_playback = require("core.media.audio_playback")
local transport = require("core.playback.transport")
transport.init("p")

-- Make the record engine the "current owner" of audio. acquire_for asserts
-- the engine has a loaded sequence; load before acquiring.
local rec = transport.engine_for_role("record")
rec:load("rec")
audio_playback.acquire_for(rec)
local owner_before = audio_playback.current_owner()
assert(owner_before == transport.engine_for_role("record"))

-- Fire focus_change signal (project browser focused).
local Signals = require("core.signals")
Signals.emit("focus_change", "timeline", "project_browser")

local owner_after = audio_playback.current_owner()
assert(owner_after == owner_before, string.format(
    "FR-009: focus change must NOT alter audio ownership; "
    .. "owner changed from %s to %s",
    tostring(owner_before), tostring(owner_after)))

print("✅ test_focusing_browser_during_play_does_not_silence_audio.lua passed")
