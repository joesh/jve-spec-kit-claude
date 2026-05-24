#!/usr/bin/env luajit
--- GoToStart / GoToEnd: park the playhead at the sequence's start /
--- out-point. Model-layer behavior: writes the sequence row, emits
--- playhead_changed, timeline_state's own listener updates the
--- displayed playhead.
---
--- No mocks: GoToStart/GoToEnd go through core.playhead.set which
--- writes the sequences row directly. We verify by reloading the
--- sequence from the DB and reading playhead_position.

require("test_env")

local database       = require("core.database")
local command_manager = require("core.command_manager")
local Sequence       = require("models.sequence")

local DB = "/tmp/jve/test_go_to_start_end.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

-- One project, one record sequence with two clips (Clip A frames 0..100,
-- Clip B frames 200..350 — total content extent = 350 frames). Sequence
-- start_timecode_frame = 0; content_duration = 350.
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":30,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame,
        created_at, modified_at)
      VALUES ('seq', 'p', 'Record', 'sequence', 30, 1, 48000, 1920, 1080,
              0, 500, 150, '[]', '[]', '[]', 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        locked, muted, soloed, volume, pan)
      VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    -- Master placeholder so V13 clips have an owner (mirrors importer output).
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
      VALUES ('mh', 'p', 'ph', '_ph', 150, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('mst', 'p', 'master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        locked, muted, soloed, volume, pan)
      VALUES ('mst_v1', 'mst', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'mst_v1' WHERE id = 'mst';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr', 'p', 'mst', 'mst_v1', 'mh', 0, 150, 0, 150, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, track_id, sequence_id, owner_sequence_id, name,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
      VALUES
        ('a', 'p', 'v1', 'mst', 'seq', 'A',   0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('b', 'p', 'v1', 'mst', 'seq', 'B', 200, 150, 0, 150, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now)))

command_manager.init("seq", "p")

local function playhead_in_db()
    return Sequence.load("seq").playhead_position
end

print("=== test_go_to_start_end.lua ===")

-- ── GoToStart parks at start_timecode_frame (0) ────────────────────────
do
    local seq = Sequence.load("seq")
    seq.playhead_position = 150
    seq:save()

    local result = command_manager.execute("GoToStart", { project_id = "p" })
    assert(result.success, "GoToStart should succeed: " .. tostring(result.error_message))
    assert(playhead_in_db() == 0, string.format(
        "GoToStart parks playhead at sequence start (0); got %s",
        tostring(playhead_in_db())))
    print("  PASS GoToStart from 150 → 0")
end

-- ── GoToEnd parks at content out-point ────────────────────────────────
-- Sequence content extent = max(sequence_start_frame + duration_frames)
-- across all clips. Clip A ends at 100, Clip B ends at 350 → out-point 350.
do
    local seq = Sequence.load("seq")
    seq.playhead_position = 0
    seq:save()

    local result = command_manager.execute("GoToEnd", { project_id = "p" })
    assert(result.success, "GoToEnd should succeed: " .. tostring(result.error_message))
    assert(playhead_in_db() == 350, string.format(
        "GoToEnd parks playhead at content out-point (350 = clip_b end); got %s",
        tostring(playhead_in_db())))
    print("  PASS GoToEnd → out-point 350")
end

-- ── Idempotent at start ────────────────────────────────────────────────
do
    local seq = Sequence.load("seq")
    seq.playhead_position = 0
    seq:save()

    local result = command_manager.execute("GoToStart", { project_id = "p" })
    assert(result.success, "GoToStart should succeed when already at start")
    assert(playhead_in_db() == 0, "GoToStart idempotent at 0")
    print("  PASS GoToStart idempotent at start")
end

-- ── Idempotent at end ─────────────────────────────────────────────────
do
    local seq = Sequence.load("seq")
    seq.playhead_position = 350
    seq:save()

    local result = command_manager.execute("GoToEnd", { project_id = "p" })
    assert(result.success, "GoToEnd should succeed when already at end")
    assert(playhead_in_db() == 350, "GoToEnd idempotent at out-point")
    print("  PASS GoToEnd idempotent at end")
end

-- ── Result is integer ──────────────────────────────────────────────────
do
    local seq = Sequence.load("seq")
    seq.playhead_position = 50
    seq:save()

    local result = command_manager.execute("GoToStart", { project_id = "p" })
    assert(result.success)
    local got = playhead_in_db()
    assert(type(got) == "number" and got == math.floor(got),
        "playhead must be integer frame; got " .. tostring(got))
    print("  PASS playhead stays integer")
end

print("\nPASS test_go_to_start_end.lua")
