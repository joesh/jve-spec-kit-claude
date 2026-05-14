#!/usr/bin/env luajit

-- Regression: ToggleTrackPreference flips tracks.locked in the DB and
-- emits track_preference_changed, but timeline_core_state's in-memory
-- cache (data.state.tracks — the source the timeline view renderer pulls
-- from) was never synced. The renderer's locked-track hash overlay reads
-- track.locked at draw time; without this sync the diagonal hashes only
-- appeared/disappeared after an editor restart (Joe 2026-05-13).
--
-- Black-box: drive the public command, then verify the in-memory row
-- reflects the new value through the public getter (timeline_state.get_track_by_id).

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end; return nil end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_track_lock_state_syncs_on_signal.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_track_lock_state_syncs_on_signal.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "schema init failed")
local db = database.get_connection()

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p','P','resample',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('s','p','S','sequence',24,1,48000,1920,1080,0,0,300,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES
      ('v1','s','V1','VIDEO',1,1,0,0,0,1.0,0.0,'off',1),
      ('a1','s','A1','AUDIO',1,1,0,0,0,1.0,0.0,'off',1);
]], now, now, now, now))

command_manager.init('s', 'p')

local timeline_state = require("ui.timeline.timeline_state")

-- ── Initial state: all unlocked ───────────────────────────────────────────
local v1 = timeline_state.get_track_by_id("v1")
assert(v1, "test setup: v1 missing in timeline_state")
assert(v1.locked == false,
    "test setup: v1 should start unlocked; got " .. tostring(v1.locked))

-- ── Toggle lock on v1 via the canonical command ───────────────────────────
print("-- toggling v1 lock ON --")
local r = command_manager.execute("ToggleTrackPreference", {
    track_id = "v1", property = "locked", project_id = "p",
})
assert(r and r.success, "ToggleTrackPreference failed: "
    .. tostring(r and r.error_message))

-- DB updated.
local s = db:prepare("SELECT locked FROM tracks WHERE id = 'v1'")
assert(s:exec() and s:next())
assert(s:value(0) == 1, "DB: v1.locked must be 1 after toggle")
s:finalize()

-- In-memory cache updated — this is what the renderer reads on every paint.
local v1_after = timeline_state.get_track_by_id("v1")
assert(v1_after.locked == true, string.format(
    "FAIL: in-memory v1.locked must be true after ToggleTrackPreference; got %s. "
    .. "The lock-hash overlay renders from this in-memory row each paint; "
    .. "without the listener sync the overlay only flips on editor restart.",
    tostring(v1_after.locked)))
print("  in-memory v1.locked synced to true — OK")

-- A1 untouched.
local a1 = timeline_state.get_track_by_id("a1")
assert(a1.locked == false or a1.locked == 0 or a1.locked == nil,
    "FAIL: a1.locked should still be unlocked; got " .. tostring(a1.locked))

-- ── Toggle back off ──────────────────────────────────────────────────────
print("-- toggling v1 lock OFF --")
local r2 = command_manager.execute("ToggleTrackPreference", {
    track_id = "v1", property = "locked", project_id = "p",
})
assert(r2 and r2.success)
local v1_off = timeline_state.get_track_by_id("v1")
assert(v1_off.locked == false, string.format(
    "FAIL: in-memory v1.locked must be false after second toggle; got %s",
    tostring(v1_off.locked)))
print("  in-memory v1.locked synced back to false — OK")

-- ── Same flow for muted to prove handler covers all 4 props ──────────────
print("-- toggling a1 muted ON --")
command_manager.execute("ToggleTrackPreference", {
    track_id = "a1", property = "muted", project_id = "p",
})
local a1_muted = timeline_state.get_track_by_id("a1")
assert(a1_muted.muted == true,
    "FAIL: muted property should sync via same listener; got "
    .. tostring(a1_muted.muted))
print("  muted prop also syncs — OK")

print("\n✅ test_track_lock_state_syncs_on_signal.lua passed")
