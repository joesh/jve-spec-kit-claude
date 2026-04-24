-- T013b / T013d (013): INV-6 + pre-T017 track-delete behavior on masters.
-- Deleting a video track on a master sequence must either:
--   (1) repoint default_video_layer_track_id to another live video track
--       before commit (if one exists), OR
--   (2) refuse with a clear error if no other V track is available AND the
--       master has clips referencing it.
-- Never silently leaves the default dangling.

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_master_track_delete.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

local function make_sequence(name, kind)
    local s = Sequence.create(name, "p1", { fps_numerator = 24, fps_denominator = 1 },
        1920, 1080, { kind = kind, audio_rate = 48000 })
    assert(s:save(), "Sequence:save failed")
    return s.id
end

local function add_track(id_prefix, seq_id, kind, idx)
    local tid = id_prefix .. "-" .. kind:sub(1,1):lower() .. idx
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('%s', '%s', '%s%d', '%s', %d)",
        tid, seq_id, kind:sub(1,1), idx, kind, idx)))
    return tid
end

-- Scenario A: master with V1 + V2, both live. Deleting V1 (the default)
-- repoints default to V2 atomically.
local mA = make_sequence("mA", "master")
local mA_v1 = add_track("mA", mA, "VIDEO", 1)
local mA_v2 = add_track("mA", mA, "VIDEO", 2)
Sequence.update(mA, { default_video_layer_track_id = mA_v1 })

Track.delete(mA_v1)

local rowA = Sequence.find(mA)
assert(rowA.default_video_layer_track_id == mA_v2, string.format(
    "expected default repointed to %s, got %s",
    mA_v2, tostring(rowA.default_video_layer_track_id)))
Sequence.assert_inv8(mA)

-- Scenario B: master with only V1, NO clips referencing it. Deleting V1
-- succeeds and leaves default NULL.
local mB = make_sequence("mB", "master")
local mB_v1 = add_track("mB", mB, "VIDEO", 1)
Sequence.update(mB, { default_video_layer_track_id = mB_v1 })

Track.delete(mB_v1)
local rowB = Sequence.find(mB)
assert(rowB.default_video_layer_track_id == nil,
    "with no V tracks remaining and no clip refs, default should be NULL")
Sequence.assert_inv8(mB)

-- Scenario C: master with only V1 AND a clip in another sequence referencing
-- it. Deleting V1 must refuse.
local mC = make_sequence("mC", "master")
local mC_v1 = add_track("mC", mC, "VIDEO", 1)
Sequence.update(mC, { default_video_layer_track_id = mC_v1 })
-- Give the master a 100-frame media_ref so a clip referencing it passes INV-4.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'm', '/tmp/m.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(string.format(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', '%s', '%s', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)",
    mC, mC_v1)))

local edit = make_sequence("edit", "nested")
local edit_v1 = add_track("edit", edit, "VIDEO", 1)
Clip.create({
    project_id = "p1",
    owner_sequence_id = edit,
    track_id = edit_v1,
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

local ok, err = pcall(function() Track.delete(mC_v1) end)
assert(not ok, "deleting last V track of a master with live clip refs must refuse")
assert(tostring(err):find(mC_v1, 1, true),
    "error must name the track id; got: " .. tostring(err))
-- After refusal, master's V1 still exists.
local rowC = Sequence.find(mC)
assert(rowC.default_video_layer_track_id == mC_v1,
    "after refusal, default must still point at the un-deleted track")

print("✅ test_master_track_delete_default_repoint.lua passed")
