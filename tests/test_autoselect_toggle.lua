#!/usr/bin/env luajit

-- 015 Phase 4: tracks.autoselect (Avid track auto-select / Premiere track
-- targeting). Per spec FR-038 the rec-patch-id button toggles this flag.
-- It defaults ON (new tracks participate in selection-driven ops); the
-- user opts out per-track. Behavior under test:
--
--   T1: new track defaults autoselect=true.
--   T2: ToggleTrackPreference(autoselect=false) persists.
--   T3: re-loading the track from DB shows autoselect=false.
--   T4: toggling back to true persists; round-trip stable.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local command_manager = require("core.command_manager")
local Track           = require("models.track")
local ripple_layout   = require("tests.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_autoselect_toggle.lua ===")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_autoselect_toggle.db",
    tracks = {
        order = {"v1", "a1"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
    },
    clips = { order = {} },
})

-- T1: new track defaults to autoselect=true.
local v1 = Track.load("trk_v1")
assert(v1, "trk_v1 must load")
assert(v1.autoselect == true, string.format(
    "FAIL T1: new track defaults autoselect=true; got %s", tostring(v1.autoselect)))
print("  T1 OK: new track has autoselect=true")

-- T2: toggle autoselect via ToggleTrackPreference.
local r = command_manager.execute("ToggleTrackPreference", {
    track_id = "trk_v1", property = "autoselect", project_id = layout.project_id,
})
assert(r and r.success, "ToggleTrackPreference failed: "
    .. tostring(r and r.error_message))
print("  T2 OK: ToggleTrackPreference(autoselect) command succeeded")

-- T3: track reload reflects the change.
local v1_after = Track.load("trk_v1")
assert(v1_after.autoselect == false, string.format(
    "FAIL T3: track did not persist autoselect=false; got %s",
    tostring(v1_after.autoselect)))
print("  T3 OK: track persists autoselect=false")

-- T4: toggle again, round-trip back to true.
local r2 = command_manager.execute("ToggleTrackPreference", {
    track_id = "trk_v1", property = "autoselect", project_id = layout.project_id,
})
assert(r2 and r2.success, "ToggleTrackPreference (second) failed")
local v1_round = Track.load("trk_v1")
assert(v1_round.autoselect == true, string.format(
    "FAIL T4: round-trip autoselect=true; got %s", tostring(v1_round.autoselect)))
print("  T4 OK: round-trip autoselect back to true")

print("\n✅ test_autoselect_toggle.lua passed")
