#!/usr/bin/env luajit
--- Regression: `PlaybackEngine:seek(frame)` MUST fail fast in Lua with a
--- named-context assert when `frame < self.start_frame`. Without this,
--- bad callers crash in the C++ PlaybackController::Park assertion
--- (`frame >= m_start_frame`) which has a less actionable stack and no
--- Lua context (which engine? which sequence? which caller path?).
---
--- Live symptom (TSO 2026-05-17 09:38:48): on a sequence with
--- `SetBounds [89750, 204140)` (TC origin = 89750), a deferred Park via
--- single_shot_timer fired with a frame value somewhere below 89750
--- (most likely `data.state.playhead_position` got transiently set to a
--- raw DB value, 0 from core.clear, or a SetPlayhead command with
--- pre-clamp frame). The C++ assert fired with no Lua-side context.
---
--- The Lua-side assert this test pins names the engine role, loaded
--- sequence id, attempted frame, and required start_frame — so a
--- developer reading the crash can identify the bad caller path
--- without spelunking C++.

require("test_env")

print("=== test_engine_seek_asserts_below_start_frame.lua ===")

package.loaded["core.qt_constants"] = {
    PLAYBACK = {
        CREATE = function() return "stub_pc" end,
        CLOSE = function() end,
        SET_LOG_TAG = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        PARK = function()
            error("PARK called — Lua-side assert should have fired first",
                  2)
        end,
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

-- Build a minimal engine with start_frame > 0 (sequence with TC origin),
-- bypassing real sequence load. The seek path only reads start_frame,
-- fps_num/fps_den, sequence, and _playback_controller.
local engine = PlaybackEngine.new("record", {
    on_show_frame = function() end,
    on_show_gap = function() end,
    on_set_rotation = function() end,
    on_set_par = function() end,
    on_position_changed = function() end,
})
engine.start_frame = 89750
engine.fps_num = 25
engine.fps_den = 1
engine.sequence = { id = "fake_seq" }
engine.loaded_sequence_id = "fake_seq"
engine._playback_controller = "stub_pc"

-- ── Case 1: seek with frame < start_frame asserts in Lua ──
local ok, err = pcall(function() engine:seek(0) end)
assert(not ok, "seek(0) when start_frame=89750 must assert in Lua, not "
    .. "fall through to C++ Park")
local err_str = tostring(err)
assert(err_str:find("start_frame") or err_str:find("89750"),
    string.format("assert message must name start_frame or its value (89750) "
        .. "so the bad caller is identifiable; got: %s", err_str))
print("  ✓ seek(0) with start_frame=89750 asserts with named context")

-- ── Case 2: seek with frame == start_frame passes ──
-- (boundary value is legal: park at the first frame of content)
engine._last_committed_frame = nil  -- ensure not deduped
local ok2, err2 = pcall(function() engine:seek(89750) end)
assert(ok2 or not tostring(err2):find("start_frame"), string.format(
    "seek(start_frame=89750) must NOT trip the start_frame assert; "
    .. "got: %s", tostring(err2)))
print("  ✓ seek(start_frame) passes the start_frame gate")

-- ── Case 3: seek with frame > start_frame passes the start_frame gate ──
engine._last_committed_frame = nil
local ok3, err3 = pcall(function() engine:seek(122559) end)
assert(ok3 or not tostring(err3):find("start_frame"), string.format(
    "seek(122559) with start_frame=89750 must NOT trip the start_frame "
    .. "assert; got: %s", tostring(err3)))
print("  ✓ seek above start_frame passes the gate")

print("\n✅ test_engine_seek_asserts_below_start_frame.lua passed")
