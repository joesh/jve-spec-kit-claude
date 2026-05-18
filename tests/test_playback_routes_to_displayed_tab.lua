#!/usr/bin/env luajit

-- Regression: when the timeline panel is showing the source tab, TogglePlay
-- must drive the source_monitor's engine (the master being viewed) — not
-- the record-bonded timeline_monitor. Symptom (2026-05-13): pressing space
-- while the source tab is displayed played the active record sequence
-- instead of the master.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end; return nil end

print("=== test_playback_routes_to_displayed_tab.lua ===")

local command_manager = require("core.command_manager")
local database        = require("core.database")

-- Minimal DB so command_manager.init has a real project/sequence.
local DB = "/tmp/jve/test_playback_routes_displayed.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('proj','P','resample','{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
        VALUES ('rec','proj','Rec','sequence',24,1,48000,1920,1080,0,0,300,%d,%d),
               ('src','proj','SrcMaster','master',24,1,NULL,1920,1080,0,0,300,%d,%d);
]], now, now, now, now, now, now))

-- Two distinct engines so we can prove which one received play().
local function make_monitor(view_id, seq_id)
    local engine = {
        played = false,
        is_playing = function(self) return self.played end,
        play = function(self) self.played = true end,
        stop = function(self) self.played = false end,
    }
    return {
        view_id = view_id,
        sequence_id = seq_id,
        total_frames = 300,
        engine = engine,
    }
end

local source_monitor   = make_monitor("source_monitor",   "src")
local timeline_monitor = make_monitor("timeline_monitor", "rec")

-- Stub panel_manager: active monitor = timeline_monitor (timeline panel focused).
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return timeline_monitor end,
    get_sequence_monitor = function(view_id)
        if view_id == "source_monitor"   then return source_monitor   end
        if view_id == "timeline_monitor" then return timeline_monitor end
        error("unexpected view_id "..tostring(view_id))
    end,
}

command_manager.init("rec", "proj")

-- Stub strip AFTER command_manager.init (which loads timeline_state and
-- installs the real strip into strip_holder at module-load time).
local strip_holder = require("ui.timeline.state.strip_holder")
local source_tab = { kind = "source", sequence_id = "src" }
local record_tab = { kind = "record", sequence_id = "rec" }
local strip = {
    _displayed = source_tab,
    get_displayed = function(self) return self._displayed end,
}
strip_holder.set(strip)

-- ── Case A: source tab displayed → play drives source_monitor ────────────
print("-- (a) source tab displayed --")
local r1 = command_manager.execute("TogglePlay", { project_id = "proj" })
assert(r1 and r1.success, "TogglePlay must succeed: "..tostring(r1 and r1.error_message))
assert(source_monitor.engine.played == true,
    "FAIL: source tab displayed but source_monitor.engine.play() was not called")
assert(timeline_monitor.engine.played == false,
    "FAIL: timeline_monitor played while source tab was displayed — transport "
    .. "must follow the displayed tab, not the active record")
print("  source_monitor played, timeline_monitor untouched — OK")

-- Reset.
source_monitor.engine.played   = false
timeline_monitor.engine.played = false

-- ── Case B: record tab displayed → play drives timeline_monitor ─────────
print("-- (b) record tab displayed --")
strip._displayed = record_tab
local r2 = command_manager.execute("TogglePlay", { project_id = "proj" })
assert(r2 and r2.success, "TogglePlay must succeed: "..tostring(r2 and r2.error_message))
assert(timeline_monitor.engine.played == true,
    "FAIL: record tab displayed but timeline_monitor.engine.play() was not called")
assert(source_monitor.engine.played == false,
    "FAIL: source_monitor played while record tab was displayed")
print("  timeline_monitor played, source_monitor untouched — OK")

print("\n✅ test_playback_routes_to_displayed_tab.lua passed")
