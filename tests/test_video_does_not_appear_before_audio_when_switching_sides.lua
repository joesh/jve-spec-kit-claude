#!/usr/bin/env luajit
-- T024 / FR-012 I2: audio-before-video invariant. On handover, the new
-- side's audio device is acquired BEFORE its CVDisplayLink starts.

require("test_env")
print("=== test_video_does_not_appear_before_audio_when_switching_sides.lua ===")

local setup = require("helpers.test_017_setup")
local call_log = {}
setup.install_qt_stub(call_log)
setup.fresh_project_db("test_017_t024.db")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
src:load("src")
require("helpers.transport_target_sim").target_source()

call_log = {}
-- Re-wire to capture the events of interest from a fresh log.
local qc = package.loaded["core.qt_constants"]
qc.AOP.START = function() call_log[#call_log+1] = "AOP.START" end
qc.PLAYBACK.PLAY = function() call_log[#call_log+1] = "PLAYBACK.PLAY" end
qc.PLAYBACK.ACTIVATE_AUDIO = function() call_log[#call_log+1] = "PLAYBACK.ACTIVATE_AUDIO" end

src:play()

-- I2: an audio start event (ACTIVATE_AUDIO or AOP.START) precedes
-- the PLAYBACK.PLAY (which kicks the CVDisplayLink frame pump).
local function first_index_of(events, prefix)
    for i, e in ipairs(events) do
        if e == prefix then return i end
    end
    return nil
end

local audio_at = first_index_of(call_log, "AOP.START")
    or first_index_of(call_log, "PLAYBACK.ACTIVATE_AUDIO")
local video_at = first_index_of(call_log, "PLAYBACK.PLAY")

assert(audio_at, "I2: expected an audio-acquire event; saw " .. table.concat(call_log, ","))
assert(video_at, "I2: expected PLAYBACK.PLAY; saw " .. table.concat(call_log, ","))
assert(audio_at < video_at, string.format(
    "FR-012 I2 audio-before-video: audio_at=%d video_at=%d log=%s",
    audio_at, video_at, table.concat(call_log, ",")))

print("✅ test_video_does_not_appear_before_audio_when_switching_sides.lua passed")
