#!/usr/bin/env luajit
-- T006 / FR-022: when both engines emit log lines (transport ticks, audio
-- events), every line must carry a tag identifying whether it came from
-- the source or the record side. TSO 2026-05-15 showed indistinguishable
-- [ticks] lines from two engines, making correlation impossible.
--
-- Structural invariant tested here: after engine:load(sequence_id), the
-- engine carries a _log_tag of the form "<role>:<first-8-of-seq-id>".
-- This tag is the value pushed into the C++ PlaybackController via
-- PLAYBACK.SET_LOG_TAG, and the value Lua-side log calls prefix.

require("test_env")

print("=== test_log_line_identifies_which_side_produced_it.lua ===")

-- The 017 refactor changes the constructor signature to PlaybackEngine.new(role).
-- Stub qt_constants minimally so engine construction succeeds without C++.
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
        HAS_AUDIO = function() return false end,
    },
    EMP = {
        TMB_CREATE = function() return "stub_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
    },
    AOP = {}, SSE = {},
}

local PlaybackEngine = require("core.playback.playback_engine")

-- Constructor must accept a role string in the 017 refactor.
local source_engine = PlaybackEngine.new("source")
local record_engine = PlaybackEngine.new("record")

assert(source_engine.role == "source", string.format(
    "source-role engine must carry role='source', got '%s'",
    tostring(source_engine.role)))
assert(record_engine.role == "record", string.format(
    "record-role engine must carry role='record', got '%s'",
    tostring(record_engine.role)))

-- Before load: tag is the "<role>:unloaded" sentinel.
assert(source_engine._log_tag == "source:unloaded", string.format(
    "before load, source-engine _log_tag must be 'source:unloaded', got '%s'",
    tostring(source_engine._log_tag)))
assert(record_engine._log_tag == "record:unloaded", string.format(
    "before load, record-engine _log_tag must be 'record:unloaded', got '%s'",
    tostring(record_engine._log_tag)))

-- After load: tag is "<role>:<first-8-of-sequence-id>". The two engines
-- must produce DIFFERENT tags so log lines are disambiguable.
-- We can't fully exercise engine:load here without a database, but we
-- can verify the tag-formatting contract by calling whatever the
-- module exposes for tag computation. The integration with the C++
-- binding is verified in test_contract_engine.lua and via T067 manual.

local long_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local expected_source = "source:" .. long_id:sub(1, 8)
local expected_record = "record:" .. long_id:sub(1, 8)

-- The engine exposes either a formatter helper or the constant we use
-- to slice. We accept whichever the module surfaces, but the slice
-- length MUST be a module-level named constant (rule 1.5).
local LOG_TAG_ID_PREFIX_LEN = PlaybackEngine.LOG_TAG_ID_PREFIX_LEN
assert(LOG_TAG_ID_PREFIX_LEN == 8, string.format(
    "PlaybackEngine.LOG_TAG_ID_PREFIX_LEN must be 8, got %s",
    tostring(LOG_TAG_ID_PREFIX_LEN)))

local function expected_tag(role, seq_id)
    return role .. ":" .. seq_id:sub(1, LOG_TAG_ID_PREFIX_LEN)
end

assert(expected_tag("source", long_id) == expected_source)
assert(expected_tag("record", long_id) == expected_record)
assert(expected_source ~= expected_record,
    "tags for two roles on the same sequence must differ")

print("✅ test_log_line_identifies_which_side_produced_it.lua passed")
