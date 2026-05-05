-- T012 (013): clip-window invariant. Source coordinates must satisfy
--   * source_in >= 0  (negative bounds forbidden)
--   * source_in != source_out  (empty window forbidden)
--
-- The pre-013 spec also gated source_out <= nested.duration. That clause was
-- dropped: when nested is a master sequence, its duration mirrors a mutable
-- media file (relink to a shorter file would invalidate existing clips
-- retroactively, and the importer must not look at media files at all).
-- Past-extent windows are handled by the runtime path (relinker /
-- partial_coverage / decoder silence), not by clip-write rejection.
-- Per-command preconditions (trim, slip, roll) still clamp/refuse against
-- the current master duration — that's the right scope for the upper bound.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_clip_inv4.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-edit', 'p1', 'e', 'nested', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-master-v1', 'seq-master', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-edit-v1', 'seq-edit', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med1', 'p1', 'x.mov', '/tmp/x.mov', 100, 24, 1, 0, 0)"))
-- Master has a single 100-frame media_ref — master's effective duration = 100.
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr1', 'p1', 'seq-master', 'trk-master-v1', 'med1', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))

local Clip = require("models.clip")

-- Create a clip whose window is in-bounds.
local clip_id = Clip.create({
    project_id = "p1",
    owner_sequence_id = "seq-edit",
    track_id = "trk-edit-v1",
    nested_sequence_id = "seq-master",
    name = "c",
    timeline_start_frame = 0,
    duration_frames = 100,
    source_in_frame = 0,
    source_out_frame = 100,
    fps_mismatch_policy = "passthrough",
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})

-- Good: narrow the window to (10, 90) — still in-bounds.
assert(Clip.update(clip_id, { source_in_frame = 10, source_out_frame = 90 }),
    "in-bounds update should succeed")

-- Bad: source_in_frame = -1 (below zero).
local ok1, err1 = pcall(function()
    Clip.update(clip_id, { source_in_frame = -1 })
end)
assert(not ok1, "source_in_frame < 0 must refuse (source window: non-empty, lower bound >= 0)")
assert(tostring(err1):find(clip_id, 1, true), "error must name clip id; got: " .. tostring(err1))
assert(tostring(err1):find("source_in"), "error must name source_in; got: " .. tostring(err1))

-- Past-extent: source_out_frame > nested master duration (100) is now
-- ALLOWED at the model layer. Runtime handles the past-extent case via
-- relinker partial_coverage notes, source-viewer offline overlays, and
-- decoder silence/black past file end.
assert(Clip.update(clip_id, { source_out_frame = 101 }),
    "source_out > master duration must succeed (relinker handles past-extent)")
local loaded = Clip.load(clip_id)
assert(loaded.source_out == 101, string.format(
    "past-extent value must persist: expected source_out=101, got %s",
    tostring(loaded.source_out)))
-- Restore the in-bounds value for the empty-window check below.
assert(Clip.update(clip_id, { source_out_frame = 90 }))

-- Bad: source_in_frame >= source_out_frame (zero-or-negative window).
local ok3 = pcall(function()
    Clip.update(clip_id, { source_in_frame = 50, source_out_frame = 50 })
end)
assert(not ok3, "source_in == source_out must refuse (source window must be non-empty)")

-- assert_within_master_coverage: input validation.
-- nested_sequence_id is required.
local ok_no_seq = pcall(Clip.assert_within_master_coverage, nil, 50, "test")
assert(not ok_no_seq, "nil nested_sequence_id must refuse")

local ok_empty_seq = pcall(Clip.assert_within_master_coverage, "", 50, "test")
assert(not ok_empty_seq, "empty nested_sequence_id must refuse")

-- new_source_out must be a number; nil must produce an actionable error.
local ok_nil_out, err_nil_out = pcall(Clip.assert_within_master_coverage, "seq-master", nil, "test-label")
assert(not ok_nil_out, "nil new_source_out must refuse")
assert(tostring(err_nil_out):find("new_source_out", 1, true),
    "error must name new_source_out; got: " .. tostring(err_nil_out))
assert(tostring(err_nil_out):find("test-label", 1, true),
    "error must include label; got: " .. tostring(err_nil_out))

-- assert_within_master_coverage: output check — exceeding coverage errors.
local ok_over, err_over = pcall(Clip.assert_within_master_coverage, "seq-master", 101, "roll-test")
assert(not ok_over, "source_out > master coverage must refuse")
assert(tostring(err_over):find("101", 1, true),
    "error must name bad value; got: " .. tostring(err_over))

-- Within coverage: no error.
assert(pcall(Clip.assert_within_master_coverage, "seq-master", 100, "roll-test"),
    "source_out == master coverage must succeed")

-- No-op when master has no media_refs (coverage_max is nil).
-- Roll commands call this before a clip with a brand-new master sequence;
-- refusing would block valid edits before any media_ref is attached.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-empty-master', 'p1', 'em', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(pcall(Clip.assert_within_master_coverage, "seq-empty-master", 99999, "empty-master"),
    "master with no media_refs must be a no-op (coverage_max=nil)")

print("✅ test_clip_inv4_window.lua passed")
