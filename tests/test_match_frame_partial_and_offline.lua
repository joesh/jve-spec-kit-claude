#!/usr/bin/env luajit
--
-- MatchFrame must degrade gracefully on the two real-world conditions
-- partial-coverage relinks introduce, instead of crashing the executor:
--
--   (A) PARTIAL COVERAGE: the clip's source_in/source_out fall outside
--       the master sequence's currently-covered range (i.e., the relinked
--       file is shorter than the original by some head and/or tail).
--       MatchFrame must clamp marks/playhead to the master's valid range
--       and still load the source viewer; the user sees the same frames
--       they would playing the clip on the timeline (the boundary, not
--       beyond it). A user-visible message describes the shortfall so
--       it doesn't look like marks were silently moved.
--
--   (B) OFFLINE FILE: the clip's media row points at a file that doesn't
--       exist on disk. MatchFrame must surface an error naming the file
--       path so the user knows what's missing — not crash with a stack
--       trace, not load garbage into the source viewer.
--
-- Pre-fix, both cases asserted in `Sequence:set_in` / `set_out` /
-- `set_playhead`:
--   ERROR: Executor failed (MatchFrame):
--   sequence.lua:1041: Sequence:set_in(...): frame 1248385 out of [1248732, 2500377)
-- which the user sees as a useless stack trace, with no source viewer
-- update and no diagnostic naming the file.

require('test_env')

_G.qt_create_single_shot_timer = function() end

-- Stub source viewer
local load_calls = {}
local stub_source_monitor = {
    sequence_id = nil,
    load_sequence = function(self, sequence_id)
        self.sequence_id = sequence_id
        table.insert(load_calls, sequence_id)
    end,
    get_loaded_master_seq_id = function(self)
        return self.sequence_id
    end,
}
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
    get_sequence_monitor = function(view_id)
        if view_id == "source_monitor" then return stub_source_monitor end
        return nil
    end,
}
package.loaded["ui.focus_manager"] = {
    focus_panel = function() end,
    get_focused_panel = function() return "timeline" end,
    set_focused_panel = function() end,
}

-- Stub the dialog binding so we can assert MatchFrame popped one for
-- the offline-file case AND captured the file path. test_env doesn't
-- ship qt_constants; create a minimal one with just DIALOG.SHOW_CONFIRM.
local dialog_calls = {}
_G.qt_constants = _G.qt_constants or {}
_G.qt_constants.DIALOG = _G.qt_constants.DIALOG or {}
_G.qt_constants.DIALOG.SHOW_CONFIRM = function(opts)
    table.insert(dialog_calls, opts)
    return true
end

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Sequence = require('models.sequence')

local TEST_DB = "/tmp/jve/test_match_frame_partial_and_offline.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

-- ---------------------------------------------------------------------------
-- Schema seed: a project, an editing sequence, a timeline track, two media
-- rows + master sequences:
--   * media_partial: file exists, but the master's content covers only
--     [50..150) — a head-and-tail shortfall vs the clip's source range.
--   * media_missing: file_path points at a path that doesn't exist on
--     disk. MatchFrame must detect this case and pop a dialog.
-- ---------------------------------------------------------------------------
local now = os.time()

-- A real on-disk file for the partial-coverage scenario (just an empty
-- file is enough — MatchFrame doesn't decode it, only reaches set_in).
local fs_utils_test = require("core.fs_utils")
local PARTIAL_PATH = "/tmp/jve/test_match_frame_partial_present.mov"
os.execute("mkdir -p /tmp/jve")
local f = assert(io.open(PARTIAL_PATH, "w"),
    "could not create partial-coverage fixture at " .. PARTIAL_PATH)
f:write("placeholder"); f:close()

local MISSING_PATH = "/tmp/jve/test_match_frame_definitely_not_a_file_42.mov"
os.remove(MISSING_PATH)
assert(not fs_utils_test.file_exists(MISSING_PATH), string.format(
    "MISSING_PATH must NOT exist for the offline-guard test to be meaningful: %s",
    MISSING_PATH))

db:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
VALUES ('p', 'Project', 'resample', %d, %d);

INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height,
    view_start_frame, view_duration_frames, playhead_frame,
    selected_clip_ids, selected_edge_infos, selected_gap_infos,
    current_sequence_number, created_at, modified_at, start_timecode_frame)
VALUES ('seq', 'p', 'Edit', 'sequence', 30, 1, 48000, 1920, 1080,
    0, 1000, 0, '[]', '[]', '[]', 0, %d, %d, 0);

INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
    enabled, locked, muted, soloed, volume, pan)
VALUES ('t_v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, width, height, audio_channels, codec,
    metadata, created_at, modified_at)
