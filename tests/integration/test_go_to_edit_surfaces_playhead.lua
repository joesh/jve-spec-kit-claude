-- Integration: GoToNextEdit / GoToPrevEdit emit playhead_changed,
-- persist to the DB, AND scroll the viewport so the new playhead is
-- visible. Regression for an earlier bug where these commands wrote
-- only data.state.playhead_position, bypassing both signal emission
-- and DB persistence (unlike GoToStart/GoToEnd).
--
-- Layout (frames):
--   clip_a [0, 100), gap [100, 5000), clip_b [5000, 5150)
-- Edit points: 0, 100, 5000, 5150. Viewport starts at [0, 500) so
-- clip_b is far off-screen — Next/Prev to clip_b must scroll the
-- viewport to keep it visible.
--
-- Replaces the stub-based test of the same name. Real bindings.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_go_to_edit_surfaces_playhead.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")
local Signals         = require("core.signals")

local DB = "/tmp/jve/test_go_to_edit_surfaces_playhead_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    -- view_start_frame=0, view_duration_frames=500 — clip_b at 5000 is
    -- far off-screen, exercising the surface-playhead viewport scroll.
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('seq1', 'p', 'Edit', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 500, 50, '[]', '[]', '[]', 0, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
      VALUES ('mh', 'p', 'ph', '_ph', 5500, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('mst', 'p', 'master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('mst_v1', 'mst', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mst_v1' WHERE id = 'mst';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr', 'p', 'mst', 'mst_v1', 'mh', 0, 5500, 0, 5500, 48000, 1, 1.0, 0, 0, 0);

    INSERT INTO clips (id, project_id, track_id, sequence_id, owner_sequence_id,
        name, sequence_start_frame, duration_frames, source_in_frame,
        source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES
        ('clip_a', 'p', 'v1', 'mst', 'seq1', 'A',    0,  100, 0,  100, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_b', 'p', 'v1', 'mst', 'seq1', 'B', 5000,  150, 0,  150, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]]))

local timeline_mon = ienv.setup_monitor_panels({
    kinds = "both", focus = "timeline_monitor", transport_project_id = "p",
}).timeline

command_manager.init("seq1", "p")
timeline_mon:load_sequence("seq1")

-- Capture playhead_changed signals.
local signal_log = {}
Signals.connect("playhead_changed", function(seq_id, frame)
    signal_log[#signal_log + 1] = { sequence_id = seq_id, frame = frame }
end)

local function park(frame)
    timeline_state.set_playhead_position(frame)
    local seq = Sequence.load("seq1")
    seq.playhead_position = frame
    seq:save()
end

-- ── (1) Next emits playhead_changed + reaches edit point ─────────────
print("-- (1) Next emits playhead_changed --")
park(50)
signal_log = {}
local result = command_manager.execute("GoToNextEdit", { project_id = "p" })
assert(result.success, "Next must succeed")
assert(timeline_state.get_playhead_position() == 100,
    string.format("Next from 50 → 100; got %s",
        tostring(timeline_state.get_playhead_position())))
assert(#signal_log > 0, "Next must emit playhead_changed")
local ev = signal_log[1]
assert(ev.sequence_id == "seq1" and ev.frame == 100, string.format(
    "first signal must carry (seq1, 100); got (%s, %s)",
    tostring(ev.sequence_id), tostring(ev.frame)))
print("  PASS signal emitted with (seq1, 100)")

-- ── (2) Next persists to DB ──────────────────────────────────────────
print("-- (2) Next persists to DB --")
assert(Sequence.load("seq1").playhead_position == 100, string.format(
    "DB playhead_position must be 100 after Next; got %s",
    tostring(Sequence.load("seq1").playhead_position)))
print("  PASS DB playhead = 100")

-- ── (3) Prev emits playhead_changed ──────────────────────────────────
print("-- (3) Prev emits playhead_changed --")
park(5100)
signal_log = {}
result = command_manager.execute("GoToPrevEdit", { project_id = "p" })
assert(result.success, "Prev must succeed")
assert(timeline_state.get_playhead_position() == 5000,
    string.format("Prev from 5100 → 5000; got %s",
        tostring(timeline_state.get_playhead_position())))
assert(#signal_log > 0, "Prev must emit playhead_changed")
assert(signal_log[1].frame == 5000, string.format(
    "first signal must carry frame 5000; got %s",
    tostring(signal_log[1].frame)))
print("  PASS signal emitted with frame 5000")

-- ── (4) Prev persists to DB ──────────────────────────────────────────
print("-- (4) Prev persists to DB --")
assert(Sequence.load("seq1").playhead_position == 5000, string.format(
    "DB playhead_position must be 5000 after Prev; got %s",
    tostring(Sequence.load("seq1").playhead_position)))
print("  PASS DB playhead = 5000")

-- ── (5) Next surfaces viewport when target off-screen ────────────────
-- Park at 100 with viewport [0, 500); Next jumps to 5000 (clip_b start).
-- After surface_playhead, the viewport must contain 5000.
print("-- (5) Next surfaces viewport for off-screen target --")
park(100)
timeline_state.set_viewport_start_time(0)  -- viewport [0, 500)
result = command_manager.execute("GoToNextEdit", { project_id = "p" })
assert(result.success, "Next must succeed")
assert(timeline_state.get_playhead_position() == 5000,
    string.format("Next from 100 → 5000; got %s",
        tostring(timeline_state.get_playhead_position())))
local vp_start = timeline_state.get_viewport_start_time()
local vp_end   = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= 5000 and 5000 <= vp_end, string.format(
    "viewport [%d, %d) must contain playhead 5000 — surface_playhead "
    .. "should have scrolled to bring it on-screen", vp_start, vp_end))
print(string.format("  PASS viewport scrolled to [%d, %d) containing 5000",
    vp_start, vp_end))

-- ── (6) Prev surfaces viewport for off-screen target ─────────────────
-- Viewport is near 5000 from scenario 5; Prev jumps to 100 (off-screen).
print("-- (6) Prev surfaces viewport for off-screen target --")
result = command_manager.execute("GoToPrevEdit", { project_id = "p" })
assert(result.success, "Prev must succeed")
assert(timeline_state.get_playhead_position() == 100,
    string.format("Prev from 5000 → 100; got %s",
        tostring(timeline_state.get_playhead_position())))
vp_start = timeline_state.get_viewport_start_time()
vp_end   = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= 100 and 100 <= vp_end, string.format(
    "viewport [%d, %d) must contain playhead 100", vp_start, vp_end))
print(string.format("  PASS viewport scrolled to [%d, %d) containing 100",
    vp_start, vp_end))

print("\nPASS test_go_to_edit_surfaces_playhead.lua")
