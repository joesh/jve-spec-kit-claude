#!/usr/bin/env luajit

-- T013 (015) — FR-026 Ripple-branch: existing pipeline behavior preserved
-- after sync_mode dispatch is inserted.
--
-- Domain: with all tracks at sync_mode='ripple' (the default), a ripple edit
-- must propagate uniformly — identical to pre-015 behavior. This test guards
-- against the dispatch insertion (T032) accidentally breaking normal ripple.
--
-- Expected FAIL today: tracks.sync_mode column does not exist (migration not
-- applied). Will also FAIL if the dispatch insertion corrupts normal ripple.
-- Must be GREEN both before T032 (if schema is present) and after T032.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database       = require("core.database")
local command_manager = require("core.command_manager")
local ripple_layout  = require("tests.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_ripple_sync_ripple.lua ===")

-- ── Fixture: 2 tracks, both 'ripple', clips at non-trivial positions ──────
-- V1: clip [0, 150),  V1-downstream [150, 300)
-- A1: clip [0, 150),  A1-downstream [150, 300)
-- Ripple-trim V1's right edge by -40 frames.
-- All downstream clips (V1 and A1) must shift by exactly -40.

local DELTA = 40

local layout = ripple_layout.create({
    db_path         = "/tmp/jve/test_ripple_sync_ripple.db",
    fps_numerator   = 1000,
    fps_denominator = 1,
    tracks = {
        order = {"v1", "a1"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
    },
    media = { main = { audio_channels=2 } },
    clips = {
        order = {"c_v1", "c_v1_ds", "c_a1", "c_a1_ds"},
        c_v1    = {id="c_v1",    track_key="v1", media_key="main",
                   timeline_start=0,   duration=150, source_in=1000, fps_numerator=1000, fps_denominator=1},
        c_v1_ds = {id="c_v1_ds", track_key="v1", media_key="main",
                   timeline_start=150, duration=150, source_in=1150, fps_numerator=1000, fps_denominator=1},
        c_a1    = {id="c_a1",    track_key="a1", media_key="main",
                   timeline_start=0,   duration=150, source_in=1000, fps_numerator=1000, fps_denominator=1},
        c_a1_ds = {id="c_a1_ds", track_key="a1", media_key="main",
                   timeline_start=150, duration=150, source_in=1150, fps_numerator=1000, fps_denominator=1},
    },
})

local db = database.get_connection()

-- Set both tracks to sync_mode='ripple' explicitly.
-- FAIL here if schema migration not applied.
local ok = db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id IN ('trk_v1','trk_a1')")
assert(ok, "FAIL: tracks.sync_mode column missing — migration not applied")
print("  sync_mode='ripple' set on both tracks")

local function clip_ts(id)
    local s = db:prepare("SELECT timeline_start_frame FROM clips WHERE id=?")
    assert(s); s:bind_value(1, id); s:exec(); s:next()
    local v = s:value(0); s:finalize()
    assert(v ~= nil, "clip " .. id .. " not found"); return v
end

local v1_ds_before = clip_ts("c_v1_ds")   -- 150
local a1_ds_before = clip_ts("c_a1_ds")   -- 150

-- Ripple-trim V1's clip by -DELTA at the right edge.
local r = command_manager.execute("RippleTrimEdge", {
    sequence_id  = layout.sequence_id,
    clip_id      = "c_v1",
    edge         = "right",
    delta_frames = -DELTA,
    project_id   = layout.project_id,
})
assert(r and r.success, "RippleTrimEdge failed: " .. tostring(r and r.error_message))

-- ── Both downstream clips must shift by exactly -DELTA ────────────────────
local v1_ds_after = clip_ts("c_v1_ds")
local a1_ds_after = clip_ts("c_a1_ds")

assert(v1_ds_after == v1_ds_before - DELTA, string.format(
    "FAIL: V1 downstream at %d, expected %d (ripple delta=%d not applied)",
    v1_ds_after, v1_ds_before - DELTA, DELTA))
print(string.format("  V1 downstream: %d→%d (delta=-%d) — OK",
    v1_ds_before, v1_ds_after, DELTA))

assert(a1_ds_after == a1_ds_before - DELTA, string.format(
    "FAIL: A1 downstream at %d, expected %d (ripple not uniform across tracks)",
    a1_ds_after, a1_ds_before - DELTA))
print(string.format("  A1 downstream: %d→%d (delta=-%d) — OK",
    a1_ds_before, a1_ds_after, DELTA))

print("\n✅ test_ripple_sync_ripple.lua passed")
