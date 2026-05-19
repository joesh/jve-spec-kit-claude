#!/usr/bin/env luajit

-- T009 (015) — ToggleTrackPreference command contract (C4a).
--
-- Domain: muted/soloed/locked/enabled are session-monitoring preferences,
-- not mix decisions. ToggleTrackPreference must persist each, not revert
-- on undo, and emit track_preference_changed with the correct payload.
-- Invalid property must assert. Boolean coercion (truthy→true, falsy→false).
--
-- Expected FAIL today: ToggleTrackPreference command does not exist.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_toggle_track_preference.lua ===")

local DB = "/tmp/jve/test_toggle_track_preference.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk', 'seq', 'A1', 'AUDIO', 1, 1)
]])

command_manager.init("seq", "proj")

local function get_field(col)
    local s = db:prepare("SELECT " .. col .. " FROM tracks WHERE id='trk'")
    assert(s); s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end

local signal_log = {}
Signals.connect("track_preference_changed", function(tid, prop, new_val, prev_val)
    table.insert(signal_log, {track_id=tid, prop=prop, new=new_val, prev=prev_val})
end)

-- ── Each boolean preference: set, verify, undo is no-op ──────────────────
local PROPS = {"muted", "soloed", "locked", "enabled"}

for _, prop in ipairs(PROPS) do
    print(string.format("-- %s --", prop))
    -- Reset to known baseline via raw SQL (doesn't touch undo stack).
    db:exec(string.format("UPDATE tracks SET %s = 0 WHERE id='trk'", prop))
    local before_count = #signal_log

    -- Toggle to true.
    local r = command_manager.execute("ToggleTrackPreference", {
        track_id   = "trk",
        property   = prop,
        value      = true,
        project_id = "proj",
    })
    assert(r and r.success, string.format(
        "ToggleTrackPreference(%s=true) failed: %s", prop, tostring(r and r.error_message)))
    assert(get_field(prop) == 1, prop .. " must be 1 after toggle-on")

    -- Signal emitted with correct payload.
    assert(#signal_log > before_count, "track_preference_changed not emitted for " .. prop)
    local sig = signal_log[#signal_log]
    assert(sig.track_id == "trk", "signal track_id wrong for " .. prop)
    assert(sig.prop == prop, "signal property wrong: " .. tostring(sig.prop))
    -- Signal payload is INTEGER 0/1 per command emit (boolean coerced at boundary).
    assert(sig.new == 1, "signal new_value must be INTEGER 1 (boundary normalization) for " .. prop)

    -- Undo must NOT revert.
    command_manager.undo()
    assert(get_field(prop) == 1, string.format(
        "FAIL: %s reverted after undo — preference must not be undoable", prop))

    -- Toggle back to false (boolean coercion: false/nil → 0).
    local r2 = command_manager.execute("ToggleTrackPreference", {
        track_id   = "trk",
        property   = prop,
        value      = false,
        project_id = "proj",
    })
    assert(r2 and r2.success, prop .. " toggle-off failed")
    assert(get_field(prop) == 0, prop .. " must be 0 after toggle-off")

    print(string.format("  %s: toggle on/off + undo no-op — OK", prop))
end

-- ── Invalid property asserts ──────────────────────────────────────────────
print("-- invalid property refused --")
local r_bad = command_manager.execute("ToggleTrackPreference", {
    track_id   = "trk",
    property   = "volume",   -- volume belongs to SetTrackMixValue, not here
    value      = 1.0,
    project_id = "proj",
})
assert(not (r_bad and r_bad.success),
    "ToggleTrackPreference must refuse 'volume' (belongs to SetTrackMixValue)")
print("  'volume' refused — OK")

print("\n✅ test_toggle_track_preference.lua passed")
