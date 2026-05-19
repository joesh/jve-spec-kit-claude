#!/usr/bin/env luajit

-- Regression: at small audio track heights the renderer reserved 16 px at
-- the clip bottom for the label and gave the rest to the waveform. Once
-- clip_height-LABEL_RESERVE dropped near zero, the wave was squeezed to a
-- 4 px strip pinned to the TOP of the clip (Joe 2026-05-14). NLE convention
-- is to drop the label at tight heights and let the wave use the full clip
-- body so it draws centred on the clip's midline.

require("test_env")
local layout = require("ui.timeline.view.waveform_layout")

print("=== test_waveform_layout_small_track.lua ===")

local LABEL = layout.LABEL_RESERVE
local MIN_WAVE = layout.MIN_WAVE_HEIGHT

-- ── Tall clip: label visible, wave sits in upper area ────────────────────
do
    local wy, wh, label = layout.compute(80)
    assert(wy == 0, "tall: wave_y should be 0; got " .. wy)
    assert(wh == 80 - LABEL, string.format(
        "tall: wave_height should be clip - label = %d; got %d", 80 - LABEL, wh))
    assert(label == true, "tall: label must be visible")
end

-- ── Small clip: label hidden, wave fills body and draws centred ──────────
do
    local clip_h = 20  -- 20 - 16 = 4, well under MIN_WAVE_HEIGHT
    local wy, wh, label = layout.compute(clip_h)
    assert(label == false, string.format(
        "FAIL: at clip_height=%d the label must be suppressed so the wave "
        .. "isn't squashed; got label_visible=%s", clip_h, tostring(label)))
    assert(wh == clip_h, string.format(
        "FAIL: at clip_height=%d the wave must fill the whole clip body so "
        .. "it draws centred on the clip midline; expected wave_height=%d, got %d. "
        .. "Pre-fix this returned clip_height-label_reserve, leaving the wave "
        .. "stuck at the top of the clip.",
        clip_h, clip_h, wh))
    assert(wy == 0, "small: wave_y should be 0 (full-body); got " .. wy)
end

-- ── Boundary: just above and just below MIN_WAVE_HEIGHT ──────────────────
do
    -- Just enough room: label kept.
    local _, wh_ok, label_ok = layout.compute(MIN_WAVE + LABEL)
    assert(label_ok == true and wh_ok == MIN_WAVE,
        string.format("boundary+: expected label kept, wave=%d; got label=%s wave=%d",
            MIN_WAVE, tostring(label_ok), wh_ok))
    -- One pixel short: label dropped.
    local _, wh_tight, label_tight = layout.compute(MIN_WAVE + LABEL - 1)
    assert(label_tight == false and wh_tight == MIN_WAVE + LABEL - 1,
        "boundary-: label must be dropped one px below the threshold")
end

-- ── Error paths surface explicitly ───────────────────────────────────────
local ok = pcall(layout.compute, 0)
assert(not ok, "zero clip_height must assert")
local ok_neg = pcall(layout.compute, -5)
assert(not ok_neg, "negative clip_height must assert")

print("  layout collapses to centred-full-body below threshold — OK")
print("\n✅ test_waveform_layout_small_track.lua passed")
