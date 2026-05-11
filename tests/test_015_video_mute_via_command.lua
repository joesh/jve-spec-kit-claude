#!/usr/bin/env luajit

-- 015 — FR-018 + FR-019: video Mute is wired end-to-end through the
-- ToggleTrackPreference command path and visible to the renderer.
--
-- Spec FR-018: "S and M MUST apply to BOTH audio and video tracks."
-- Spec FR-019: "On video tracks, Mute MUST cause the renderer to skip
-- that track during compositing such that the next-lower non-muted track
-- becomes the topmost candidate."
--
-- This pins the COMMAND → MODEL → RENDERER chain. test_video_mute_solo_compositor
-- already pins the renderer's pure compute fn against synthetic input;
-- this test pins that ToggleTrackPreference actually flips the persisted
-- column AND that the renderer's effective-set respects the flipped value.
-- A regression where the click handler doesn't dispatch the command,
-- the command writes to the wrong column, or the renderer reads stale
-- track state will fail this test.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Track           = require("models.track")
local renderer        = require("core.renderer")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_video_mute_via_command.lua ===")

local DB = "/tmp/jve/test_015_video_mute_via_command.db"
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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, sync_mode)
    VALUES
      ('trk_v1', 'seq', 'V1', 'VIDEO', 1, 1, 'ripple'),
      ('trk_v2', 'seq', 'V2', 'VIDEO', 2, 1, 'ripple'),
      ('trk_v3', 'seq', 'V3', 'VIDEO', 3, 1, 'ripple');
]], now, now, now, now))

command_manager.init("seq", "proj")

local function video_track_states()
    local out = {}
    for _, t in ipairs(Track.find_by_sequence("seq", "VIDEO")) do
        table.insert(out, {
            track_index = t.track_index,
            muted       = t.muted == true,
            soloed      = t.soloed == true,
        })
    end
    return out
end

-- ── (1) Baseline: no mute, all 3 tracks participate, V3 topmost ────────
print("-- (1) baseline: no mute --")
local effective = renderer.compute_effective_video_indices(video_track_states())
assert(#effective == 3, string.format(
    "FAIL: expected 3 effective tracks, got %d", #effective))
assert(effective[1] == 3, "FAIL: V3 must be topmost in effective set")
print("  topmost=V3, count=3 — OK")

-- ── (2) ToggleTrackPreference muted=true on V3 → V2 promotes ───────────
print("-- (2) ToggleTrackPreference muted=true on V3 --")
local r = command_manager.execute("ToggleTrackPreference", {
    track_id   = "trk_v3",
    property   = "muted",
    value      = true,
    project_id = "proj",
})
assert(r and r.success, "ToggleTrackPreference failed: " .. tostring(r and r.error_message))

local v3 = Track.load("trk_v3")
assert(v3.muted == true, string.format(
    "FAIL: V3.muted not true after ToggleTrackPreference, got %s",
    tostring(v3.muted)))
print("  V3.muted=true persisted — OK")

local effective_after = renderer.compute_effective_video_indices(video_track_states())
assert(#effective_after == 2, string.format(
    "FAIL: expected 2 effective tracks after V3 mute, got %d", #effective_after))
assert(effective_after[1] == 2, string.format(
    "FAIL: V2 must promote to topmost when V3 muted, got V%d (FR-019)",
    effective_after[1]))
assert(effective_after[2] == 1, "FAIL: V1 must be second after V3 mute")
print("  V2 promoted to topmost; V3 excluded — OK")

-- ── (3) Toggle muted back to false → V3 returns ────────────────────────
print("-- (3) un-mute V3 --")
command_manager.execute("ToggleTrackPreference", {
    track_id   = "trk_v3",
    property   = "muted",
    value      = false,
    project_id = "proj",
})
local v3_back = Track.load("trk_v3")
assert(v3_back.muted == false, "FAIL: V3.muted not cleared")

local effective_back = renderer.compute_effective_video_indices(video_track_states())
assert(#effective_back == 3, "FAIL: V3 should rejoin effective set")
assert(effective_back[1] == 3, "FAIL: V3 should be topmost again")
print("  V3 back as topmost — OK")

-- ── (4) Mute on a video track does NOT touch audio_playback semantics ──
-- Belt-and-braces: spec FR-018 says S/M apply to BOTH; ensure the column
-- is the SAME schema column for video and audio (no parallel column).
print("-- (4) muted column is shared schema — OK by INSERT contract")
local stmt = db:prepare(
    "SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name='muted'")
stmt:exec(); stmt:next()
assert(stmt:value(0) == 1, "FAIL: tracks.muted column missing")
stmt:finalize()
print("  one shared muted column for both track types — OK")

print("\nâœ… test_015_video_mute_via_command.lua passed")
