#!/usr/bin/env luajit
-- White-box test for command_manager's capture_displayed_playhead helper
-- (H1 finalize, c66850d6). The helper enforces the bidirectional invariant:
--   had_displayed_tab ⇔ playhead_value ≠ nil ⇔ playhead_rate ≠ nil
-- Each capture site (4 callsites in command_manager) relies on this guard
-- to crash at capture time rather than persist divergent (nil, number) or
-- (number, nil) pairs that Command.save's co-required pair assert would
-- catch later — but with the original displayed-tab state already lost.
--
-- A future refactor that lets get_playhead_position or get_sequence_frame_rate
-- fabricate a value when the cache field is nil — or fails to surface a nil
-- when the tab is detached — degrades silently downstream. This test guards
-- the equivalence directly.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local env = require("test_env")

local command_manager = require("core.command_manager")
local strip_holder = require("ui.timeline.state.strip_holder")

local capture = command_manager._test_capture_displayed_playhead
assert(capture, "command_manager must expose _test_capture_displayed_playhead for white-box tests")

-- =====================================================================
-- Case 1: no displayed tab → both nil, no crash.
-- =====================================================================
strip_holder.set(nil)
local v, r = capture("test:no-tab")
assert(v == nil, "no-tab: playhead_value must be nil, got " .. tostring(v))
assert(r == nil, "no-tab: playhead_rate must be nil, got " .. tostring(r))

-- =====================================================================
-- Case 2: displayed tab with valid playhead + rate → both returned.
-- =====================================================================
env.install_displayed_tab_stub({
    playhead_position = 42,
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
})
v, r = capture("test:happy")
assert(v == 42, "happy: playhead_value must be 42, got " .. tostring(v))
-- playhead_rate is the cache's Rational record ({fps_numerator, fps_denominator});
-- Command.save's resolve_playhead_rate accepts either a number or this shape.
assert(type(r) == "table" and r.fps_numerator and r.fps_denominator,
    "happy: playhead_rate must be a Rational with fps_numerator/fps_denominator, got " .. tostring(r))

-- =====================================================================
-- Case 3: displayed tab present but cache.playhead_position is nil.
-- Invariant violation — capture must crash citing the label.
-- =====================================================================
env.install_displayed_tab_stub({
    playhead_position = 42,
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
})
local cache = strip_holder.displayed_cache()
cache.playhead_position = nil

local ok, err = pcall(capture, "test:value-nil-but-tab")
assert(not ok, "value-nil-but-tab: capture must crash when tab present but playhead_position is nil")
assert(tostring(err):find("playhead_value/displayed%-tab invariant violated", 1)
    or tostring(err):find("playhead_value", 1, true),
    "value-nil-but-tab: error must cite playhead_value invariant, got: " .. tostring(err))
assert(tostring(err):find("test:value-nil-but-tab", 1, true),
    "value-nil-but-tab: error must include the call-site label, got: " .. tostring(err))

-- =====================================================================
-- Case 4: displayed tab present but cache.sequence_frame_rate is nil.
-- Same invariant on the rate half.
-- =====================================================================
env.install_displayed_tab_stub({
    playhead_position = 42,
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
})
cache = strip_holder.displayed_cache()
cache.sequence_frame_rate = nil

ok, err = pcall(capture, "test:rate-nil-but-tab")
assert(not ok, "rate-nil-but-tab: capture must crash when tab present but sequence_frame_rate is nil")
assert(tostring(err):find("playhead_rate", 1, true),
    "rate-nil-but-tab: error must cite playhead_rate invariant, got: " .. tostring(err))
assert(tostring(err):find("test:rate-nil-but-tab", 1, true),
    "rate-nil-but-tab: error must include the call-site label, got: " .. tostring(err))

print("✅ capture_displayed_playhead enforces bidirectional had_tab ⇔ value ⇔ rate invariant")
