-- T013 (013): sequences.default_video_layer_track_id must be non-NULL
-- whenever the sequence has at least one video track.
-- Coverage: Sequence.assert_inv8 fires with a message naming the sequence id
-- and the violation when the default is NULL with V tracks present, or points
-- at a track that's not a VIDEO track of this sequence.

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

local DB_PATH = "/tmp/jve/test_sequence_inv8.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

-- Helper: wrap the 2-step create+save as a single call.
local function make_sequence(name, kind)
    -- 018 INV-7: masters carry no audio_sample_rate; regular sequences require it.
    local asr = (kind == "master") and nil or 48000
    local s = Sequence.create(name, "p1", {  fps_numerator = 24, fps_denominator = 1 },
        1920, 1080, { kind = kind, audio_sample_rate = asr })
    assert(s:save(), "Sequence:save failed")
    return s.id
end

-- Good control: master with no video tracks → default NULL is valid.
local audio_only_id = make_sequence("audio-only", "master")
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-a1', '%s', 'A1', 'AUDIO', 1)", audio_only_id)))
Sequence.assert_inv8(audio_only_id)  -- passes: no V tracks

-- Master with a V track.
local vid_id = make_sequence("vid", "master")
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-v1', '%s', 'V1', 'VIDEO', 1)", vid_id)))

-- Set default to the live V track via Sequence.update — default_video_layer_track_id post-check passes.
Sequence.update(vid_id, { default_video_layer_track_id = "trk-v1" })
Sequence.assert_inv8(vid_id)

-- Direct-SQL NULL'ing the default while a V track exists should cause
-- assert_inv8 to fire. (Sequence.update's post-condition check would also fire,
-- but raw SQL bypasses the command layer.)
assert(db:exec(string.format(
    "UPDATE sequences SET default_video_layer_track_id = NULL WHERE id = '%s'", vid_id)))

local ok, err = pcall(function() Sequence.assert_inv8(vid_id) end)
assert(not ok, "assert_inv8 must fire when default_video_layer_track_id is NULL with a V track present")
assert(tostring(err):find("INV%-8"),
    "error must name INV-8; got: " .. tostring(err))
assert(tostring(err):find(vid_id, 1, true),
    "error must name the sequence id; got: " .. tostring(err))

-- Restore, then try pointing default at an audio track — also a violation.
assert(db:exec(string.format(
    "UPDATE sequences SET default_video_layer_track_id = 'trk-v1' WHERE id = '%s'", vid_id)))
assert(db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-a2', '%s', 'A2', 'AUDIO', 2)", vid_id)))

local ok2, err2 = pcall(function()
    Sequence.update(vid_id, { default_video_layer_track_id = "trk-a2" })
end)
assert(not ok2, "Sequence.update pointing default at an AUDIO track must refuse")
assert(tostring(err2):find("trk%-a2"),
    "error must name the bad track; got: " .. tostring(err2))
assert(tostring(err2):find("VIDEO") or tostring(err2):find("track_type"),
    "error must name the track_type expectation; got: " .. tostring(err2))

print("✅ test_sequence_inv8_default_layer.lua passed")
