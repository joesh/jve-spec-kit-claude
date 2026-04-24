-- T013 (013): INV-8 — sequences.default_video_layer_track_id must be non-NULL
-- whenever the sequence has at least one video track. Model layer must refuse
-- any UPDATE that would violate this.
-- Expected to FAIL until T017 (sequence.lua narrow) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_sequence_inv8.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

local Sequence = require("models.sequence")

-- Good control: create a master with no video tracks; default_video_layer_track_id = NULL is fine.
local audio_only_id = Sequence.create({
    project_id = "p1",
    name = "audio-only",
    kind = "master",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
-- Add an audio track. Still no video — default stays NULL.
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-a1', '%s', 'A1', 'AUDIO', 1)", audio_only_id)))
Sequence.assert_inv8(audio_only_id)  -- should pass (no video tracks)

-- Now make a master with a V track.
local vid_id = Sequence.create({
    project_id = "p1",
    name = "vid",
    kind = "master",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-v1', '%s', 'V1', 'VIDEO', 1)", vid_id)))

-- The creating path should have set default_video_layer_track_id to the new V track
-- OR assert_inv8 should refuse until it's set. Test the explicit set path.
assert(Sequence.update(vid_id, { default_video_layer_track_id = "trk-v1" }),
    "setting default_video_layer_track_id to a live V track should succeed")
Sequence.assert_inv8(vid_id)  -- passes

-- Bad: NULL-ing the default when the sequence has a video track must refuse.
local ok, err = pcall(function()
    Sequence.update(vid_id, { default_video_layer_track_id = nil })
end)
assert(not ok, "setting default_video_layer_track_id = NULL with a live V track must refuse (INV-8)")
assert(tostring(err):find("INV%-8"),
    "error must name INV-8; got: " .. tostring(err))
assert(tostring(err):find(vid_id),
    "error must name the sequence id; got: " .. tostring(err))

-- Bad: setting default to a track that's not a video track of this sequence must refuse.
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-a2', '%s', 'A1', 'AUDIO', 1)", vid_id)))
local ok2, err2 = pcall(function()
    Sequence.update(vid_id, { default_video_layer_track_id = "trk-a2" })
end)
assert(not ok2, "setting default to an audio track must refuse")
assert(tostring(err2):find("trk%-a2"), "error must name the bad track; got: " .. tostring(err2))

print("✅ test_sequence_inv8_default_layer.lua passed")
