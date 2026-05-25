-- Integration: GoToNextEdit / GoToPrevEdit navigation across edit points.
--
-- 11 scenarios pin (timeline layout: clip_a [0,100), gap [100,200),
-- clip_b [200,350); edit points: 0, 100, 200, 350):
--   - GoToNextEdit walks 50→100→200→350 (and stays at 350 at the end).
--   - GoToPrevEdit walks 300→200→100→0 (and stays at 0 at the start).
--   - Navigation from inside a gap still finds the surrounding edit points.
--   - Round-trip Next+Prev from 50 lands on 0 (prev jumps to previous
--     edit, not back to the starting frame).
--
-- Replaces the stub-based test of the same name. Uses real
-- SequenceMonitor + transport so GoToNextEdit/GoToPrevEdit can resolve
-- pm.get_active_sequence_monitor() and call sv.engine:is_playing()/stop().

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_go_to_next_prev_edit.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")

-- ── DB ────────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_go_to_next_prev_edit_integ.db"
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
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('seq', 'p', 'Edit', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 500, 50, '[]', '[]', '[]', 0, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);

    -- Placeholder master + media so V13 clips have a valid source sequence.
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
      VALUES ('mh', 'p', 'ph', '_ph', 500, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('mst', 'p', 'master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('mst_v1', 'mst', 'V1', 'VIDEO', 1, 1);
    UPDATE sequences SET default_video_layer_track_id = 'mst_v1' WHERE id = 'mst';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr', 'p', 'mst', 'mst_v1', 'mh', 0, 500, 0, 500, 48000, 1, 1.0, 0, 0, 0);

    -- Timeline: clip_a [0, 100), gap [100, 200), clip_b [200, 350).
    INSERT INTO clips (id, project_id, track_id, sequence_id, owner_sequence_id,
        name, sequence_start_frame, duration_frames, source_in_frame,
        source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
      VALUES
        ('a', 'p', 'v1', 'mst', 'seq', 'A',   0, 100, 0, 100, 1, 0, 0,
         NULL, NULL, 'resample', 1.0, 0),
        ('b', 'p', 'v1', 'mst', 'seq', 'B', 200, 150, 0, 150, 1, 0, 0,
         NULL, NULL, 'resample', 1.0, 0);
]]))

-- Real monitors + focus wiring + transport. focus_manager.register_panel
-- is needed so panel_manager.get_active_sequence_monitor (which reads
-- the focused panel) returns timeline_monitor — without it, the command
-- resolves to a fallback path and may not find an engine.
local mons = ienv.setup_monitor_panels({
    kinds = "both", focus = "timeline_monitor", transport_project_id = "p",
})
local source_mon, timeline_mon = mons.source, mons.timeline

command_manager.init("seq", "p")

-- GoToNextEdit/PrevEdit assert that the active sequence monitor has a
-- loaded sequence (sv.sequence_id). Load the edit sequence into the
-- timeline monitor so the command's resolver finds it.
timeline_mon:load_sequence("seq")

-- Park BOTH the in-memory cache and the DB row. GoToNextEdit/PrevEdit
-- read the current playhead via timeline_state.get_playhead_position()
-- (the in-memory cache), so a DB-only park would let stale state leak
-- between scenarios — earlier tests would still pass by accident
-- because each Next/Prev emits playhead_changed and the listener
-- updates the cache, but a fresh park (e.g. into a gap) would read
-- the previous scenario's leftover cache value.
local function park(frame)
    timeline_state.set_playhead_position(frame)
    local seq = Sequence.load("seq")
    seq.playhead_position = frame
    seq:save()
end

local function playhead_in_db()
    return Sequence.load("seq").playhead_position
end

local function next_edit()
    return command_manager.execute("GoToNextEdit", { project_id = "p" })
end

local function prev_edit()
    return command_manager.execute("GoToPrevEdit", { project_id = "p" })
end

-- ── 1: middle of clip_a → end of clip_a ────────────────────────────────
park(50)
assert(next_edit().success)
assert(playhead_in_db() == 100, string.format(
    "Next from 50 → 100; got %s", playhead_in_db()))
print("  PASS Next 50 → 100")

-- ── 2: end of clip_a → start of clip_b ─────────────────────────────────
park(100)
assert(next_edit().success)
assert(playhead_in_db() == 200, string.format(
    "Next from 100 → 200; got %s", playhead_in_db()))
print("  PASS Next 100 → 200")

-- ── 3: start of clip_b → end of clip_b ─────────────────────────────────
park(200)
assert(next_edit().success)
assert(playhead_in_db() == 350, string.format(
    "Next from 200 → 350; got %s", playhead_in_db()))
print("  PASS Next 200 → 350")

-- ── 4: at end of timeline → stay ───────────────────────────────────────
park(350)
assert(next_edit().success)
assert(playhead_in_db() == 350, string.format(
    "Next from 350 stays; got %s", playhead_in_db()))
print("  PASS Next 350 → 350 (no past-end)")

-- ── 5: middle of clip_b → start of clip_b ──────────────────────────────
park(300)
assert(prev_edit().success)
assert(playhead_in_db() == 200, string.format(
    "Prev from 300 → 200; got %s", playhead_in_db()))
print("  PASS Prev 300 → 200")

-- ── 6: start of clip_b → end of clip_a ─────────────────────────────────
park(200)
assert(prev_edit().success)
assert(playhead_in_db() == 100, string.format(
    "Prev from 200 → 100; got %s", playhead_in_db()))
print("  PASS Prev 200 → 100")

-- ── 7: end of clip_a → start of timeline ───────────────────────────────
park(100)
assert(prev_edit().success)
assert(playhead_in_db() == 0, string.format(
    "Prev from 100 → 0; got %s", playhead_in_db()))
print("  PASS Prev 100 → 0")

-- ── 8: at start of timeline → stay ─────────────────────────────────────
park(0)
assert(prev_edit().success)
assert(playhead_in_db() == 0, string.format(
    "Prev from 0 stays; got %s", playhead_in_db()))
print("  PASS Prev 0 → 0 (no before-start)")

-- ── 9: inside gap → next finds clip_b start ────────────────────────────
park(150)
assert(next_edit().success)
assert(playhead_in_db() == 200, string.format(
    "Next from gap 150 → 200; got %s", playhead_in_db()))
print("  PASS Next 150 (gap) → 200")

-- ── 10: inside gap → prev finds clip_a end ─────────────────────────────
park(150)
assert(prev_edit().success)
assert(playhead_in_db() == 100, string.format(
    "Prev from gap 150 → 100; got %s", playhead_in_db()))
print("  PASS Prev 150 (gap) → 100")

-- ── 11: round-trip: 50 → Next (100) → Prev (0, not 50) ────────────────
-- Prev jumps to previous edit, not back to where Next started from.
park(50)
assert(next_edit().success)
assert(prev_edit().success)
assert(playhead_in_db() == 0, string.format(
    "round-trip 50 → 100 → 0; got %s", playhead_in_db()))
print("  PASS round-trip lands on 0 (not 50)")

print("\nPASS test_go_to_next_prev_edit.lua")
