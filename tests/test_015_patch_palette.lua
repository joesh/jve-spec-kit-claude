#!/usr/bin/env luajit

-- 015 — FR-031: 12-hue palette, deterministic by creation order.
--
-- Spec FR-031: "Each patch has a unique color from a stable 12-hue palette,
-- assigned deterministically by creation order (wraps on overflow, reusing
-- palette from the start). The color is stored on the patch entity
-- (`patches.color`) and is canonical — both the src-side and rec-side
-- indicators render using this color. The palette contains ≥12 distinct
-- hues; adjacent-index patches MUST be visually distinct even on overflow
-- wrap."
--
-- Rules verified:
--   1. ≥12 distinct hues actually distinct (case-insensitive hex compare).
--   2. Determinism: creating N patches in the same order on a fresh
--      sequence produces the same N colors twice in a row.
--   3. Wrap: patch #13 reuses color of patch #1 (palette wraps).
--   4. Adjacent distinctness: no two consecutive palette entries share a
--      color. Verified across the wrap boundary too.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Patch           = require("models.patch")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_patch_palette.lua ===")

local DB = "/tmp/jve/test_015_patch_palette.db"
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
]], now, now, now, now))

command_manager.init("seq", "proj")

-- Create N AUDIO source tracks so we can patch each with a different src_idx.
local N = 13  -- 12 palette slots + 1 to verify wrap
for i = 1, N do
    db:exec(string.format([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
            enabled, sync_mode)
        VALUES ('trk_a%d', 'seq', 'A%d', 'AUDIO', %d, 1, 'ripple')
    ]], i, i, i))
end

local function create_patch(src_idx)
    local r = command_manager.execute("SetPatch", {
        sequence_id        = "seq",
        track_type         = "AUDIO",
        source_track_index = src_idx,
        record_track_index = src_idx,
        project_id         = "proj",
        enabled            = 1,
    })
    assert(r and r.success, string.format("SetPatch(src=%d) failed: %s",
        src_idx, tostring(r and r.error_message)))
end

local function get_color(src_idx)
    local p = Patch.find_by_source("seq", "AUDIO", src_idx)
    assert(p, string.format("patch missing for src=%d", src_idx))
    return p.color:lower()
end

-- ── (1) Create N patches; record colors in creation order ────────────────
print(string.format("-- (1) create %d AUDIO patches; record colors --", N))
local colors = {}
for i = 1, N do
    create_patch(i)
    colors[i] = get_color(i)
end
for i = 1, N do
    print(string.format("  patch %d → %s", i, colors[i]))
end

-- ── (2) ≥12 distinct hues among the first 12 ─────────────────────────────
print("-- (2) first 12 are distinct hues --")
local seen = {}
for i = 1, 12 do
    assert(not seen[colors[i]], string.format(
        "FAIL: color %s collides at positions %d and %d (palette must have "
        .. "≥12 distinct hues)", colors[i], seen[colors[i]] or 0, i))
    seen[colors[i]] = i
end
print("  12 distinct — OK")

-- ── (3) Wrap: patch #13 reuses patch #1's color ──────────────────────────
print("-- (3) palette wraps at slot 13 --")
assert(colors[13] == colors[1], string.format(
    "FAIL: patch #13 color=%s, expected wrap to patch #1 color=%s",
    colors[13], colors[1]))
print("  patch 13 wraps to patch 1's hue — OK")

-- ── (4) Adjacent palette entries are visually distinct, including wrap ───
print("-- (4) no two adjacent palette slots share a color --")
for i = 1, 12 do
    local nxt = (i % 12) + 1   -- 1..12 → 2..12,1 (wrap-aware adjacency)
    assert(colors[i] ~= colors[nxt], string.format(
        "FAIL: adjacent palette slots %d and %d share color %s — spec "
        .. "FR-031 requires adjacent-index patches be visually distinct "
        .. "even on overflow wrap", i, nxt, colors[i]))
end
print("  all 12 adjacencies distinct — OK")

-- ── (5) Determinism: re-create on a fresh sequence → same colors ─────────
print("-- (5) determinism: fresh sequence yields same color sequence --")
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq2', 'proj', 'S2', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
for i = 1, N do
    db:exec(string.format([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
            enabled, sync_mode)
        VALUES ('trk2_a%d', 'seq2', 'A%d', 'AUDIO', %d, 1, 'ripple')
    ]], i, i, i))
end
for i = 1, N do
    local r = command_manager.execute("SetPatch", {
        sequence_id        = "seq2",
        track_type         = "AUDIO",
        source_track_index = i,
        record_track_index = i,
        project_id         = "proj",
        enabled            = 1,
    })
    assert(r and r.success)
end
for i = 1, N do
    local p2 = Patch.find_by_source("seq2", "AUDIO", i)
    local c2 = p2.color:lower()
    assert(c2 == colors[i], string.format(
        "FAIL: deterministic palette violated — seq2 patch %d color=%s, "
        .. "expected %s (must match seq's order)", i, c2, colors[i]))
end
print("  fresh sequence reproduces the same color sequence — OK")

print("\nâœ… test_015_patch_palette.lua passed")
