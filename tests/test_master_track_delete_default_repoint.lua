-- T013b / T013d (013): INV-6 + pre-T017 track-delete behavior on masters.
-- Deleting a video track on a master sequence must either:
--   (1) repoint default_video_layer_track_id to another live video track before commit
--       (if one exists), OR
--   (2) refuse with a clear error if no other video track is available and the master
--       has clips that reference it.
-- Never silently leaves the default dangling (INV-8).
-- Expected to FAIL until T017 (sequence.lua) + the matching DeleteTrack command land.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_master_track_delete.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

local Sequence = require("models.sequence")
local Track = require("models.track")

-- Scenario A: master with V1 + V2, both live. Deleting V1 (the default) repoints
-- default to V2 atomically.
local mA = Sequence.create({
    project_id = "p1",
    name = "mA",
    kind = "master",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('mA-v1', '%s', 'V1', 'VIDEO', 1)", mA)))
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('mA-v2', '%s', 'V2', 'VIDEO', 2)", mA)))
Sequence.update(mA, { default_video_layer_track_id = "mA-v1" })

Track.delete("mA-v1")  -- must repoint atomically

local row = Sequence.find(mA)
assert(row.default_video_layer_track_id == "mA-v2",
    string.format("expected default repointed to mA-v2, got %s",
        tostring(row.default_video_layer_track_id)))
Sequence.assert_inv8(mA)

-- Scenario B: master with only V1, NO clips referencing it. Deleting V1 succeeds
-- and leaves default NULL (audio_only state is valid when no V tracks).
local mB = Sequence.create({
    project_id = "p1",
    name = "mB",
    kind = "master",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('mB-v1', '%s', 'V1', 'VIDEO', 1)", mB)))
Sequence.update(mB, { default_video_layer_track_id = "mB-v1" })

Track.delete("mB-v1")
local rowB = Sequence.find(mB)
assert(rowB.default_video_layer_track_id == nil,
    "with no V tracks remaining, default should be NULL")
Sequence.assert_inv8(mB)

-- Scenario C: master with only V1 AND a clip in another sequence referencing it.
-- Deleting V1 must refuse (would orphan the clip's visual content).
local mC = Sequence.create({
    project_id = "p1",
    name = "mC",
    kind = "master",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('mC-v1', '%s', 'V1', 'VIDEO', 1)", mC)))
Sequence.update(mC, { default_video_layer_track_id = "mC-v1" })

local edit = Sequence.create({
    project_id = "p1",
    name = "edit",
    kind = "nested",
    fps_numerator = 24,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
})
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('edit-v1', '%s', 'V1', 'VIDEO', 1)", edit)))
local Clip = require("models.clip")
Clip.create({
    project_id = "p1",
    owner_sequence_id = edit,
    track_id = "edit-v1",
    nested_sequence_id = mC,
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

local ok, err = pcall(function() Track.delete("mC-v1") end)
assert(not ok, "deleting last V track of a master with live clip refs must refuse")
assert(tostring(err):find("mC%-v1"),
    "error must name the track; got: " .. tostring(err))
-- Master's V1 is still there — no half-applied mutation.
local rowC = Sequence.find(mC)
assert(rowC.default_video_layer_track_id == "mC-v1",
    "after refusal, default must still point at mC-v1")

print("✅ test_master_track_delete_default_repoint.lua passed")
