-- T009 (013): media_refs must be owned by a kind='master' sequence.
-- Model layer must refuse with a loud assert naming the media_ref id, the wrong
-- owner_sequence_id, and its actual kind (rule 1.14). Schema trigger is defense-in-depth;
-- this test verifies the model-layer check fires FIRST with the actionable message.
-- Expected to FAIL until T014 (media_ref.lua) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_media_ref_inv1.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

-- A nested (non-master) sequence. Media_refs must be owned by a kind='master' — cannot live here.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-edit', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-v1', 'seq-edit', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med1', 'p1', 'x.mov', '/tmp/x.mov', 100, 24, 1, 0, 0)"))

-- Model API under test.
local MediaRef = require("models.media_ref")

-- Good control: creating a media_ref in a master sequence succeeds.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-master-v1', 'seq-master', 'V1', 'VIDEO', 1)"))

local good_id = MediaRef.create({
    project_id = "p1",
    owner_sequence_id = "seq-master",
    track_id = "trk-master-v1",
    media_id = "med1",
    source_in_frame = 0,
    source_out_frame = 100,
    sequence_start_frame = 0,
    duration_frames = 100,
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})
assert(type(good_id) == "string" and good_id ~= "",
    "MediaRef.create on master should return the new id")

-- Bad: owner_sequence_id references a nested sequence. Model layer MUST assert
-- with a message naming the wrong owner's id and its actual kind.
local ok, err = pcall(function()
    MediaRef.create({
        project_id = "p1",
        owner_sequence_id = "seq-edit",  -- kind='sequence' — violates "media_refs must be kind='master'"
        track_id = "trk-v1",
        media_id = "med1",
        source_in_frame = 0,
        source_out_frame = 100,
        sequence_start_frame = 0,
        duration_frames = 100,
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end)
assert(not ok, "MediaRef.create on a nested sequence must refuse (media_refs must be kind='master')")
assert(tostring(err):find("INV%-1"),
    "MediaRef.create error must name INV-1; got: " .. tostring(err))
assert(tostring(err):find("seq%-edit"),
    "MediaRef.create error must name the offending owner_sequence_id; got: " .. tostring(err))
assert(tostring(err):find("sequence"),
    "MediaRef.create error must name the actual kind ('sequence'); got: " .. tostring(err))

-- Bad: owner_sequence_id references a sequence that doesn't exist. Model should
-- assert with a clear "not found" message, not surface a raw FK error.
local ok2, err2 = pcall(function()
    MediaRef.create({
        project_id = "p1",
        owner_sequence_id = "seq-ghost",
        track_id = "trk-master-v1",
        media_id = "med1",
        source_in_frame = 0,
        source_out_frame = 100,
        sequence_start_frame = 0,
        duration_frames = 100,
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end)
assert(not ok2, "MediaRef.create on missing sequence must refuse")
assert(tostring(err2):find("seq%-ghost"),
    "Error must name the missing sequence id; got: " .. tostring(err2))

print("✅ test_media_ref_inv1.lua passed")
