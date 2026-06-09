#!/usr/bin/env luajit
--- Regression: after timeline_state.clear() leaves the strip with no
--- displayed tab, subsequent persistence requests (e.g. from DeselectAll
--- or any selection-mutating command) MUST be no-ops rather than
--- assert-crashing on "no displayed tab on strip".
---
--- Live symptom (TSO 2026-05-17): closing the source tab via
--- ShowSourceTab's no-master path called core.clear(); a moments-later
--- DeselectAll fired persist_selection_state → core.persist_state_to_db
--- → flush_state_to_db → assert "no displayed tab on strip".
---
--- Domain contract: persistence writes to the displayed sequence's row.
--- If there is no displayed sequence, there is nothing to persist;
--- silently no-op. The strip pointer IS the model's "is there a
--- displayed tab" property — persistence checks it on entry.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_clear_displayed_gates_persistence.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_clear_displayed_gates_persistence.db"
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

-- Drop the displayed tab via the public clear (the path ShowSourceTab
-- and Toggle take when no source master is loaded).
timeline_state.clear()
assert(timeline_state.get_displayed_tab_id() == nil,
    "after clear, displayed tab pointer must be nil")

-- ── The bug-bait: with no displayed tab, persist must be a silent no-op,
--    not an assert.
local ok, err = pcall(timeline_state.persist_state_to_db, true)
assert(ok, string.format(
    "persist_state_to_db with no displayed tab must NOT assert — it must "
    .. "silently no-op (the model says: no displayed → nothing to write). "
    .. "Got error: %s", tostring(err)))
print("  ✓ persist_state_to_db is a no-op when no displayed tab")

-- Same for the debounced (force=false) path.
local ok2, err2 = pcall(timeline_state.persist_state_to_db)
assert(ok2, string.format(
    "persist_state_to_db (debounced) with no displayed tab must NOT assert. "
    .. "Got: %s", tostring(err2)))
print("  ✓ persist_state_to_db (debounced) no-ops when no displayed tab")

-- And the higher-level path that fires on selection commands.
timeline_state.set_selection({})
local ok3, err3 = pcall(timeline_state.set_edge_selection, {})
assert(ok3, string.format(
    "set_edge_selection after clear must not assert via persistence. "
    .. "Got: %s", tostring(err3)))
print("  ✓ selection mutation after clear does not crash")

print("\n✅ test_clear_displayed_gates_persistence.lua passed")
