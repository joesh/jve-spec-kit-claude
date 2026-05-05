#!/usr/bin/env luajit

-- T010 (015) — SetTrackMixValue command contract (C4b).
--
-- Domain: volume and pan are mix decisions that belong on the undo stack.
-- SetTrackMixValue (split from SetTrackProperty) must update volume/pan,
-- support Cmd-Z revert (UNLIKE ToggleTrackPreference), and emit track_mix_changed.
--
-- Expected FAIL today: SetTrackMixValue command does not exist.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_set_track_mix_value.lua ===")

local DB = "/tmp/jve/test_set_track_mix_value.db"
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
    VALUES ('seq', 'proj', 'S', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        volume, pan)
    VALUES ('trk', 'seq', 'A1', 'AUDIO', 1, 1, 1.0, 0.0)
]])

command_manager.init("seq", "proj")

local function get_field(col)
    local s = db:prepare("SELECT " .. col .. " FROM tracks WHERE id='trk'")
    assert(s); s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end

local signal_log = {}
Signals.connect("track_mix_changed", function(...)
    table.insert(signal_log, {...})
end)

-- ── Volume update and undo ────────────────────────────────────────────────
print("-- volume update --")
local r1 = command_manager.execute("SetTrackMixValue", {
    track_id   = "trk",
    property   = "volume",
    value      = 0.75,
    project_id = "proj",
})
assert(r1 and r1.success, "SetTrackMixValue volume failed: " .. tostring(r1 and r1.error_message))
assert(math.abs(get_field("volume") - 0.75) < 0.001,
    "volume must be 0.75 after set, got: " .. tostring(get_field("volume")))
print("  volume=0.75 set — OK")

-- track_mix_changed signal emitted.
assert(#signal_log >= 1, "track_mix_changed must be emitted on volume change")
print("  track_mix_changed emitted — OK")

-- Undo MUST revert (volume/pan ARE undoable — unlike muted/soloed/locked/enabled).
command_manager.undo()
assert(math.abs(get_field("volume") - 1.0) < 0.001,
    "FAIL: undo did not revert volume to 1.0 — volume changes must be undoable; got: "
    .. tostring(get_field("volume")))
print("  undo reverted volume=1.0 — OK (mix values are undoable)")

-- ── Pan update and undo ───────────────────────────────────────────────────
print("-- pan update --")
local r2 = command_manager.execute("SetTrackMixValue", {
    track_id   = "trk",
    property   = "pan",
    value      = -0.5,
    project_id = "proj",
})
assert(r2 and r2.success, "SetTrackMixValue pan failed")
assert(math.abs(get_field("pan") - (-0.5)) < 0.001,
    "pan must be -0.5, got: " .. tostring(get_field("pan")))
print("  pan=-0.5 set — OK")

command_manager.undo()
assert(math.abs(get_field("pan") - 0.0) < 0.001,
    "undo must revert pan to 0.0; got: " .. tostring(get_field("pan")))
print("  undo reverted pan=0.0 — OK")

-- ── SetTrackMixValue must refuse boolean properties ───────────────────────
print("-- refuses muted (belongs to ToggleTrackPreference) --")
local r_bad = command_manager.execute("SetTrackMixValue", {
    track_id   = "trk",
    property   = "muted",
    value      = true,
    project_id = "proj",
})
assert(not (r_bad and r_bad.success),
    "SetTrackMixValue must refuse 'muted' (belongs to ToggleTrackPreference)")
print("  'muted' refused — OK")

print("\n✅ test_set_track_mix_value.lua passed")
