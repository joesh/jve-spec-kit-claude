-- Integration: GoToPrevEdit / GoToNextEdit walk multi-track edit points.
--
-- Timeline layout (frames):
--   V1: clip_a [0, 1500)   + clip_b [3000, 4500)
--   V2: clip_c [1200, 2400) + clip_d [5000, 6200)
-- Combined edit points: 0, 1200, 1500, 2400, 3000, 4500, 5000, 6200.
--
-- Scenarios:
--   - From 2500 (gap between V1 clips, after V2 clip_c ends): Prev → 2400
--     (clip_c end on V2 — multi-track edit-point handling).
--   - From 3200 (inside V1 clip_b): Next → 4500 (clip_b end).
--   - At timeline end (6200): Next stays.
--
-- Replaces the stub-based test of the same name. Uses real
-- SequenceMonitor + transport + focus_manager registration so
-- GoToNextEdit/PrevEdit can resolve get_active_sequence_monitor.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_timeline_edit_navigation.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local panel_manager   = require("ui.panel_manager")
local SequenceMonitor = require("ui.sequence_monitor")
local focus_manager   = require("ui.focus_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")

local DB = "/tmp/jve/test_timeline_edit_navigation_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":30,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('seq', 'p', 'Edit', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 10000, 2500, '[]', '[]', '[]', 0, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('v1', 'seq', 'V1', 'VIDEO', 1, 1),
        ('v2', 'seq', 'V2', 'VIDEO', 2, 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
      VALUES ('mh', 'p', 'ph', '_ph', 6500, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('mst', 'p', 'master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('mst_v1', 'mst', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mst_v1' WHERE id = 'mst';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr', 'p', 'mst', 'mst_v1', 'mh', 0, 6500, 0, 6500, 48000, 1, 1.0, 0, 0, 0);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
      VALUES
        ('clip_a', 'p', 'A', 'v1', 'mst', 'seq',    0, 1500, 0, 1500, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_b', 'p', 'B', 'v1', 'mst', 'seq', 3000, 1500, 0, 1500, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_c', 'p', 'C', 'v2', 'mst', 'seq', 1200, 1200, 0, 1200, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0),
        ('clip_d', 'p', 'D', 'v2', 'mst', 'seq', 5000, 1200, 0, 1200, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]]))

-- Real monitors + transport + focus.
local source_mon   = SequenceMonitor.new({ view_id = "source_monitor"   })
local timeline_mon = SequenceMonitor.new({ view_id = "timeline_monitor" })
panel_manager.register_sequence_monitor("source_monitor",   source_mon)
panel_manager.register_sequence_monitor("timeline_monitor", timeline_mon)
focus_manager.register_panel("source_monitor",   source_mon:get_widget(),
    source_mon:get_title_widget(),   "Source")
focus_manager.register_panel("timeline_monitor", timeline_mon:get_widget(),
    timeline_mon:get_title_widget(), "Timeline")
focus_manager.set_focused_panel("timeline_monitor")
require("core.playback.transport").init("p")

command_manager.init("seq", "p")
timeline_mon:load_sequence("seq")

local function park(frame)
    timeline_state.set_playhead_position(frame)
    local seq = Sequence.load("seq")
    seq.playhead_position = frame
    seq:save()
end

local function playhead_in_db()
    return Sequence.load("seq").playhead_position
end

-- ── Prev from 2500 (post-V2-clip-c-end gap) → 2400 ────────────────────
-- This is the multi-track regression: edit points combine across V1
-- and V2. From 2500 the nearest LOWER edit point is 2400 (clip_c end
-- on V2), NOT 1500 (clip_a end on V1).
park(2500)
local result = command_manager.execute("GoToPrevEdit", { project_id = "p" })
assert(result.success, "Prev must succeed: " .. tostring(result.error_message))
assert(playhead_in_db() == 2400, string.format(
    "Prev from 2500 → 2400 (V2 clip_c end); got %s", playhead_in_db()))
print("  PASS Prev 2500 → 2400 (multi-track edit point on V2)")

-- ── Next from 3200 (inside V1 clip_b) → 4500 (clip_b end) ─────────────
park(3200)
result = command_manager.execute("GoToNextEdit", { project_id = "p" })
assert(result.success, "Next must succeed")
assert(playhead_in_db() == 4500, string.format(
    "Next from 3200 → 4500 (clip_b end); got %s", playhead_in_db()))
print("  PASS Next 3200 → 4500")

-- ── Next at timeline end (6200) → stay ────────────────────────────────
park(6200)
result = command_manager.execute("GoToNextEdit", { project_id = "p" })
assert(result.success, "Next must succeed at end")
assert(playhead_in_db() == 6200, string.format(
    "Next at 6200 (last edit point) must stay; got %s", playhead_in_db()))
print("  PASS Next 6200 → 6200 (no past-end)")

print("\nPASS test_timeline_edit_navigation.lua")