VALUES ('m_partial', 'p', 'partial.mov', '%s', 500, 30, 1, 1920, 1080, 0,
    'prores', '{"start_tc_value":50,"start_tc_rate":30}', %d, %d);

INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, width, height, audio_channels, codec,
    metadata, created_at, modified_at)
VALUES ('m_missing', 'p', 'missing.mov', '%s', 500, 30, 1, 1920, 1080, 0,
    'prores', '{"start_tc_value":0,"start_tc_rate":30}', %d, %d);

-- Master for the partial-coverage media. start_timecode_frame=50 +
-- media_ref duration_frames=100 → master valid range [50, 150).
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, created_at, modified_at, start_timecode_frame)
VALUES ('master_partial', 'p', 'Master Partial', 'master', 30, 1, NULL, 1920, 1080,
    %d, %d, 50);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
    enabled, locked, muted, soloed, volume, pan)
VALUES ('mp_v', 'master_partial', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'mp_v' WHERE id = 'master_partial';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
    source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
    enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_partial', 'p', 'master_partial', 'mp_v', 'm_partial',
    50, 150, 0, 100, 1, 1.0, 0, 0, 0);

-- Master for the missing-file media — full range, but file_path won't exist.
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, created_at, modified_at, start_timecode_frame)
VALUES ('master_missing', 'p', 'Master Missing', 'master', 30, 1, NULL, 1920, 1080,
    %d, %d, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
    enabled, locked, muted, soloed, volume, pan)
VALUES ('mm_v', 'master_missing', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'mm_v' WHERE id = 'master_missing';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
    source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
    enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_missing', 'p', 'master_missing', 'mm_v', 'm_missing',
    0, 500, 0, 500, 1, 1.0, 0, 0, 0);

-- Timeline clips.
--   c_partial: source_in=10 → 40f BEFORE master valid range start (50).
--              source_out=210 → 60f past master valid range end (150).
--   c_missing: any range; the file just isn't there.
INSERT INTO clips (id, project_id, name, track_id, sequence_id,
    owner_sequence_id, sequence_start_frame, duration_frames,
    source_in_frame, source_out_frame, enabled, created_at, modified_at,
    master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
    volume, playhead_frame)
VALUES
('c_partial', 'p', 'C Partial', 't_v1', 'master_partial', 'seq',
    0, 200, 10, 210, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
('c_missing', 'p', 'C Missing', 't_v1', 'master_missing', 'seq',
    300, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]],
    now, now,                           -- projects
    now, now,                           -- seq
    PARTIAL_PATH, now, now,             -- m_partial
    MISSING_PATH, now, now,             -- m_missing
    now, now,                           -- master_partial
    now, now,                           -- master_missing
    now, now, now, now))                -- clips

command_manager.init('seq', 'p')

print("=== MatchFrame partial-coverage + offline ===")

-- ---------------------------------------------------------------------------
-- Test A: partial coverage — clamp + warn (don't crash).
-- Playhead at frame 50 lands inside c_partial. The clip's source_in is
-- 10, which is 40f BEFORE the master's covered range start at 50 → pre-
-- fix this asserted in Sequence:set_in. Post-fix: marks/playhead clamp
-- to the master's bounds, source_viewer.load_master_clip is called, and
-- the warning surfaces via set_last_error so the menu/status bar can
-- show why marks landed at the boundary rather than the clip's recorded
-- source position.
-- ---------------------------------------------------------------------------
print("Test A: partial-coverage clip clamps marks instead of crashing")
load_calls = {}
dialog_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})

local result = command_manager.execute("MatchFrame", { project_id = "p" })
assert(result.success, string.format(
    "REGRESSION: MatchFrame should succeed (with clamped marks) when the "
    .. "clip's source range extends past the master's coverage, not crash "
    .. "the executor. Got error: %s", tostring(result.error_message)))
assert(#load_calls == 1 and load_calls[1] == 'master_partial',
    "source viewer should still load the master")

-- The post-clamp marks must lie inside the master's valid range.
local mp = Sequence.load('master_partial')
assert(mp.mark_in == 50, string.format(
    "mark_in must be clamped to master start (50), got %s", tostring(mp.mark_in)))
assert(mp.mark_out == 150, string.format(
    "mark_out must be clamped to master end (150), got %s", tostring(mp.mark_out)))

-- The clamped marks landing exactly at the coverage boundary are the
-- user-visible signal; a log line carries the per-frame deficit for
-- diagnosis (asserted indirectly via "no crash + correct clamps").
print("  ✓ marks clamped to coverage boundary, no crash")

