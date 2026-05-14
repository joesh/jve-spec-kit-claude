#!/usr/bin/env luajit

-- T022 (015) — Signal contracts for all 8 new/modified signals (contracts/signals.md).
--
-- For each signal: (1) emitted on the documented action, (2) payload shape correct,
-- (3) no emission on no-op, (4) displayed_tab_changed fires but active_sequence_changed
-- does NOT fire on SourceTab click (FR-005 pointer decoupling).
--
-- Expected FAIL today: SetPatch, SetSyncMode, ToggleTrackPreference, SetTrackMixValue
-- commands not registered; source_loaded_changed not emitted; tab signals not wired.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_signals_015.lua ===")

local DB = "/tmp/jve/test_signals_015.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        volume, pan)
    VALUES ('trk', 'seq', 'A1', 'AUDIO', 1, 1, 1.0, 0.0)
]])

-- Set sync_mode — FAIL here if schema migration not applied.
assert(db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id='trk'"),
    "FAIL: tracks.sync_mode column missing — schema migration T025 not applied")

command_manager.init("seq", "proj")

-- Helper: collect signal emissions into a list.
local function capture(name)
    local log = {}
    Signals.connect(name, function(...) log[#log+1] = {...} end)
    return log
end

-- ── patch_changed ─────────────────────────────────────────────────────────────
print("-- patch_changed --")
local patch_log = capture("patch_changed")

-- Patch signal payload contract (set_patch.lua):
--   (sequence_id, track_type, source_shape, source_track_index, change_type)
local SHAPE = 4

local r1 = command_manager.execute("SetPatch", {
    sequence_id         = "seq",
    project_id          = "proj",
    track_type          = "AUDIO",
    source_shape        = SHAPE,
    source_track_index  = 1,
    record_track_index  = 2,
    enabled             = true,
})
assert(r1 and r1.success, "SetPatch create failed: " .. tostring(r1 and r1.error_message))
assert(#patch_log == 1, string.format("patch_changed: expected 1 emission, got %d", #patch_log))
assert(patch_log[1][1] == "seq",     "patch_changed payload[1] must be sequence_id")
assert(patch_log[1][2] == "AUDIO",   "patch_changed payload[2] must be track_type")
assert(patch_log[1][3] == SHAPE,     "patch_changed payload[3] must be source_shape")
assert(patch_log[1][4] == 1,         "patch_changed payload[4] must be source_track_index=1")
assert(patch_log[1][5] == "created", "patch_changed payload[5] must be 'created'")
print("  patch_changed (created) payload — OK")

-- Update.
local r1b = command_manager.execute("SetPatch", {
    sequence_id         = "seq",
    project_id          = "proj",
    track_type          = "AUDIO",
    source_shape        = SHAPE,
    source_track_index  = 1,
    record_track_index  = 3,
    enabled             = true,
})
assert(r1b and r1b.success, "SetPatch update failed")
assert(#patch_log == 2,             "patch_changed: expected 2 emissions after update")
assert(patch_log[2][5] == "updated", "patch_changed payload[5] must be 'updated'")
print("  patch_changed (updated) payload — OK")

-- Disable (row is kept; src-btn keeps rendering in dimmed state).
local r1c = command_manager.execute("SetPatch", {
    sequence_id         = "seq",
    project_id          = "proj",
    track_type          = "AUDIO",
    source_shape        = SHAPE,
    source_track_index  = 1,
    enabled             = false,
})
assert(r1c and r1c.success, "SetPatch disable failed")
assert(#patch_log == 3,             "patch_changed: expected 3 emissions after disable")
assert(patch_log[3][5] == "disabled",
    "patch_changed payload[5] must be 'disabled' (row is kept so src-btn keeps rendering)")
print("  patch_changed (disabled) payload — OK")

-- ── sync_mode_changed ─────────────────────────────────────────────────────────
print("-- sync_mode_changed --")
local sync_log = capture("sync_mode_changed")

local r2 = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "cut",
    project_id = "proj",
})
assert(r2 and r2.success, "SetSyncMode failed: " .. tostring(r2 and r2.error_message))
assert(#sync_log == 1, string.format("sync_mode_changed: expected 1, got %d", #sync_log))
assert(sync_log[1][1] == "trk",      "sync_mode_changed payload[1] must be track_id")
assert(sync_log[1][2] == "cut",      "sync_mode_changed payload[2] must be new mode 'cut'")
assert(sync_log[1][3] == "ripple",   "sync_mode_changed payload[3] must be previous mode 'ripple'")
print("  sync_mode_changed payload — OK")

-- No-op: set to current value must NOT emit.
local r2b = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "cut",
    project_id = "proj",
})
assert(r2b and r2b.success, "SetSyncMode no-op failed")
assert(#sync_log == 1, string.format(
    "sync_mode_changed: no-op must NOT emit; got %d total", #sync_log))
print("  sync_mode_changed no-op — NOT emitted — OK")

-- ── track_preference_changed ──────────────────────────────────────────────────
print("-- track_preference_changed --")
local pref_log = capture("track_preference_changed")

for _, prop in ipairs({"muted", "soloed", "locked", "enabled"}) do
    local count_before = #pref_log
    local r3 = command_manager.execute("ToggleTrackPreference", {
        track_id   = "trk",
        property   = prop,
        project_id = "proj",
    })
    assert(r3 and r3.success,
        "ToggleTrackPreference " .. prop .. " failed: " .. tostring(r3 and r3.error_message))
    assert(#pref_log == count_before + 1, string.format(
        "track_preference_changed: expected 1 emission for '%s', got %d",
        prop, #pref_log - count_before))
    local ev = pref_log[#pref_log]
    assert(ev[1] == "trk",  "track_preference_changed payload[1] must be track_id")
    assert(ev[2] == prop,   "track_preference_changed payload[2] must be property name")
    -- payload[3] = new_value, payload[4] = previous_value (both non-nil)
    assert(ev[3] ~= nil,    "track_preference_changed payload[3] (new_value) must not be nil")
    assert(ev[4] ~= nil,    "track_preference_changed payload[4] (previous_value) must not be nil")
    assert(ev[3] ~= ev[4],  "track_preference_changed: new_value must differ from previous")
    print(string.format("  track_preference_changed '%s' payload — OK", prop))
end

-- ── track_mix_changed ─────────────────────────────────────────────────────────
print("-- track_mix_changed --")
local mix_log = capture("track_mix_changed")

local r4 = command_manager.execute("SetTrackMixValue", {
    track_id   = "trk",
    property   = "volume",
    value      = 0.5,
    project_id = "proj",
})
assert(r4 and r4.success, "SetTrackMixValue volume failed: " .. tostring(r4 and r4.error_message))
assert(#mix_log >= 1, "track_mix_changed must be emitted on volume change")
print("  track_mix_changed (volume) emitted — OK")

local r4b = command_manager.execute("SetTrackMixValue", {
    track_id   = "trk",
    property   = "pan",
    value      = 0.25,
    project_id = "proj",
})
assert(r4b and r4b.success, "SetTrackMixValue pan failed")
assert(#mix_log >= 2, "track_mix_changed must be emitted on pan change")
print("  track_mix_changed (pan) emitted — OK")

-- ── Qt-bound signals (source_loaded_changed, source_tab_visibility_changed,
--    displayed_tab_changed, active_sequence_changed) ─────────────────────────
-- These signals are emitted from source_viewer (panel_manager, Qt-bound) and
-- tab-strip commands that touch the timeline UI. They require --test mode.
-- Coverage:
--   source_loaded_changed         → tests/test_source_viewer_signal.lua (--test, T036)
--   source_tab_visibility_changed → tests/test_displayed_vs_active_pointer.lua (--test, T016)
--   displayed_tab_changed         → tests/test_displayed_vs_active_pointer.lua (--test, T016)
--   active_sequence_changed       → tests/test_displayed_vs_active_pointer.lua (--test, T016)
-- This file covers only the pure-Lua command-emitted signals above.

print("\n✅ test_signals_015.lua passed")
