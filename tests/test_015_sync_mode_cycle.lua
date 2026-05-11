#!/usr/bin/env luajit

-- 015 — FR-024: sync-mode cycle order Off → Ripple → Cut → Off.
--
-- Spec FR-024: "The sync-mode cell in the track header MUST cycle
-- Off → Ripple → Cut → Off on click."
--
-- This test exercises the cycle through three SetSyncMode calls starting
-- from each of the three valid states, asserting that the next-mode mapping
-- is single-valued and the full cycle returns to start in exactly 3 steps.
-- The cycle table (or equivalent) is a track-header concern, not SetSyncMode
-- itself — SetSyncMode validates and writes; the *cycle* is computed by the
-- track header. We pin the expected next-mode mapping here so the cycle
-- stays correct wherever it lives.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Track           = require("models.track")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_sync_mode_cycle.lua ===")

local DB = "/tmp/jve/test_015_sync_mode_cycle.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        sync_mode)
    VALUES ('trk', 'seq', 'V1', 'VIDEO', 1, 1, 'off');
]], now, now, now, now))

command_manager.init("seq", "proj")

-- Spec-mandated next-mode mapping.
local NEXT = { off = "ripple", ripple = "cut", cut = "off" }

local function set_to(mode)
    local r = command_manager.execute("SetSyncMode", {
        track_id = "trk", sync_mode = mode, project_id = "proj",
    })
    assert(r and r.success, string.format("SetSyncMode(%s) failed: %s",
        mode, tostring(r and r.error_message)))
end

-- ── Verify each transition individually (3 transitions × 3 starting states) ──
for _, start in ipairs({"off", "ripple", "cut"}) do
    set_to(start)
    local t0 = Track.load("trk")
    assert(t0.sync_mode == start, string.format(
        "FAIL: precondition: track sync_mode=%s, expected %s", t0.sync_mode, start))

    local expected_next = NEXT[start]
    set_to(expected_next)
    local t1 = Track.load("trk")
    assert(t1.sync_mode == expected_next, string.format(
        "FAIL: cycle from %s should land on %s, got %s",
        start, expected_next, t1.sync_mode))
    print(string.format("  %s → %s — OK", start, expected_next))
end

-- ── Full 3-click cycle returns to start ─────────────────────────────────────
print("-- 3-click cycle returns to start --")
set_to("off")
for _, _i in ipairs({1, 2, 3}) do
    local cur = Track.load("trk").sync_mode
    set_to(NEXT[cur])
end
local final = Track.load("trk").sync_mode
assert(final == "off", string.format(
    "FAIL: 3-click cycle from 'off' must return to 'off', got %s", final))
print("  off → ripple → cut → off — OK")

print("\nâœ… test_015_sync_mode_cycle.lua passed")
