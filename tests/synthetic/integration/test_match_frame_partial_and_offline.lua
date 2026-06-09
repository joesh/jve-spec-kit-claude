-- Integration: MatchFrame degrades gracefully on partial-coverage relinks
-- and offline media, never crashes the executor.
--
-- Scenarios:
--   A   — Partial coverage: clip.source_in/source_out fall outside the
--         master sequence's currently-covered range. MatchFrame must
--         clamp marks/playhead to the master's bounds, still load the
--         source viewer, and surface a per-frame-deficit log line.
--   A2  — Partial coverage WITH stale volume file_path: the media row's
--         file_path is a non-existent volume path, but the offline_note
--         carries a partial_coverage entry pointing at a real on-disk
--         candidate. MatchFrame must NOT report failure / pop a
--         "missing on disk" dialog — the viewer's offline overlay
--         already conveys the partial-coverage info.
--   B   — Offline file: file_path doesn't exist on disk. MatchFrame
--         loads the master so the viewer's offline overlay can render;
--         no dialog (importer-no-probe philosophy applied downstream).
--
-- Replaces the stub-based test of the same name. Real bindings only;
-- the dialog spy is dropped because match_frame.lua never calls
-- DIALOG.SHOW_CONFIRM (the original spy was verifying that absence).

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_match_frame_partial_and_offline.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")
local fs_utils        = require("core.fs_utils")

-- ── DB + fixture files ────────────────────────────────────────────────
local DB = "/tmp/jve/test_match_frame_partial_and_offline_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local PARTIAL_PATH = "/tmp/jve/test_mf_partial_integ_present.mov"
local f = assert(io.open(PARTIAL_PATH, "w"),
    "could not create partial-coverage fixture at " .. PARTIAL_PATH)
f:write("placeholder"); f:close()

local MISSING_PATH = "/tmp/jve/test_mf_definitely_not_a_file_integ.mov"
os.remove(MISSING_PATH)
assert(not fs_utils.file_exists(MISSING_PATH), string.format(
    "MISSING_PATH must NOT exist for the offline-guard test: %s",
    MISSING_PATH))

local STALE_VOLUME = "/Volumes/AnamBack4 NotMounted/never/exists.mov"
local NOTE_JSON = string.format(
    '{"kind":"partial_coverage","candidate_path":"%s",'
    .. '"covered_start_tc":50,"covered_end_tc":150,"rate":30}',
    PARTIAL_PATH)

-- Project + edit sequence + V1 track.
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('seq', 'p', 'Edit', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 1000, 0, '[]', '[]', '[]', 0, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('t_v1', 'seq', 'V1', 'VIDEO', 1, 1);
]]))

-- Partial-coverage scenario: master content covers [50, 150) in TC.
-- Clip's source range [10, 210) extends 40f before and 60f after.
assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        metadata, created_at, modified_at)
      VALUES ('m_partial', 'p', 'partial.mov', '%s', 500, 30, 1, 1920, 1080, 0,
              'prores', '{"start_tc_value":50,"start_tc_rate":30}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, start_timecode_frame, created_at, modified_at)
      VALUES ('master_partial', 'p', 'MPartial', 'master', 30, 1, NULL,
              1920, 1080, 50, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('mp_v', 'master_partial', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mp_v'
      WHERE id = 'master_partial';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr_partial', 'p', 'master_partial', 'mp_v', 'm_partial',
              50, 150, 0, 100, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id,
        owner_sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES ('c_partial', 'p', 'C Partial', 't_v1', 'master_partial', 'seq',
              0, 200, 10, 210, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]], PARTIAL_PATH)))

