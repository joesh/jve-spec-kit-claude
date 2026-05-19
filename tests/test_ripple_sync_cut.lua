#!/usr/bin/env luajit

-- 015 — sync_mode='cut' shrink-trim: splits spanning clip; right half
-- preserves its original TC.
--
-- Per spec F3 cut should equal "split + ripple per current ripple rules",
-- but on shrink-trim of a clip that spans the trim point, rippling the
-- right half backward overlaps the left half it was just split from.
-- The current implementation preserves TC on the split right half as a
-- workaround until that design question is resolved.
--
-- Concrete setup (non-trivial, non-zero values):
--   Dialog V1  (ripple): [0, 100). Trim right edge by -30 → [0, 70).
--   Music  A1  (cut):    [40, 200), source_in=2000 (rate=1000, no mismatch).
--     spans trim point 100.
--   After cut dispatch:
--     Left  music: [40, 100), duration=60, source_in=2000, source_out=2060.
--     Right music: [100, 200), duration=100, source_in=2060, source_out=2160.
--                  (TC preserved — does NOT ripple)

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_ripple_sync_cut.lua ===")

local TRIM_POINT = 100    -- dialog clip right edge before trim
local DELTA      = 30     -- ripple delta (negative: trim shortens clip)
local MUSIC_START   = 40
local MUSIC_SOURCE  = 2000  -- non-trivial BWF-style source_in

local layout = ripple_layout.create({
    db_path         = "/tmp/jve/test_ripple_sync_cut.db",
    fps_numerator   = 1000,
    fps_denominator = 1,
    tracks = {
        order = {"v1", "a1"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
    },
    media = { main = { audio_channels=2 } },
    clips = {
        order = {"c_dialog", "c_music"},
        c_dialog = {id="c_dialog", track_key="v1", media_key="main",
                    sequence_start=0,          duration=TRIM_POINT,
                    source_in=500,
                    fps_numerator=1000, fps_denominator=1},
        c_music  = {id="c_music",  track_key="a1", media_key="main",
                    sequence_start=MUSIC_START, duration=160,
                    source_in=MUSIC_SOURCE,
                    fps_numerator=1000, fps_denominator=1},
    },
})

local db = database.get_connection()

-- Set sync_mode. FAIL here if migration not applied.
local ok_rip = db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id='trk_v1'")
assert(ok_rip, "FAIL: tracks.sync_mode column missing — migration not applied")
local ok_cut = db:exec("UPDATE tracks SET sync_mode='cut' WHERE id='trk_a1'")
assert(ok_cut, "UPDATE cut-track sync_mode failed")
print("  sync_mode set: V1=ripple, A1=cut")

-- ── Execute the ripple trim ───────────────────────────────────────────────
local r = command_manager.execute("RippleTrimEdge", {
    sequence_id  = layout.sequence_id,
    clip_id      = "c_dialog",
    edge         = "right",
    delta_frames = -DELTA,
    project_id   = layout.project_id,
})
assert(r and r.success,
    "RippleTrimEdge failed: " .. tostring(r and r.error_message))

-- ── Find the two resulting music clips (left=c_music, right=new UUID) ─────
local function clips_on_track(track_id)
    local s = db:prepare([[
        SELECT id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM clips WHERE track_id = ?
        ORDER BY sequence_start_frame
    ]])
    assert(s)
    s:bind_value(1, track_id); s:exec()
    local out = {}
    while s:next() do
        out[#out+1] = {
            id  = s:value(0),
            ts  = s:value(1),
            dur = s:value(2),
            sin = s:value(3),
            sout= s:value(4),
        }
    end
    s:finalize()
    return out
end

local music_clips = clips_on_track("trk_a1")
assert(#music_clips == 2, string.format(
    "FAIL: music track has %d clip(s) after cut-ripple — expected 2 (split at trim point %d)",
    #music_clips, TRIM_POINT))
print("  music track split into 2 clips — OK")

local left  = music_clips[1]
local right = music_clips[2]

-- ── Left half: [MUSIC_START, TRIM_POINT) ─────────────────────────────────
local exp_left_dur = TRIM_POINT - MUSIC_START   -- 60
assert(left.ts == MUSIC_START, string.format(
    "FAIL: left music sequence_start=%d, expected %d", left.ts, MUSIC_START))
assert(left.dur == exp_left_dur, string.format(
    "FAIL: left music duration=%d, expected %d", left.dur, exp_left_dur))
assert(left.dur >= 1, "FAIL: left music clip is sub-frame (duration < 1)")
print(string.format("  left: ts=%d dur=%d — OK", left.ts, left.dur))

-- ── Right half: preserves TC at TRIM_POINT (current workaround) ─────────
-- See header docstring for the design question still open.
local exp_right_ts  = TRIM_POINT          -- 100 (TC preserved)
local exp_right_dur = 160 - exp_left_dur  -- 100
assert(right.ts == exp_right_ts, string.format(
    "FAIL: right music sequence_start=%d, expected %d", right.ts, exp_right_ts))
assert(right.dur == exp_right_dur, string.format(
    "FAIL: right music duration=%d, expected %d", right.dur, exp_right_dur))
assert(right.dur >= 1, "FAIL: right music clip is sub-frame")
print(string.format("  right: ts=%d dur=%d — OK (TC preserved)", right.ts, right.dur))

-- ── Source continuity: no dropped or duplicated frames ───────────────────
-- Left source_out must equal right source_in (contiguous source content).
-- At 1000fps identity (no mismatch): source_out = source_in + duration.
local exp_left_sout  = MUSIC_SOURCE + exp_left_dur   -- 2060
local exp_right_sin  = exp_left_sout                 -- 2060
assert(left.sout == exp_left_sout, string.format(
    "FAIL: left source_out=%d, expected %d", left.sout, exp_left_sout))
assert(right.sin == exp_right_sin, string.format(
    "FAIL: right source_in=%d, expected %d — source discontinuity at split",
    right.sin, exp_right_sin))
assert(left.sout == right.sin, string.format(
    "FAIL: source discontinuity — left.source_out=%d != right.source_in=%d",
    left.sout, right.sin))
print(string.format("  source contiguous: left.sout=%d == right.sin=%d — OK",
    left.sout, right.sin))

print("\n✅ test_ripple_sync_cut.lua passed")
