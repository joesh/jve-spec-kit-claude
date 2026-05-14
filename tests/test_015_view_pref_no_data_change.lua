#!/usr/bin/env luajit

-- 015 — FR-029c: changing source_routing_view preference must NOT alter
-- underlying patches rows. The preference controls representation only.
--
-- Spec FR-029c: "switching `source_routing_view` between 'per_channel' and
-- 'per_clip' MUST NOT alter underlying `patches` rows — only the rendered
-- representation. Re-render after preference change shows the new layout."
-- Spec FR-029d (companion): same invariant under modifier-key view-toggle —
-- the held-modifier flip changes display only; underlying rows unchanged.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local view_pref       = require("ui.source_routing_view_pref")
local view_state      = require("ui.source_routing_view_state")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_view_pref_no_data_change.lua ===")

local DB = "/tmp/jve/test_015_view_pref_no_data_change.db"
local PREF = "/tmp/jve/test_015_view_pref.json"
os.remove(DB); os.remove(PREF); os.execute("mkdir -p /tmp/jve")

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
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, sync_mode)
    VALUES
      ('trk_a1', 'seq', 'A1', 'AUDIO', 1, 1, 'ripple'),
      ('trk_a2', 'seq', 'A2', 'AUDIO', 2, 1, 'ripple'),
      ('trk_a3', 'seq', 'A3', 'AUDIO', 3, 1, 'ripple');
]], now, now, now, now))

command_manager.init("seq", "proj")
view_pref.init(PREF)
view_state.init(view_pref)

-- Create three patches at shape=3 (3 AUDIO source tracks in the fixture).
for _, idx in ipairs({1, 2, 3}) do
    command_manager.execute("SetPatch", {
        sequence_id        = "seq",
        track_type         = "AUDIO",
        source_shape       = 3,
        source_track_index = idx,
        record_track_index = idx,
        project_id         = "proj",
        enabled            = 1,
    })
end

local function snapshot_patches()
    local out = {}
    local s = db:prepare(
        "SELECT track_type, source_track_index, record_track_index, enabled "
        .. "FROM patches WHERE sequence_id='seq' "
        .. "ORDER BY track_type, source_track_index")
    s:exec()
    while s:next() do
        table.insert(out, {
            type = s:value(0), src = s:value(1), rec = s:value(2),
            enabled = s:value(3),
        })
    end
    s:finalize()
    return out
end

local function rows_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].type ~= b[i].type or a[i].src ~= b[i].src
           or a[i].rec ~= b[i].rec or a[i].enabled ~= b[i].enabled then
            return false
        end
    end
    return true
end

local before = snapshot_patches()
assert(#before == 3, string.format(
    "FAIL: expected 3 patches before pref change, got %d", #before))

-- ── (1) Pref flip per_channel → per_clip: no DB change ─────────────────
print("-- (1) flip pref per_channel → per_clip --")
assert(view_pref.get() == "per_channel",
    "FAIL: precondition: default pref should be per_channel")
view_pref.set("per_clip")
assert(view_pref.get() == "per_clip", "FAIL: pref did not change to per_clip")

local after_pref_change = snapshot_patches()
assert(rows_equal(before, after_pref_change),
    "FAIL: patches rows changed when source_routing_view pref flipped — "
    .. "FR-029c: pref MUST NOT alter underlying patches")
print("  3 patches unchanged after pref flip — OK")

-- ── (2) Modifier-key flip: no DB change ────────────────────────────────
print("-- (2) modifier-key flip (FR-029d) --")
assert(view_state.effective_mode() == "per_clip",
    "FAIL: precondition: effective mode should be per_clip (pref)")
view_state.set_modifier_held(true)
assert(view_state.effective_mode() == "per_channel",
    "FAIL: held modifier must flip per_clip → per_channel")

local after_modifier = snapshot_patches()
assert(rows_equal(before, after_modifier),
    "FAIL: patches rows changed when modifier-key view-toggle was held — "
    .. "FR-029d: modifier flip MUST NOT alter underlying patches")
print("  3 patches unchanged with modifier held — OK")

view_state.set_modifier_held(false)
assert(view_state.effective_mode() == "per_clip",
    "FAIL: releasing modifier must return to base pref")

-- ── (3) Pref flip back: no DB change ───────────────────────────────────
print("-- (3) flip pref per_clip → per_channel --")
view_pref.set("per_channel")
local after_back = snapshot_patches()
assert(rows_equal(before, after_back),
    "FAIL: patches rows changed when pref flipped back — "
    .. "FR-029c invariant must hold in both directions")
print("  3 patches unchanged after second pref flip — OK")

print("\nâœ… test_015_view_pref_no_data_change.lua passed")