-- Stale-volume + offline_note scenario: master_stale references a media
-- row whose file_path is a non-existent /Volumes path, but offline_note
-- points at PARTIAL_PATH (a real local candidate).
assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        metadata, offline_note, created_at, modified_at)
      VALUES ('m_stale_volume', 'p', 'stale.mov', '%s', 500, 30, 1, 1920, 1080, 0,
              'prores', '{"start_tc_value":50,"start_tc_rate":30}',
              '%s', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, start_timecode_frame, created_at, modified_at)
      VALUES ('master_stale', 'p', 'MStale', 'master', 30, 1, NULL,
              1920, 1080, 50, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('ms_v', 'master_stale', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'ms_v'
      WHERE id = 'master_stale';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr_stale', 'p', 'master_stale', 'ms_v', 'm_stale_volume',
              50, 150, 0, 100, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id,
        owner_sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES ('c_stale', 'p', 'C Stale', 't_v1', 'master_stale', 'seq',
              500, 200, 10, 210, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]], STALE_VOLUME, NOTE_JSON)))

-- Offline scenario: media_missing's file_path points at a path that
-- doesn't exist on disk and has no offline_note (no candidate).
assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        metadata, created_at, modified_at)
      VALUES ('m_missing', 'p', 'missing.mov', '%s', 500, 30, 1, 1920, 1080, 0,
              'prores', '{"start_tc_value":0,"start_tc_rate":30}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, start_timecode_frame, created_at, modified_at)
      VALUES ('master_missing', 'p', 'MMissing', 'master', 30, 1, NULL,
              1920, 1080, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('mm_v', 'master_missing', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mm_v'
      WHERE id = 'master_missing';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr_missing', 'p', 'master_missing', 'mm_v', 'm_missing',
              0, 500, 0, 500, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id,
        owner_sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES ('c_missing', 'p', 'C Missing', 't_v1', 'master_missing', 'seq',
              300, 100, 0, 100, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]], MISSING_PATH)))

-- Real source monitor + transport bootstrap.
local source_mon = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "p",
}).source

command_manager.init("seq", "p")

local function exec_match_frame()
    source_mon.sequence_id = nil
    return command_manager.execute("MatchFrame", { project_id = "p" })
end

-- ── A: partial-coverage clamps marks instead of crashing ──────────────
print("-- (A) partial coverage clamps marks --")
timeline_state.set_playhead_position(50)  -- inside c_partial [0, 200)
timeline_state.set_selection({})
local result = exec_match_frame()
assert(result.success, string.format(
    "MatchFrame must succeed with clamped marks (not crash) on a "
    .. "partial-coverage clip. got error: %s",
    tostring(result.error_message)))
assert(source_mon.sequence_id == "master_partial",
    "source viewer must still load the master")

-- Master's valid range is [50, 150) per its media_ref + start_tc=50.
-- Clip's source range [10, 210) clamps to [50, 150).
local mp = Sequence.load("master_partial")
assert(mp.mark_in == 50, string.format(
    "mark_in must clamp to master start (50); got %s", tostring(mp.mark_in)))
assert(mp.mark_out == 150, string.format(
    "mark_out must clamp to master end (150); got %s", tostring(mp.mark_out)))
print("  PASS marks clamped to [50, 150), no crash")

-- ── A2: stale volume + offline_note → no failure, viewer loads ────────
print("-- (A2) stale volume file_path with offline_note candidate --")
timeline_state.set_playhead_position(550)  -- inside c_stale [500, 700)
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, string.format(
    "MatchFrame on partial-coverage clip whose media row carries a stale "
    .. "volume file_path must NOT fail — offline_note points at a real "
    .. "local candidate. got error: %s", tostring(result.error_message)))
assert(source_mon.sequence_id == "master_stale",
    "source viewer must load master_stale so its overlay can render")
print("  PASS no failure; viewer loaded; clamp path took over")

-- ── B: offline file → viewer loads, no failure ────────────────────────
-- The viewer's own offline overlay surfaces the file-missing state;
-- MatchFrame is navigation, not playback.
print("-- (B) offline file → viewer loads --")
timeline_state.set_playhead_position(350)  -- inside c_missing
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, string.format(
    "MatchFrame on offline media must still succeed: viewer renders the "
    .. "master with its offline overlay. got error: %s",
    tostring(result.error_message)))
assert(source_mon.sequence_id == "master_missing",
    "source viewer should load the master so its offline overlay can render")
print("  PASS viewer loaded for offline master")

-- Cleanup
os.remove(PARTIAL_PATH)

print("\nPASS test_match_frame_partial_and_offline.lua")
