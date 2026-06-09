-- Regression: the clip source-window invariant must consider subframes
-- on AUDIO clips. A sub-1-frame audio source range (e.g. a 1-sample
-- patch from a DRP master timeline) lands on a single video-frame
-- index but spans distinct master-clock-tick subframes, so the window
-- is non-empty at the data model's actual granularity (FR-022).
--
-- Domain behaviour exercised:
--   1. Audio clip with source_in_frame == source_out_frame but
--      distinct subframes — accepted (sub-1-frame audio is legal).
--   2. Audio clip with identical frame AND identical subframe —
--      rejected (truly empty window).
--   3. Video clip with source_in_frame == source_out_frame and NULL
--      subframes — rejected (preserves the existing video behaviour
--      since video carries no subframe per FR-013).
--
-- Repro of the original bug: importing `anamnesis joe edit.drp` hits
-- clip "58-209-001" — an audio clip with a 1-sample source range
-- (source_in=3217555200, source_out=3217555201 samples at 48 kHz).
-- At master fps 25, both samples land on frame 1675810 with subframes
-- 0 and 14700 respectively (1 sample = 14700 master-clock ticks).
-- Pre-fix the importer crashed on assert_window_in_bounds.

require("test_env")

local database = require("core.database")
local Clip = require("models.clip")

local db_path = "/tmp/jve/test_clip_window_audio_subframe.db"
os.remove(db_path); os.remove(db_path .. "-wal"); os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample',
        '{"master_clock_hz":254016000000,"default_fps":{"num":25,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame,
        view_duration_frames, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('seq', 'proj', 'Timeline', 'sequence', 25, 1, 48000, 1920, 1080,
        0, 0, 8000, '[]', '[]', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_a', 'proj', 'audio_master', 'master', 25, 1, NULL, NULL, NULL, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_v', 'proj', 'video_master', 'master', 25, 1, NULL, NULL, NULL, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now, now, now, now, now)))

-- Case 1: sub-1-frame audio window — same frame, distinct subframe.
-- Models the real DRP "58-209-001" case (1 sample at 48k/25).
local ok, err = pcall(Clip.create, {
    project_id          = "proj",
    owner_sequence_id   = "seq",
    track_id            = "a1",
    sequence_id         = "master_a",
    name                = "1-sample-audio",
    sequence_start_frame = 0,
    duration_frames     = 1,
    source_in_frame     = 1675810,
    source_out_frame    = 1675810,
    source_in_subframe  = 0,
    source_out_subframe = 14700,
    fps_mismatch_policy = "resample",
    enabled             = true,
    volume              = 1.0,
    playhead_frame      = 0,
    created_at          = now,
    modified_at         = now,
})
assert(ok, "sub-1-frame audio window should be accepted (got error: "
    .. tostring(err) .. ")")
print("  ✓ Sub-1-frame audio (same frame, distinct subframes) accepted")

-- Case 2: truly empty audio window — same frame AND same subframe.
ok, err = pcall(Clip.create, {
    project_id          = "proj",
    owner_sequence_id   = "seq",
    track_id            = "a1",
    sequence_id         = "master_a",
    name                = "empty-audio",
    sequence_start_frame = 10,
    duration_frames     = 1,
    source_in_frame     = 2000,
    source_out_frame    = 2000,
    source_in_subframe  = 0,
    source_out_subframe = 0,
    fps_mismatch_policy = "resample",
    enabled             = true,
    volume              = 1.0,
    playhead_frame      = 0,
    created_at          = now,
    modified_at         = now,
})
assert(not ok, "truly empty audio window should be rejected")
assert(tostring(err):find("empty window"),
    "error must flag empty window (got: " .. tostring(err) .. ")")
print("  ✓ Truly empty audio window (same frame, same subframe) rejected")

-- Case 3: video clip with same frame — preserves existing behaviour.
-- Video carries NULL subframe per FR-013; comparison reduces to frame.
ok, err = pcall(Clip.create, {
    project_id          = "proj",
    owner_sequence_id   = "seq",
    track_id            = "v1",
    sequence_id         = "master_v",
    name                = "empty-video",
    sequence_start_frame = 20,
    duration_frames     = 1,
    source_in_frame     = 500,
    source_out_frame    = 500,
    source_in_subframe  = nil,
    source_out_subframe = nil,
    fps_mismatch_policy = "resample",
    enabled             = true,
    volume              = 1.0,
    playhead_frame      = 0,
    created_at          = now,
    modified_at         = now,
})
assert(not ok, "empty video window should still be rejected")
assert(tostring(err):find("empty window"),
    "error must flag empty window (got: " .. tostring(err) .. ")")
print("  ✓ Empty video window (FR-013 NULL subframe) still rejected")

-- Case 4: mixed nil/int subframe — partial mutation slipped through.
-- nil-vs-int would silently read as "non-equal" under raw Lua equality
-- (Half 1 NSF gap). The window check must surface the type mismatch loud.
ok, err = pcall(Clip.create, {
    project_id          = "proj",
    owner_sequence_id   = "seq",
    track_id            = "a1",
    sequence_id         = "master_a",
    name                = "mixed-nil-audio",
    sequence_start_frame = 30,
    duration_frames     = 1,
    source_in_frame     = 3000,
    source_out_frame    = 3000,
    source_in_subframe  = nil,    -- malformed: one nil, one int
    source_out_subframe = 14700,
    fps_mismatch_policy = "resample",
    enabled             = true,
    volume              = 1.0,
    playhead_frame      = 0,
    created_at          = now,
    modified_at         = now,
})
assert(not ok, "mixed nil/int subframe must surface a clear error")
assert(tostring(err):find("mismatched") or tostring(err):find("subframe"),
    "error must flag the subframe-kind mismatch (got: " .. tostring(err) .. ")")
print("  ✓ Mixed nil/int subframe (partial mutation) rejected")

print("✅ test_clip_window_audio_subframe.lua passed")
