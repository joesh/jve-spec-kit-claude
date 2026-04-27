-- T012 (013): INV-4 — a clip's [source_in_frame, source_out_frame] must fit
-- inside its nested sequence's timebase: 0 ≤ source_in AND source_out ≤ nested.duration.
-- Enforced at the command layer (Trim, Slip, Roll) — a direct-update path that
-- would violate the invariant must refuse with a message naming the clip and the
-- offending bound.
-- Expected to FAIL until T015 (clip.lua narrow) lands with assert_window_in_nested_bounds.

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
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
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
assert(not ok1, "source_in_frame < 0 must refuse (INV-4)")
assert(tostring(err1):find(clip_id, 1, true), "error must name clip id; got: " .. tostring(err1))
assert(tostring(err1):find("source_in"), "error must name source_in; got: " .. tostring(err1))

-- Bad: source_out_frame > nested master duration (100).
local ok2, err2 = pcall(function()
    Clip.update(clip_id, { source_out_frame = 101 })
end)
assert(not ok2, "source_out_frame > nested.duration must refuse (INV-4)")
assert(tostring(err2):find(clip_id, 1, true), "error must name clip id")
assert(tostring(err2):find("source_out"), "error must name source_out")
assert(tostring(err2):find("100"), "error must name nested duration (100)")

-- Bad: source_in_frame >= source_out_frame (zero-or-negative window).
local ok3 = pcall(function()
    Clip.update(clip_id, { source_in_frame = 50, source_out_frame = 50 })
end)
assert(not ok3, "source_in == source_out must refuse (empty window)")

print("✅ test_clip_inv4_window.lua passed")
