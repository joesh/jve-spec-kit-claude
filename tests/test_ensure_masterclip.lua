require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Media = require("models.media")

local pass_count = 0
local fail_count = 0

local function check(label, condition, detail)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (detail and (" — " .. detail) or ""))
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

local dkjson = require("dkjson")

print("\n=== Sequence.ensure_master Tests (013/V13) ===")

-- Set up database
local db_path = "/tmp/jve/test_ensure_masterclip.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

--------------------------------------------------------------------------------
-- Input validation
--------------------------------------------------------------------------------

print("\n--- ensure_master: input validation ---")

expect_error("nil media_id asserts", function()
    Sequence.ensure_master(nil, "proj1")
end, "media_id is required")

expect_error("empty media_id asserts", function()
    Sequence.ensure_master("", "proj1")
end, "media_id is required")

expect_error("nil project_id asserts", function()
    Sequence.ensure_master("some_media", nil)
end, "project_id is required")

expect_error("empty project_id asserts", function()
    Sequence.ensure_master("some_media", "")
end, "project_id is required")

expect_error("nonexistent media_id asserts", function()
    Sequence.ensure_master("nonexistent_media_id", "proj1")
end, "Media record not found")

--------------------------------------------------------------------------------
-- Happy path: video+audio media → kind='master' Sequence + tracks + media_refs
--------------------------------------------------------------------------------

local function count_tracks(seq_id, ttype)
    local stmt = assert(db:prepare(
        "SELECT COUNT(*) FROM tracks WHERE sequence_id = ? AND track_type = ?"))
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, ttype)
    assert(stmt:exec()) stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local function count_media_refs(seq_id)
    local stmt = assert(db:prepare(
        "SELECT COUNT(*) FROM media_refs WHERE owner_sequence_id = ?"))
    stmt:bind_value(1, seq_id)
    assert(stmt:exec()) stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

print("\n--- ensure_master: video+audio media ---")

local media_va = Media.create({
    id = "media_va",
    project_id = "proj1",
    name = "VideoAudio",
    file_path = "synthetic://video_audio.mov",
    duration_frames = 240,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
    codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = 0, start_tc_rate = 24,
        start_tc_audio_samples = 0, start_tc_audio_rate = 48000,
    }),
})
assert(media_va:save(), "Failed to save video+audio media")

local mc_id = Sequence.ensure_master("media_va", "proj1")
check("returns non-nil ID", mc_id ~= nil)
check("returns string ID", type(mc_id) == "string")

local mc_seq = Sequence.load(mc_id)
check("master sequence exists", mc_seq ~= nil)
check("kind is master", mc_seq and mc_seq.kind == "master",
    "got: " .. tostring(mc_seq and mc_seq.kind))
check("name matches media", mc_seq and mc_seq.name == "VideoAudio")
check("fps matches media",
    mc_seq and mc_seq.frame_rate.fps_numerator == 24
       and mc_seq.frame_rate.fps_denominator == 1)
check("dimensions match media",
    mc_seq and mc_seq.width == 1920 and mc_seq.height == 1080)

check("1 video track", count_tracks(mc_id, "VIDEO") == 1)
-- Stereo: per FR-005, audio is one media_ref per channel on dedicated tracks.
-- ensure_master may create N audio tracks (one per channel) or 1 audio track
-- holding N media_refs. Assert N media_refs total to match channel count.
local audio_track_count = count_tracks(mc_id, "AUDIO")
check("1+ audio track(s)", audio_track_count >= 1, "got: " .. audio_track_count)

local total_mrefs = count_media_refs(mc_id)
check("3 media_refs (1V + 2A channels)", total_mrefs == 3,
    "got: " .. total_mrefs)

--------------------------------------------------------------------------------
-- Idempotent: same media → same master sequence
--------------------------------------------------------------------------------

print("\n--- ensure_master: idempotent ---")

local mc_id2 = Sequence.ensure_master("media_va", "proj1")
check("returns same ID on repeat", mc_id == mc_id2,
    string.format("first=%s second=%s", tostring(mc_id), tostring(mc_id2)))
check("no duplicate media_refs", count_media_refs(mc_id) == 3)

--------------------------------------------------------------------------------
-- Video-only media → 1 V track + 1 media_ref
--------------------------------------------------------------------------------

print("\n--- ensure_master: video-only media ---")

local media_v = Media.create({
    id = "media_v",
    project_id = "proj1",
    name = "VideoOnly",
    file_path = "synthetic://video_only.mov",
    duration_frames = 120,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1280, height = 720,
    audio_channels = 0,
    codec = "prores",
    metadata = dkjson.encode({ start_tc_value = 0, start_tc_rate = 24 }),
})
assert(media_v:save())

local mv_id = Sequence.ensure_master("media_v", "proj1")
local mv_seq = Sequence.load(mv_id)
check("video-only kind=master", mv_seq and mv_seq.kind == "master")
check("video-only 1 V track", count_tracks(mv_id, "VIDEO") == 1)
check("video-only 0 A tracks", count_tracks(mv_id, "AUDIO") == 0)
check("video-only 1 media_ref", count_media_refs(mv_id) == 1)

print(string.format("\n=== %d passed, %d failed ===", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_ensure_masterclip.lua passed")
