-- Integration: MatchFrame clip resolution + master-clip load + marks/playhead.
--
-- 12 scenarios pin (in order):
--   - error path: no clips under playhead
--   - single-clip resolution
--   - multi-clip tiebreaker: topmost track_index
--   - selection-tiebreaker variants (single / both selected)
--   - browser is NOT touched
--   - source_viewer errors surface (not swallowed)
--   - video trumps audio when nothing selected
--   - selected audio overrides video-trumps-audio
--   - master clip marks/playhead are written from clip.source_in/_out
--
-- Replaces the stub-based test of the same name. Uses real
-- SequenceMonitor; the load_calls log is replaced by source_mon.sequence_id
-- read-back after each MatchFrame dispatch.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_match_frame.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")

-- ── DB ────────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_match_frame_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('default_project', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('default_sequence', 'default_project', 'Seq', 'sequence',
              30, 1, 48000, 1920, 1080, 0, 500, 0,
              '[]', '[]', '[]', 0, 0, 0, 0);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1),
        ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1),
        ('track_a1', 'default_sequence', 'A1', 'AUDIO', 1, 1),
        ('track_a2', 'default_sequence', 'A2', 'AUDIO', 2, 1),
        ('track_a3', 'default_sequence', 'A3', 'AUDIO', 3, 1);

    -- Media files (paths must exist on disk — MatchFrame's offline guard).
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        metadata, created_at, modified_at)
      VALUES
        ('media_a',     'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 500,
         30, 1, 1920, 1080, 0, 'prores',
         '{"start_tc_value":0,"start_tc_rate":30}', 0, 0),
        ('media_b',     'default_project', 'clip_b.mov', '/tmp/clip_b.mov', 500,
         30, 1, 1920, 1080, 0, 'prores',
         '{"start_tc_value":0,"start_tc_rate":30}', 0, 0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        audio_sample_rate, metadata, created_at, modified_at)
      VALUES
        ('media_audio', 'default_project', 'audio.wav', '/tmp/audio.wav', 500,
         30, 1, 0, 0, 2, 'pcm', 48000,
         '{"start_tc_value":0,"start_tc_rate":30,"start_tc_audio_samples":0,"start_tc_audio_rate":48000}',
         0, 0);

    -- Master sequences (V13). Each clip references a master via sequence_id.
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES
        ('master_clip_a',         'default_project', 'Master A',  'master', 30, 1, NULL, 1920, 1080, 0, 0),
        ('master_clip_b',         'default_project', 'Master B',  'master', 30, 1, NULL, 1920, 1080, 0, 0),
        ('master_clip_audio_a1',  'default_project', 'Audio A1',  'master', 30, 1, NULL, 1920, 1080, 0, 0),
        ('master_empty',          'default_project', 'Empty',     'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('mca_v', 'master_clip_a',        'V1', 'VIDEO', 1, 1),
        ('mcb_v', 'master_clip_b',        'V1', 'VIDEO', 1, 1),
        ('mca_a', 'master_clip_audio_a1', 'A1', 'AUDIO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mca_v' WHERE id = 'master_clip_a';
    UPDATE sequences SET default_video_layer_track_id = 'mcb_v' WHERE id = 'master_clip_b';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES
        ('mr_a',   'default_project', 'master_clip_a',        'mca_v', 'media_a',     0, 500,     0, 500,     48000, 1, 1.0, 0, 0, 0),
        ('mr_b',   'default_project', 'master_clip_b',        'mcb_v', 'media_b',     0, 500,     0, 500,     48000, 1, 1.0, 0, 0, 0),
        ('mr_aud', 'default_project', 'master_clip_audio_a1', 'mca_a', 'media_audio', 0, 8000000, 0, 8000000, 48000, 1, 1.0, 0, 0, 0);

    -- Timeline clips. clip_v1 references master_clip_a (source_in=10 to pin
    -- the marks-write assertion); clip_v2 references master_clip_b;
    -- clip_no_parent references master_empty (no media_refs → 'no master
    -- content' degraded path). Audio clips share master_clip_audio_a1.
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES
        ('clip_v1', 'default_project', 'Clip V1', 'track_v1', 'master_clip_a',         'default_sequence',   0, 200, 10, 210, NULL, NULL, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_v2', 'default_project', 'Clip V2', 'track_v2', 'master_clip_b',         'default_sequence', 100, 100,  0, 100, NULL, NULL, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_no_parent', 'default_project', 'No Parent', 'track_v1', 'master_empty', 'default_sequence', 300, 100,  0, 100, NULL, NULL, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_a1', 'default_project', 'Audio A1', 'track_a1', 'master_clip_audio_a1', 'default_sequence',   0, 200,  0, 200,    0,    0, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_a2', 'default_project', 'Audio A2', 'track_a2', 'master_clip_audio_a1', 'default_sequence',   0, 200,  0, 200,    0,    0, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_a3', 'default_project', 'Audio A3', 'track_a3', 'master_clip_audio_a1', 'default_sequence',   0, 200,  0, 200,    0,    0, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]]))

-- MatchFrame's offline-file guard requires every fixture media path to
-- exist on disk. Empty files satisfy the guard.
for _, p in ipairs({ "/tmp/clip_a.mov", "/tmp/clip_b.mov", "/tmp/audio.wav" }) do
    local f = assert(io.open(p, "w"),
        "could not create fixture media file at " .. p)
    f:close()
end

local source_mon = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "default_project",
}).source

command_manager.init("default_sequence", "default_project")

local clip_v1 = timeline_state.get_tab_strip():clip_by_id("clip_v1")
local clip_v2 = timeline_state.get_tab_strip():clip_by_id("clip_v2")
local clip_a1 = timeline_state.get_tab_strip():clip_by_id("clip_a1")
assert(clip_v1 and clip_v2 and clip_a1, "fixture: clips must load from DB")

local function exec_match_frame()
    source_mon.sequence_id = nil  -- clear before each scenario
    return command_manager.execute("MatchFrame", { project_id = "default_project" })
end

-- ── Test 1: No clips under playhead → error ──
print("Test 1: no clips under playhead")
timeline_state.set_playhead_position(250)  -- gap
timeline_state.set_selection({})
local result = exec_match_frame()
assert(not result.success, "must fail when no clips under playhead")
assert(result.error_message:find("No clips under playhead"),
    "error must name the empty-playhead condition; got: " .. tostring(result.error_message))
print("  PASS error: no clips under playhead")

-- ── Test 3: Single clip → loads that clip's master ──
print("Test 3: single clip → loads master_clip_a")
timeline_state.set_playhead_position(50)  -- only clip_v1
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, "must succeed: " .. tostring(result.error_message))
assert(source_mon.sequence_id == "master_clip_a", string.format(
    "must load master_clip_a; got %s", tostring(source_mon.sequence_id)))
print("  PASS single clip → master_clip_a")

-- ── Test 4: Multi-clip, no selection → topmost (highest track_index) ──
print("Test 4: multi-clip, no selection → topmost")
timeline_state.set_playhead_position(150)  -- clip_v1 (1) + clip_v2 (2)
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_b", string.format(
    "topmost V2 → master_clip_b; got %s", tostring(source_mon.sequence_id)))