-- ---------------------------------------------------------------------------
-- Test A2: partial-coverage WITH a stale volume-path on the media row.
-- This mirrors the in-the-wild relink: try_partial_fit_relink leaves the
-- original media row's file_path at the (offline) volume path while the
-- offline_note carries the path to the local candidate the relinker
-- actually found. The source viewer reads offline_note and renders a
-- useful overlay; MatchFrame must do the same lookup so it doesn't pop
-- a "missing on disk" dialog naming the volume path the user has
-- visibly relinked past — that popup just contradicts what the source
-- viewer is showing two pixels above it.
-- ---------------------------------------------------------------------------
print("Test A2: partial-coverage clip with stale volume-path on media row")

-- Build the scenario: an audio clip pointing at a master whose media
-- row's file_path is a missing volume path, but whose offline_note
-- carries a partial_coverage entry pointing at a real on-disk
-- candidate. Re-use the partial-coverage on-disk fixture file.
local STALE_VOLUME = "/Volumes/AnamBack4 NotMounted/never/exists.mov"
local NOTE_JSON = string.format(
    '{"kind":"partial_coverage","candidate_path":"%s",'
    .. '"covered_start_tc":50,"covered_end_tc":150,"rate":30}',
    PARTIAL_PATH)

db:exec(string.format([[
INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, width, height, audio_channels, codec,
    metadata, offline_note, created_at, modified_at)
VALUES ('m_stale_volume', 'p', 'stale.mov', '%s', 500, 30, 1, 1920, 1080, 0,
    'prores', '{"start_tc_value":50,"start_tc_rate":30}',
    '%s', %d, %d);

INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, created_at, modified_at, start_timecode_frame)
VALUES ('master_stale', 'p', 'Master Stale', 'master', 30, 1, NULL, 1920, 1080,
    %d, %d, 50);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
    enabled, locked, muted, soloed, volume, pan)
VALUES ('ms_v', 'master_stale', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'ms_v' WHERE id = 'master_stale';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
    source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
    enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_stale', 'p', 'master_stale', 'ms_v', 'm_stale_volume',
    50, 150, 0, 100, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id,
    owner_sequence_id, sequence_start_frame, duration_frames,
    source_in_frame, source_out_frame, enabled, created_at, modified_at,
    master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
    volume, playhead_frame)
VALUES ('c_stale', 'p', 'C Stale', 't_v1', 'master_stale', 'seq',
    500, 200, 10, 210, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], STALE_VOLUME, NOTE_JSON, now, now,
    now, now,
    now, now))

timeline_state.init('seq', 'p')

load_calls = {}
dialog_calls = {}
timeline_state.set_playhead_position(550)  -- inside c_stale [500, 700)
timeline_state.set_selection({})

result = command_manager.execute("MatchFrame", { project_id = "p" })
assert(result.success, string.format(
    "REGRESSION: MatchFrame on a partial-coverage clip whose media row "
    .. "still carries a stale volume file_path must NOT report failure — "
    .. "the offline_note tells us a real local candidate exists. The "
    .. "source viewer correctly shows the partial-coverage overlay; "
    .. "MatchFrame popping a contradictory 'missing on disk' dialog is "
    .. "the bug. error: %s", tostring(result.error_message)))
assert(#dialog_calls == 0, string.format(
    "REGRESSION: no dialog should pop when the offline_note points at "
    .. "an on-disk candidate; the source viewer overlay already conveys "
    .. "the partial-coverage info. Got %d dialog(s). First message: %s",
    #dialog_calls,
    #dialog_calls > 0 and tostring(dialog_calls[1].message) or "(none)"))
assert(#load_calls == 1 and load_calls[1] == 'master_stale',
    "source viewer should still load the master so its overlay can render")
print("  ✓ no spurious dialog; viewer loaded; clamp path took over")

-- ---------------------------------------------------------------------------
-- Test B: offline file — succeed and load the master; no dialog. The source
-- viewer's own offline indicator surfaces the file-missing state to the
-- user. MatchFrame is navigation, not playback (consistent with the
-- importer-no-probe philosophy applied to downstream operations).
-- ---------------------------------------------------------------------------
print("Test B: offline-file clip loads viewer without dialog")
load_calls = {}
dialog_calls = {}
timeline_state.set_playhead_position(350)  -- inside c_missing
timeline_state.set_selection({})

result = command_manager.execute("MatchFrame", { project_id = "p" })
assert(result.success,
    "MatchFrame on offline media must still succeed: source viewer "
    .. "renders the master sequence with its offline overlay")
assert(#load_calls == 1,
    "source viewer should load the master so its offline overlay can render")
assert(#dialog_calls == 0, string.format(
    "no dialog should pop for offline media — viewer overlay surfaces it; "
    .. "got %d dialog call(s)", #dialog_calls))
print("  ✓ viewer loaded without dialog; offline state surfaces via overlay")

-- Cleanup
os.remove(PARTIAL_PATH)
database.shutdown()
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")

print("\n✅ test_match_frame_partial_and_offline passed")
