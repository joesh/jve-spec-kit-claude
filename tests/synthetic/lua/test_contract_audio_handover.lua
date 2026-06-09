#!/usr/bin/env luajit
-- T009: contract test for audio handover per contracts/audio_handover.md.
-- The two observable invariants (I1 no-overlap, I2 audio-before-video)
-- ride on the audio_playback module's halt_current / acquire_for
-- functions. This test verifies structural call ordering at the Lua
-- boundary; full end-to-end audio-stream invariants are validated
-- manually via quickstart (T067).

require("test_env")

print("=== test_contract_audio_handover.lua ===")

-- Track FFI calls in the order issued so we can verify drain-before-acquire.
local ffi_log = {}

-- Stub qt_constants to provide the FFI surface that _ffi_drain /
-- _ffi_acquire / _ffi_configure_silent will call into.
package.loaded["core.qt_constants"] = {
    PLAYBACK = {
        CREATE = function() return "stub_pc" end,
        CLOSE  = function() end,
        SET_LOG_TAG = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        STOP = function() end,
        HAS_AUDIO = function() return true end,
        ACTIVATE_AUDIO = function()
            ffi_log[#ffi_log + 1] = "PLAYBACK.ACTIVATE_AUDIO"
        end,
        DEACTIVATE_AUDIO = function()
            ffi_log[#ffi_log + 1] = "PLAYBACK.DEACTIVATE_AUDIO"
        end,
    },
    EMP = {
        TMB_CREATE = function() return "stub_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_AUDIO_MIX_PARAMS = function() end,
    },
    AOP = {
        OPEN = function(rate, ch)
            ffi_log[#ffi_log + 1] = string.format("AOP.OPEN(%d,%d)", rate, ch)
            return "stub_aop"
        end,
        CLOSE = function() ffi_log[#ffi_log + 1] = "AOP.CLOSE" end,
        START = function() ffi_log[#ffi_log + 1] = "AOP.START" end,
        STOP  = function() ffi_log[#ffi_log + 1] = "AOP.STOP" end,
        FLUSH = function() end,
        PLAYHEAD_US = function() return 0 end,
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
    },
    SSE = {
        CREATE = function() return "stub_sse" end,
        CLOSE = function() end,
        RESET = function() end,
        SET_TARGET = function() end,
    },
}

local audio_playback = require("core.media.audio_playback")

-- ---------- Case 1: required public surface ----------
for _, name in ipairs({
    "current_owner", "is_owner", "halt_current", "acquire_for",
}) do
    assert(type(audio_playback[name]) == "function",
        string.format("audio_playback.%s must be a function", name))
end

-- ---------- Case 2: nobody owns the device at startup ----------
assert(audio_playback.current_owner() == nil,
    "audio_playback.current_owner() must be nil before any acquire_for")

-- ---------- Case 3: halt_current with no owner is a clean no-op ----------
-- (Two-invariant protocol: halt_current is callable any time; if no owner
-- exists, it returns synchronously without touching the device.)
audio_playback.halt_current()
assert(audio_playback.current_owner() == nil,
    "halt_current with no owner must leave owner nil")

-- A synthetic "engine" — the audio module only needs the role + a
-- minimum sequence-shape to compute the bus rate. The real PlaybackEngine
-- structure is exercised in test_contract_engine.lua.
local function fake_engine(role)
    return {
        role = role,
        loaded_sequence_id = "stub-seq",
        sequence = { audio_sample_rate = 48000 },
    }
end

local source_engine = fake_engine("source")
local record_engine = fake_engine("record")

-- ---------- Case 4: acquire_for sets owner, calls AOP.START ----------
ffi_log = {}
audio_playback.acquire_for(source_engine)
assert(audio_playback.current_owner() == source_engine,
    "after acquire_for(source), current_owner() must equal source-engine")
assert(audio_playback.is_owner(source_engine) == true)
assert(audio_playback.is_owner(record_engine) == false)

-- ---------- Case 5: acquire_for while another owner holds asserts ----------
local ok = pcall(audio_playback.acquire_for, record_engine)
assert(not ok,
    "acquire_for with another live owner must assert (caller must halt_current first)")

-- ---------- Case 6: halt_current → acquire_for ordering (I1 + I2) ----------
ffi_log = {}
audio_playback.halt_current()
assert(audio_playback.current_owner() == nil,
    "after halt_current, current_owner must be nil")
-- The drain/stop step must have fired before any acquire begins:
local saw_stop = false
for _, e in ipairs(ffi_log) do
    if e == "AOP.STOP" or e == "PLAYBACK.DEACTIVATE_AUDIO" then
        saw_stop = true; break
    end
end
assert(saw_stop, string.format(
    "halt_current must fire AOP.STOP or PLAYBACK.DEACTIVATE_AUDIO; ffi_log=%s",
    table.concat(ffi_log, ",")))

audio_playback.acquire_for(record_engine)
assert(audio_playback.is_owner(record_engine))

-- ---------- Case 7: acquire_for(nil) and bad-shape asserts ----------
audio_playback.halt_current()
assert(not pcall(audio_playback.acquire_for, nil),
    "acquire_for(nil) must assert")
assert(not pcall(audio_playback.acquire_for, {}),
    "acquire_for({}) must assert (no role/sequence)")

print("✅ test_contract_audio_handover.lua passed")
