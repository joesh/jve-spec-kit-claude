#!/usr/bin/env luajit

-- Regression: the timeline_state module must expose a `clear()` primitive that
-- leaves the project identity intact but removes any active-sequence reference.
-- This is the foundation for the no-active-sequence state (feature 010):
-- closing the last tab, opening a project without tab metadata, and deleting
-- the active sequence all route through this clear path.
--
-- Domain behavior under test (expected values derived from the feature spec,
-- not from code tracing):
--   * When no sequence is active, queries for the current sequence must return
--     nil so pull-based views render blank instead of showing stale content.
--   * Clearing must not tear down the project identity — the editor is still
--     inside the project; only the timeline is blank.
--   * Re-entering an active-sequence state after clearing must work with the
--     same model API that is used from a fresh open.
--   * Consumers that react to state changes must be notified on clear so the
--     inspector/monitors re-pull.

require('test_env')

local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')

-- Minimal DB fixture: a project with two sequences that each have a track,
-- so init() can load tracks for either one.
local DB_PATH = "/tmp/jve/test_timeline_state_clear.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init failed")
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ  = "prj-clear-test"
local SEQ_A = "seq-clear-a"
local SEQ_B = "seq-clear-b"

assert(conn:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
VALUES ('%s', 'Clear Test', 'resample', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
    created_at, modified_at)
VALUES
('%s', '%s', 'Seq A', 'sequence', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now'), strftime('%%s','now')),
('%s', '%s', 'Seq B', 'sequence', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES
('tr-a', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
('tr-b', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], PROJ, SEQ_A, PROJ, SEQ_B, PROJ, SEQ_A, SEQ_B)), "seed insert failed")

print("=== timeline_state.clear() contract ===")

-- 1. After init → clear, sequence reference is gone, project identity survives.
timeline_state.init(SEQ_A, PROJ)
assert(timeline_state.get_sequence_id() == SEQ_A,
    "precondition: get_sequence_id should return the initialised sequence")
assert(timeline_state.get_project_id() == PROJ,
    "precondition: get_project_id should return the initialised project")

timeline_state.clear()

assert(timeline_state.get_sequence_id() == nil,
    "after clear(), get_sequence_id must return nil so views render blank; "
    .. "got " .. tostring(timeline_state.get_sequence_id()))
assert(timeline_state.get_project_id() == PROJ,
    "clear() must not drop the project identity; got "
    .. tostring(timeline_state.get_project_id()))
print("  OK: clear leaves project intact, removes sequence reference")

-- 2. Re-entering a sequence after clear uses the same init() path.
timeline_state.init(SEQ_B, PROJ)
assert(timeline_state.get_sequence_id() == SEQ_B,
    "after init following clear, get_sequence_id must return the new sequence; "
    .. "got " .. tostring(timeline_state.get_sequence_id()))
print("  OK: init() after clear() re-enters active-sequence state")

-- 3. Listeners registered before clear must fire when clear runs, so consumers
--    that pull on state changes see the transition.
timeline_state.init(SEQ_A, PROJ)
local listener_calls = 0
timeline_state.add_listener(function() listener_calls = listener_calls + 1 end)
local calls_before_clear = listener_calls
timeline_state.clear()
assert(listener_calls > calls_before_clear,
    "clear() must invoke state listeners at least once so consumers re-pull; "
    .. "calls before=" .. calls_before_clear .. " after=" .. listener_calls)
print("  OK: listeners are notified on clear")

-- 4. Repeat clear() remains a no-op — idempotent for cascading delete flows.
timeline_state.clear()
timeline_state.clear()
assert(timeline_state.get_sequence_id() == nil,
    "repeated clear() must remain a no-op after the first clear")
print("  OK: clear() is idempotent")

print("✅ test_timeline_state_clear.lua passed")
