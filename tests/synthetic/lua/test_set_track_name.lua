#!/usr/bin/env luajit

-- SetTrackName command (023 Feature B) — rename a track; clearing reverts.
--
-- Domain: a synced master's audio tracks are nameless (the display derives a
-- recorder channel label). The user may rename a track (an override that the
-- display shows verbatim); clearing the name (empty input) drops the override
-- so the derived label returns. Renames are undoable.
--
-- Black-box: assert what the header label shows (via the display helper) and
-- what survives undo — never the storage mechanism.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")
local labels = require("ui.timeline.track_header_label")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_set_track_name.lua ===")

local DB = "/tmp/jve/test_set_track_name.db"
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
-- A nameless audio track (as a synced master's channel tracks are created):
-- name is NULL (unset) so the display derives a label.
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk', 'seq', NULL, 'AUDIO', 1, 1)
]])

command_manager.init("seq", "proj")

local Track = require("models.track")
local function header_label()
    -- The record-tab label the user sees, given a probed channel name "BOOM".
    local t = Track.load("trk")
    return labels.for_display(
        { name = t.name, channel_name = "BOOM", channel_backed = true,
          track_index = t.track_index, track_type = t.track_type },
        "record")
end

local signal_log = {}
Signals.connect("track_name_changed", function(...)
    table.insert(signal_log, {...})
end)

-- ── Nameless track shows the derived (probed) label ───────────────────────
assert(header_label() == "BOOM",
    "a nameless track must show the probed channel name; got " .. header_label())
print("  nameless track shows derived label 'BOOM' — OK")

-- ── Rename: the override is shown verbatim, signal emitted ─────────────────
local r1 = command_manager.execute("SetTrackName", {
    track_id = "trk", name = "Boom Op", project_id = "proj",
})
assert(r1 and r1.success, "SetTrackName failed: " .. tostring(r1 and r1.error_message))
assert(header_label() == "Boom Op",
    "after rename the header must show the override; got " .. header_label())
assert(#signal_log >= 1, "track_name_changed must be emitted")
print("  rename -> 'Boom Op' (override beats probe) — OK")

-- ── Undo reverts to the nameless (derived) state ──────────────────────────
command_manager.undo()
assert(header_label() == "BOOM",
    "undo must restore the nameless state (derived label returns); got " .. header_label())
print("  undo restores derived label 'BOOM' — OK")

-- ── Redo re-applies the override ──────────────────────────────────────────
command_manager.redo()
assert(header_label() == "Boom Op",
    "redo must re-apply the override; got " .. header_label())
print("  redo re-applies 'Boom Op' — OK")

-- ── Clearing the name (empty input) reverts to the derived label ──────────
local r2 = command_manager.execute("SetTrackName", {
    track_id = "trk", name = "   ", project_id = "proj",
})
assert(r2 and r2.success, "SetTrackName clear failed")
assert(header_label() == "BOOM",
    "clearing the name must revert to the derived label; got " .. header_label())
print("  clear (whitespace) reverts to derived label — OK")

-- Undo of the clear restores the override.
command_manager.undo()
assert(header_label() == "Boom Op",
    "undo of clear must restore the override; got " .. header_label())
print("  undo of clear restores 'Boom Op' — OK")

print("\n✅ test_set_track_name.lua passed")
