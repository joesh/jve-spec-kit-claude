-- T010 (013): INV-2 — clips.owner_sequence_id MUST reference a kind='nested' sequence.
-- Model layer must refuse with a loud assert naming the clip's owner_sequence_id
-- and its actual kind (rule 1.14).
-- Expected to FAIL until T015 (clip.lua narrow) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_clip_inv2.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
-- A master (NOT a nested). INV-2 says clips can't live here.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
-- A proper nested edit sequence (good control).
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
-- Give the master a 100-frame media_ref so its effective duration = 100.
-- Without this, INV-4 would fire before INV-2.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'm', '/tmp/m.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'seq-master', 'trk-master-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))

local Clip = require("models.clip")

-- Good: clip in a nested sequence, referencing a master, succeeds.
local good_id = Clip.create({
    project_id = "p1",
    owner_sequence_id = "seq-edit",
    track_id = "trk-edit-v1",
    nested_sequence_id = "seq-master",
    name = "c1",
    timeline_start_frame = 0,
    duration_frames = 100,
    source_in_frame = 0,
    source_out_frame = 100,
    fps_mismatch_policy = "passthrough",
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})
assert(type(good_id) == "string" and good_id ~= "",
    "Clip.create on nested sequence should return the new id")

-- Bad: owner_sequence_id points at a master. INV-2 must refuse with context.
local ok, err = pcall(function()
    Clip.create({
        project_id = "p1",
        owner_sequence_id = "seq-master",  -- kind='master' — INV-2 violation
        track_id = "trk-master-v1",
        nested_sequence_id = "seq-edit",
        name = "bad",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end)
assert(not ok, "Clip.create on a master sequence must refuse (INV-2)")
assert(tostring(err):find("INV%-2"),
    "Clip.create error must name INV-2; got: " .. tostring(err))
assert(tostring(err):find("seq%-master"),
    "Error must name the offending owner_sequence_id; got: " .. tostring(err))
assert(tostring(err):find("master"),
    "Error must name the actual kind ('master'); got: " .. tostring(err))

-- Bad: fps_mismatch_policy must be explicit (NOT NULL, no default under rule 2.13).
local ok_nopol = pcall(function()
    Clip.create({
        project_id = "p1",
        owner_sequence_id = "seq-edit",
        track_id = "trk-edit-v1",
        nested_sequence_id = "seq-master",
        name = "no-policy",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        -- fps_mismatch_policy intentionally omitted
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end)
assert(not ok_nopol,
    "Clip.create without fps_mismatch_policy must refuse (rule 2.13 no default)")

print("✅ test_clip_inv2.lua passed")
