#!/usr/bin/env luajit

-- T012 (015) — FR-026 Off-branch: sync_mode='off' tracks are immune to ripple.
--
-- Domain: when a track's sync_mode is 'off', a ripple edit on another track
-- must not shift any clips on the off-track. All other tracks (sync_mode='ripple')
-- must shift normally by the ripple delta.
--
-- Expected FAIL today: tracks.sync_mode column does not exist (migration not applied).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database   = require("core.database")
local command_manager = require("core.command_manager")
local ripple_layout = require("synthetic.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_ripple_sync_off.lua ===")

-- ── Fixture: 3 tracks, track_2 is 'off', others are 'ripple' ─────────────
-- Timeline (1000fps, non-trivial):
--   V1 (ripple): clip at [0, 100)
--   A1 (off):    clip at [0, 100) — must NOT shift
--   A2 (ripple): clip at [0, 100) — must shift by N
-- Ripple-delete N=30 frames from V1's clip.
-- Expected: V1 clip shrinks; A2 downstream clips shift -30; A1 unchanged.

local DELTA = 30   -- non-trivial, non-zero

local layout = ripple_layout.create({
    db_path       = "/tmp/jve/test_ripple_sync_off.db",
    fps_numerator = 1000,
    fps_denominator = 1,
    tracks = {
        order = {"v1", "a1", "a2"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        a2 = {id="trk_a2", name="A2", track_type="AUDIO", track_index=2, enabled=1},
    },
    media = {
        -- Override the default 'main' key to add audio channels.
        main = { audio_channels=2 },
    },
    clips = {
        order = {"c_v1", "c_a1_front", "c_a1_back", "c_a2_front", "c_a2_back"},
        -- V1: one clip at [0,100) — we'll ripple-trim its right edge back
        c_v1       = {id="c_v1",  name="V1",  track_key="v1", media_key="main",
                      sequence_start=0,   duration=100, source_in=500, fps_numerator=1000, fps_denominator=1},
        -- A1 (off): two clips so we can verify downstream position unchanged
        c_a1_front = {id="c_a1f", name="A1f", track_key="a1", media_key="main",
                      sequence_start=0,   duration=60,  source_in=500, fps_numerator=1000, fps_denominator=1},
        c_a1_back  = {id="c_a1b", name="A1b", track_key="a1", media_key="main",
                      sequence_start=100, duration=100, source_in=600, fps_numerator=1000, fps_denominator=1},
        -- A2 (ripple): similar layout — back clip must shift by -DELTA
        c_a2_front = {id="c_a2f", name="A2f", track_key="a2", media_key="main",
                      sequence_start=0,   duration=60,  source_in=500, fps_numerator=1000, fps_denominator=1},
        c_a2_back  = {id="c_a2b", name="A2b", track_key="a2", media_key="main",
                      sequence_start=100, duration=100, source_in=600, fps_numerator=1000, fps_denominator=1},
    },
})

local db = database.get_connection()

-- Set sync_mode on tracks.
-- This will FAIL if the migration hasn't added the sync_mode column.
local ok_off = db:exec("UPDATE tracks SET sync_mode='off' WHERE id='trk_a1'")
assert(ok_off, "FAIL: tracks.sync_mode column missing — migration not applied")
local ok_rip = db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id IN ('trk_v1','trk_a2')")
assert(ok_rip, "UPDATE ripple tracks failed")
print("  sync_mode set: a1=off, v1/a2=ripple")

-- Read helper.
local function clip_ts(clip_id)
    local s = db:prepare("SELECT sequence_start_frame FROM clips WHERE id=?")
    assert(s); s:bind_value(1, clip_id); s:exec(); s:next()
    local v = s:value(0); s:finalize()
    assert(v ~= nil, "clip " .. clip_id .. " not found")
    return v
end

-- Record pre-ripple positions.
local a1b_before = clip_ts("c_a1b")   -- must not change
local a2b_before = clip_ts("c_a2b")   -- must shift by -DELTA

-- Ripple-trim V1's clip: shorten it by DELTA (right edge moves left).
local ripple_r = command_manager.execute("RippleTrimEdge", {
    sequence_id = layout.sequence_id,
    clip_id     = "c_v1",
    edge        = "right",
    delta_frames = -DELTA,
    project_id  = layout.project_id,
})
assert(ripple_r and ripple_r.success,
    "RippleTrimEdge failed: " .. tostring(ripple_r and ripple_r.error_message))

-- ── Off-branch: A1 clips must be unchanged ────────────────────────────────
local a1b_after = clip_ts("c_a1b")
assert(a1b_after == a1b_before, string.format(
    "FAIL: Off-track A1 clip shifted from %d to %d — sync_mode='off' must be immune to ripple",
    a1b_before, a1b_after))
print(string.format("  Off-track A1 unchanged: sequence_start=%d — OK", a1b_after))

-- ── Ripple-branch: A2 back-clip must shift by -DELTA ─────────────────────
local a2b_after = clip_ts("c_a2b")
assert(a2b_after == a2b_before - DELTA, string.format(
    "FAIL: Ripple-track A2 back-clip at %d, expected %d (before=%d, delta=%d)",
    a2b_after, a2b_before - DELTA, a2b_before, DELTA))
print(string.format("  Ripple-track A2 shifted: %d → %d (delta=-%d) — OK",
    a2b_before, a2b_after, DELTA))

print("\n✅ test_ripple_sync_off.lua passed")
