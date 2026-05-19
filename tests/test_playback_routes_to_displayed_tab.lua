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

-- 017 transport-target routing: TogglePlay routes via
-- core.playback.transport, which picks source vs record engine based on
-- the displayed tab kind (or source-monitor focus). We initialize
-- transport and swap its two engines for stubs that record play() calls,
-- so we can assert which side received the transport command without
-- pulling in the full PlaybackEngine + C++ FFI surface.
command_manager.init("rec", "proj")

local transport = require("core.playback.transport")
-- command_manager.init may have already bootstrapped transport; rebind
-- engines to stubs after a defensive re-init.
if transport.is_bootstrapped() then transport.shutdown() end
transport.init("proj")
local function make_stub_engine(seq_id)
    return {
        loaded_sequence_id = seq_id,
        played = false,
        is_playing = function(self) return self.played end,
        play = function(self) self.played = true end,
        stop = function(self) self.played = false end,
    }
end
local src_eng = make_stub_engine("src")
local rec_eng = make_stub_engine("rec")
transport.source_engine = src_eng
transport.record_engine = rec_eng

-- Drive transport.get_target() via the displayed-tab projection. Source
-- monitor isn't focused (focus_manager returns "timeline"); the displayed
-- tab kind alone decides routing.
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
}
local displayed_kind = "source"
package.loaded["ui.timeline.timeline_state"] =
    setmetatable({ get_displayed_tab_kind = function() return displayed_kind end },
                 { __index = require("ui.timeline.timeline_state") })

-- ── Case A: source tab displayed → play drives transport.source_engine ──
print("-- (a) source tab displayed --")
local r1 = command_manager.execute("TogglePlay", { project_id = "proj" })
assert(r1 and r1.success, "TogglePlay must succeed: "..tostring(r1 and r1.error_message))
assert(src_eng.played == true,
    "FAIL: source tab displayed but transport.source_engine.play() was not called")
assert(rec_eng.played == false,
    "FAIL: record engine played while source tab was displayed — transport "
    .. "must follow the displayed tab, not the active record")
print("  source_engine played, record_engine untouched — OK")

-- Reset.
src_eng.played = false
rec_eng.played = false

-- ── Case B: record tab displayed → play drives transport.record_engine ──
print("-- (b) record tab displayed --")
displayed_kind = "record"
local r2 = command_manager.execute("TogglePlay", { project_id = "proj" })
assert(r2 and r2.success, "TogglePlay must succeed: "..tostring(r2 and r2.error_message))
assert(rec_eng.played == true,
    "FAIL: record tab displayed but transport.record_engine.play() was not called")
assert(src_eng.played == false,
    "FAIL: source engine played while record tab was displayed")
print("  record_engine played, source_engine untouched — OK")

print("\n✅ test_playback_routes_to_displayed_tab.lua passed")
