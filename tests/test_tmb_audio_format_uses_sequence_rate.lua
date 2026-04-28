#!/usr/bin/env luajit
--- Regression: TMB audio format is configured at the sequence's audio
--- sample rate, not a hardcoded 48000. A sequence-rate mismatch forces
--- the SSE stretch engine to resample on every output buffer, costing
--- both correctness (extra interpolation) and performance.
---
--- Domain rule: the playback engine's TMB output rate IS the sequence's
--- audio_sample_rate — the same rate the SSE/AOP session opens at.
---
--- Pre-fix: `EMP.TMB_SET_AUDIO_FORMAT(self._tmb, 48000, 2)` (literal 48000).
--- Post-fix: `EMP.TMB_SET_AUDIO_FORMAT(self._tmb, self.audio_sample_rate, ...)`.
--- A nil/zero `audio_sample_rate` must fail-fast with an actionable assert
--- (rule 1.14) rather than silently passing junk to the C++ binding.
require("test_env")

-- Capture every TMB_SET_AUDIO_FORMAT invocation.
local tmb_audio_format_calls = {}

_G.qt_create_single_shot_timer = function() end
package.loaded["core.qt_constants"] = {
    EMP = {
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_SEQUENCE_RESOLUTION = function() end,
        TMB_SET_AUDIO_FORMAT = function(_tmb, sample_rate, channels)
            table.insert(tmb_audio_format_calls,
                { sample_rate = sample_rate, channels = channels })
        end,
        TMB_SET_TC_OVERRIDES = function() end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_pc" end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        CLOSE = function() end,
    },
}

package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

-- Minimal Media stub so PlaybackEngine doesn't need a real DB.
package.loaded["models.media"] = {
    find_tc_override_media = function() return {} end,
}

local PlaybackEngine = require("core.playback.playback_engine")

local function fresh_engine()
    tmb_audio_format_calls = {}
    return PlaybackEngine.new({
        on_show_frame   = function() end,
        on_show_gap     = function() end,
        on_set_rotation = function() end,
        on_set_par      = function() end,
        on_position_changed = function() end,
    })
end

-- =============================================================================
-- Test 1: 44.1kHz sequence configures TMB at 44.1kHz, not 48kHz.
-- =============================================================================
local engine = fresh_engine()
engine.fps_num = 24
engine.fps_den = 1
engine.audio_sample_rate = 44100
engine.sequence = { project_id = "p1", width = 1920, height = 1080 }
engine:_create_tmb()

assert(#tmb_audio_format_calls == 1, string.format(
    "_create_tmb must invoke TMB_SET_AUDIO_FORMAT exactly once; got %d",
    #tmb_audio_format_calls))
local call = tmb_audio_format_calls[1]
assert(call.sample_rate == 44100, string.format(
    "TMB output rate must match sequence's audio_sample_rate; expected 44100, "
    .. "got %s — hardcoded 48000 forces a needless resample at SSE for non-48k "
    .. "sequences", tostring(call.sample_rate)))

-- =============================================================================
-- Test 2: 48kHz sequence still works (sanity — fix doesn't break the common case).
-- =============================================================================
engine = fresh_engine()
engine.fps_num = 24
engine.fps_den = 1
engine.audio_sample_rate = 48000
engine.sequence = { project_id = "p1", width = 1920, height = 1080 }
engine:_create_tmb()

assert(tmb_audio_format_calls[1].sample_rate == 48000, string.format(
    "48kHz sequence must configure TMB at 48000; got %s",
    tostring(tmb_audio_format_calls[1].sample_rate)))

-- =============================================================================
-- Test 3: missing audio_sample_rate fails fast (rule 1.14: no silent default).
-- =============================================================================
engine = fresh_engine()
engine.fps_num = 24
engine.fps_den = 1
engine.audio_sample_rate = nil
engine.sequence = { project_id = "p1", width = 1920, height = 1080 }
local ok, err = pcall(function() engine:_create_tmb() end)
assert(not ok, "missing audio_sample_rate must fail fast, not silently default")
assert(tostring(err):find("audio_sample_rate"), string.format(
    "assertion message must mention audio_sample_rate for diagnosis; got %s",
    tostring(err)))

-- =============================================================================
-- Test 4: zero audio_sample_rate fails fast (rule 1.14).
-- =============================================================================
engine = fresh_engine()
engine.fps_num = 24
engine.fps_den = 1
engine.audio_sample_rate = 0
engine.sequence = { project_id = "p1", width = 1920, height = 1080 }
ok, err = pcall(function() engine:_create_tmb() end)
assert(not ok, "zero audio_sample_rate must fail fast")
assert(tostring(err):find("audio_sample_rate"), string.format(
    "assertion message must mention audio_sample_rate; got %s", tostring(err)))

print("\n✅ test_tmb_audio_format_uses_sequence_rate.lua passed")
