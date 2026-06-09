#!/usr/bin/env luajit

-- Regression: opening a different project must leave the timeline model
-- empty so pull-based views render blank. Before this fix, `project_changed`
-- only cleared sequence_id/project_id — the old project's tracks, clips,
-- selection, playhead, and viewport stayed resident and the timeline kept
-- displaying the previous project's content (Feature 010: projects can open
-- with no active sequence, so `load_sequence` does not always follow the
-- signal to refill state).
--
-- Domain behavior under test (expected values from the feature contract,
-- not from tracing the implementation):
--   * After a project change, asking the timeline "what should I display?"
--     must yield nothing: no tracks, no clips, no selection, no playhead,
--     no sequence/project identity, no sequence frame rate.
--   * Listeners registered before the change must fire, so views re-pull
--     and paint the now-empty model.

require('test_env')

local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')
local data = require('ui.timeline.state.timeline_state_data')
local Signals = require('core.signals')

local DB_PATH = "/tmp/jve/test_timeline_state_resets_on_project_change.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init failed")
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ_A = "prj-A"
local SEQ_A  = "seq-A"

assert(conn:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
VALUES ('%s', 'Project A', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
    created_at, modified_at)
VALUES ('%s', '%s', 'Seq A', 'sequence', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('tr-A', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], PROJ_A, SEQ_A, PROJ_A, SEQ_A)), "seed insert failed")

print("=== timeline state fully resets on project change ===")

-- Populate the timeline model with Project A's content.
timeline_state.init(SEQ_A, PROJ_A)
-- Spec 022 Phase 1.3f: tracks/clips live on the displayed tab cache.
local strip = timeline_state.get_tab_strip()
local displayed_a = strip:get_displayed()
assert(displayed_a and #displayed_a.cache.tracks > 0,
    "precondition: expected tracks loaded into Project A's displayed tab cache")

-- Simulate in-flight user state that ought to be gone after a project change.
-- Inject directly into the displayed tab cache so the post-clear assertions
-- prove the strip reset cleanly (no stale content). Per-sequence
-- view-state (playhead, viewport, scroll, frame_rate, tc origin) lives on
-- the cache post-H1 — not on data.state. Set values that aren't the
-- "natural defaults" so a half-reset leaves a fingerprint.
table.insert(displayed_a.cache.clips,
    { id = "c1", track_id = "tr-A", sequence_start = 0, duration = 100, clip_kind = "media" })
table.insert(displayed_a.cache.clips,
    { id = "c2", track_id = "tr-A", sequence_start = 200, duration = 50, clip_kind = "media" })
data.state.selected_clips = { displayed_a.cache.clips[1] }
data.state.selected_edges = { { clip_id = "c1", edge_type = "out" } }
displayed_a.cache.playhead_position = 12345
displayed_a.cache.viewport_start_time = 500
displayed_a.cache.viewport_duration = 999
displayed_a.cache.video_scroll_offset = 77
displayed_a.cache.audio_scroll_offset = 88

-- A view subscribes; it must be notified when the project changes so it
-- re-pulls the (now empty) model and repaints.
local listener_calls = 0
timeline_state.add_listener(function() listener_calls = listener_calls + 1 end)
local calls_before = listener_calls

-- Fire the project_changed signal (same path open_project.post_open_init uses).
Signals.emit("project_changed", "prj-B")

-- Post-condition: the model carries nothing from the previous project.
assert(timeline_state.get_project_id() == nil,
    "after project_changed, project_id must be cleared; got "
    .. tostring(timeline_state.get_project_id()))
assert(timeline_state.get_tab_strip():active_sequence_id() == nil,
    "after project_changed, sequence_id must be cleared; got "
    .. tostring(timeline_state.get_tab_strip():active_sequence_id()))
-- Strip reset means no displayed tab → reads return empty. Spec 022 Phase
-- 1.3f: tracks/clips live on tab cache, not data.state.
local strip_after = timeline_state.get_tab_strip()
assert(strip_after:get_displayed() == nil,
    "after project_changed, strip must carry no displayed tab")
assert(#strip_after:displayed_tracks() == 0,
    "after project_changed, displayed tracks must be empty")
assert(#strip_after:displayed_clips() == 0,
    "after project_changed, displayed clips must be empty")
assert(#data.state.selected_clips == 0,
    "after project_changed, selected_clips must be empty; got " .. #data.state.selected_clips)
assert(#data.state.selected_edges == 0,
    "after project_changed, selected_edges must be empty; got " .. #data.state.selected_edges)
assert(data.sequence == nil,
    "after project_changed, cached sequence model must be cleared")

-- Per-sequence view-state lives on the displayed tab's cache (H1). After
-- project_changed, the strip is reset to a fresh empty instance — no
-- displayed tab → getters return nil → views render blank. This is the
-- post-H1 invariant: the model can't leak per-sequence state across
-- projects because there is no per-sequence state outside a tab cache,
-- and the new project's strip starts with zero tabs.
assert(timeline_state.get_playhead_position() == nil,
    "after project_changed, playhead getter must return nil (no displayed tab); got "
    .. tostring(timeline_state.get_playhead_position()))
assert(timeline_state.get_viewport_start_time() == nil,
    "viewport_start_time getter must return nil; got "
    .. tostring(timeline_state.get_viewport_start_time()))
assert(timeline_state.get_viewport_duration() == nil,
    "viewport_duration getter must return nil; got "
    .. tostring(timeline_state.get_viewport_duration()))
assert(timeline_state.get_video_scroll_offset() == nil,
    "video_scroll_offset getter must return nil; got "
    .. tostring(timeline_state.get_video_scroll_offset()))
assert(timeline_state.get_audio_scroll_offset() == nil,
    "audio_scroll_offset getter must return nil; got "
    .. tostring(timeline_state.get_audio_scroll_offset()))
assert(timeline_state.get_sequence_frame_rate() == nil,
    "sequence_frame_rate getter must return nil; got "
    .. tostring(timeline_state.get_sequence_frame_rate()))
print("  OK: per-sequence and identity state cleared")

assert(listener_calls > calls_before,
    "after project_changed, listeners must fire at least once so views re-pull; "
    .. "calls before=" .. calls_before .. " after=" .. listener_calls)
print("  OK: listeners notified")

print("✅ test_timeline_state_resets_on_project_change.lua passed")
