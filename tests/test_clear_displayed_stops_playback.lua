#!/usr/bin/env luajit
--- Regression: when timeline_state.clear() blanks the timeline (no
--- displayed sequence), any playback engine currently transporting that
--- sequence MUST stop. Otherwise a stale playback tick (or deferred park)
--- carrying the closed sequence's playhead crashes into the new
--- (possibly nonexistent) sequence's extent.
---
--- Live symptom (TSO 2026-05-17): PlaybackController::Park C++ assert
---     "frame >= m_start_frame"  (frame=122559, start=63164)
--- fired from a single_shot_timer callback after the source tab (extent
--- 215828, playhead 122559) was closed and the displayed sequence
--- collapsed to a smaller record sequence.
---
--- Domain contract: core.clear() emits "displayed_tab_cleared". Any
--- subsystem that drives transport against the displayed sequence
--- (playback engines, deferred viewer seeks) listens and shuts down.
--- The signal is the canonical "no displayed" boundary.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_clear_displayed_stops_playback.lua ===")

local Signals = require("core.signals")

-- Capture every displayed_tab_cleared emission. The signal IS the contract
-- — every "no displayed" transition (close last tab, ShowSourceTab with no
-- master, Toggle src/rec with no master) routes through it.
local cleared_log = {}
Signals.connect("displayed_tab_cleared", function(prev_seq_id)
    table.insert(cleared_log, prev_seq_id)
end)

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_clear_displayed_stops_playback.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))

local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('tr', 'rec', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

timeline_state.reset()
timeline_state.init("rec", "p")
command_manager.init("rec", "p")

assert(timeline_state.get_displayed_tab_id() == "rec",
    "fixture: rec must be displayed before clear")

local n_before = #cleared_log
timeline_state.clear()

assert(#cleared_log == n_before + 1, string.format(
    "core.clear() must emit displayed_tab_cleared exactly once; "
    .. "got %d new emissions", #cleared_log - n_before))
assert(cleared_log[#cleared_log] == "rec", string.format(
    "displayed_tab_cleared must carry the prev displayed seq_id so "
    .. "listeners can identify which engine to stop; got %s",
    tostring(cleared_log[#cleared_log])))
print("  ✓ displayed_tab_cleared emitted with prev seq_id=rec")

-- Idempotence: clearing again when nothing is displayed must NOT re-emit
-- (no transition happened). Avoids spurious stop calls on engines.
local n_idem = #cleared_log
timeline_state.clear()
assert(#cleared_log == n_idem, string.format(
    "core.clear() must NOT emit displayed_tab_cleared when there was "
    .. "no displayed tab to begin with (no transition). Got %d extra emissions",
    #cleared_log - n_idem))
print("  ✓ no spurious emission when already blank")

print("\n✅ test_clear_displayed_stops_playback.lua passed")