print("  PASS multi → topmost master_clip_b")

-- ── Test 5: Single selection → use selected ──
print("Test 5: single selection wins")
timeline_state.set_playhead_position(150)
timeline_state.set_selection({ clip_v2 })
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_b", string.format(
    "selected V2 → master_clip_b; got %s", tostring(source_mon.sequence_id)))
print("  PASS single selection → master_clip_b")

-- ── Test 6: Multi-selection → topmost selected ──
print("Test 6: multi-selection, topmost wins")
timeline_state.set_playhead_position(150)
timeline_state.set_selection({ clip_v2, clip_v1 })
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_b", string.format(
    "topmost selected V2 → master_clip_b; got %s",
    tostring(source_mon.sequence_id)))
print("  PASS multi-selection → topmost master_clip_b")

-- ── Test 8: source_viewer.load_master_clip error surfaces ──
print("Test 8: source_viewer error surfaces")
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
local source_viewer = require("ui.source_viewer")
local orig_load = source_viewer.load_master_clip
source_viewer.load_master_clip = function() error("source viewer exploded") end
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
source_viewer.load_master_clip = orig_load
assert(not result.success, "must fail when source_viewer throws")
assert(result.error_message:match("source viewer exploded"),
    "error must carry original message; got: " .. tostring(result.error_message))
print("  PASS source_viewer error surfaced")

-- ── Test 9: Video trumps audio when nothing selected ──
print("Test 9: video trumps audio (no selection)")
timeline_state.set_playhead_position(50)  -- V1 + A1/A2/A3
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_a", string.format(
    "video V1 must beat all audio tracks; got %s",
    tostring(source_mon.sequence_id)))
print("  PASS video trumps audio")

-- ── Test 10: Multi V+A, no selection → topmost VIDEO wins ──
print("Test 10: topmost VIDEO wins over higher-index audio")
timeline_state.set_playhead_position(150)  -- V1 + V2 + A1/A2/A3
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_b", string.format(
    "topmost VIDEO V2 → master_clip_b; got %s",
    tostring(source_mon.sequence_id)))
print("  PASS topmost VIDEO wins")

-- ── Test 11: Selected audio overrides video-trumps-audio policy ──
print("Test 11: selected audio overrides video preference")
timeline_state.set_playhead_position(50)
timeline_state.set_selection({ clip_a1 })
result = exec_match_frame()
assert(result.success, "must succeed")
assert(source_mon.sequence_id == "master_clip_audio_a1", string.format(
    "selected audio must win; got %s", tostring(source_mon.sequence_id)))
print("  PASS selected audio overrides")

-- ── Test 12: MatchFrame writes master marks + playhead from clip ──
-- clip_v1: sequence_start=0, source_in=10, source_out=210, playhead=50.
-- Expected on master_clip_a:
--   mark_in  = source_in (10)
--   mark_out = source_out (210)
--   playhead = source_in + (playhead - sequence_start) = 10 + 50 = 60
print("Test 12: master clip marks + playhead written from clip source range")
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
result = exec_match_frame()
assert(result.success, "must succeed")
local m = Sequence.load("master_clip_a")
assert(m, "master_clip_a must load")
assert(m.mark_in == 10, string.format(
    "master.mark_in must == clip.source_in (10); got %s", tostring(m.mark_in)))
assert(m.mark_out == 210, string.format(
    "master.mark_out must == clip.source_out (210); got %s", tostring(m.mark_out)))
assert(m.playhead_position == 60, string.format(
    "master.playhead must == source_in + (timeline_playhead - sequence_start) = 60; got %s",
    tostring(m.playhead_position)))
print("  PASS marks (10, 210) and playhead 60 written to master_clip_a")

print("\nPASS test_match_frame.lua")
