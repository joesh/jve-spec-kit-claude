-- Domain behaviors under test (relink-to-trimmed-media scenario):
--
-- (A) Audio timecode of a recording is a property of the recording clock,
--     not of any one stream. A file that stores only a video TC still has
--     a knowable audio TC: the same instant expressed in audio samples.
--     For camera MOVs and BRAW (common-clock capture), probing such a
--     file must answer that audio-TC question — otherwise audio-side
--     callers can't align waveforms to the file's real content.
--
-- (B) A Media row's TC metadata describes the currently-linked file, not
--     some historical version of it. When the link moves to a new file
--     (e.g. Resolve Media-Manage produced a trimmed copy whose embedded
--     TC is later than the original's), the Media row's TC must update
--     in the same atomic step as the path. If the path moves without
--     the TC, waveform rendering computes source-file positions using
--     the wrong origin and clips whose content sits past the trimmed
--     head show no peaks.
--
-- (C) Undoing a relink must put the Media row back exactly as it was —
--     both path and TC metadata revert together.
--
-- No back-compat: existing rows that weren't relinked after the fix keep
-- whatever TC they had.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_relink_tc_resync ---")

-- Fixtures carry authoritative embedded TC:
--   MOV: 25fps, tmcd atom only (no explicit audio TC) at 22:55:38:13.
--   WAV: BWF time_reference (primary audio TC source).
local MOV = env.test_media_path(
    "anamnesis-trimmed/Volumes/AnamBack4 Joe/Footage/Day 12/A035/A035_11192255_C020.mov")
local WAV = env.test_media_path(
    "anamnesis-trimmed/Volumes/AnamBack4 Joe/Footage/Day 12/DAY12 Sound/SCENE1_WT-T001.WAV")

-- -----------------------------------------------------------------------
-- (A) MOV audio TC comes back from the probe, computed as the same instant
--     the video TC names, expressed in audio samples. Domain math only:
--     samples_at_instant = seconds_at_instant * sample_rate.
-- -----------------------------------------------------------------------
print("\n--- (A) MOV audio TC derived on the shared recording clock ---")

local mov = assert(EMP.MEDIA_PROBE(MOV), "probe failed for MOV fixture")
assert(mov.has_video_tc_origin,
    "MOV fixture must carry embedded video TC for this test to be meaningful")
assert(mov.has_audio_tc_origin,
    "A MOV with a video-TC origin must also report an audio-TC origin — "
    .. "video and audio share the recording clock, so both streams "
    .. "refer to the same instant")

local video_tc_seconds = mov.first_frame_tc * mov.fps_den / mov.fps_num
local expected_audio_samples = math.floor(
    video_tc_seconds * mov.audio_sample_rate + 0.5)
assert(mov.first_sample_tc == expected_audio_samples, string.format(
    "audio TC (%d samples) should equal the video TC's instant expressed\n"
    .. "in audio samples (%d). Video TC is %d frames at %d/%d fps =\n"
    .. "%.6fs; at %d Hz that instant is %d samples.",
    mov.first_sample_tc, expected_audio_samples,
    mov.first_frame_tc, mov.fps_num, mov.fps_den,
    video_tc_seconds, mov.audio_sample_rate, expected_audio_samples))

-- -----------------------------------------------------------------------
-- (B) Re-linking a Media row to a new file updates the row's TC metadata
--     atomically with the path. Test with the WAV's true TC (from BWF
--     time_reference) standing in for "the new file's embedded TC" after
--     a Media-Manage trim.
-- -----------------------------------------------------------------------
print("\n--- (B) Relink resyncs TC metadata atomically with the path ---")

local db_path = "/tmp/jve/test_relink_tc_resync_" .. os.time() .. ".jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(db_path); os.remove(db_path.."-wal"); os.remove(db_path.."-shm")

local database = require("core.database")
assert(database.init(db_path), "database.init failed")
local db = database.get_connection()
assert(db, "no db connection")
db:exec(require("import_schema"))

local project_id = "proj-tc-resync"
local media_id = "media-tc-resync"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) VALUES ('%s', 'tc test', %d, %d, 'passthrough')",
    project_id, now, now))

-- Seed the Media row with the kind of "original file TC" a DRP import
-- would write when the original file referenced by the DRP has since been
-- Media-Managed down to a trimmed copy. Pick an origin 1 second earlier
-- than the fixture's real TC so the two are unambiguously different.
local wav = assert(EMP.MEDIA_PROBE(WAV), "probe failed for WAV fixture")
assert(wav.has_audio_tc_origin,
    "WAV fixture must carry a BWF time_reference")
local trimmed_origin_samples = wav.first_sample_tc
local original_origin_samples = trimmed_origin_samples - wav.audio_sample_rate

local json = require("dkjson")
local original_metadata_json = json.encode({
    start_tc_value = original_origin_samples,
    start_tc_rate = wav.audio_sample_rate,
    start_tc_audio_samples = original_origin_samples,
    start_tc_audio_rate = wav.audio_sample_rate,
})

local Media = require("models.media")
local media = Media.create({
    id = media_id,
    project_id = project_id,
    file_path = WAV,
    name = "SCENE1",
    duration_frames = 1495680,
    fps_numerator = wav.audio_sample_rate,
    fps_denominator = 1,
    audio_sample_rate = wav.audio_sample_rate,
    audio_channels = 2,
    width = 0, height = 0,
    codec = "pcm_s24le",
    metadata = original_metadata_json,
})
assert(media:save(), "media save failed")

-- Before relink: the row reports the original file's TC.
local pre = Media.load(media_id)
assert(pre:get_audio_start_tc() == original_origin_samples,
    "setup: the seeded row must report the pre-relink TC")

-- Relink to the same path but with the new file's true TC (what the
-- relinker's probe would produce). Nothing else about the row changes.
local probed_tc = {
    start_tc_value = trimmed_origin_samples,
    start_tc_rate = wav.audio_sample_rate,
    start_tc_audio_samples = trimmed_origin_samples,
    start_tc_audio_rate = wav.audio_sample_rate,
}
local old_state = Media.batch_set_file_paths(
    { [media_id] = WAV },
    { [media_id] = probed_tc })

-- Captured state contains the pre-change file_path AND metadata so undo
-- can revert both.
assert(old_state[media_id].file_path == WAV,
    "captured state must include pre-change file_path")
assert(old_state[media_id].metadata == original_metadata_json,
    "captured state must include pre-change metadata JSON verbatim")

-- After relink: the row describes the new linked file.
local post = Media.load(media_id)
assert(post:get_audio_start_tc() == trimmed_origin_samples, string.format(
    "after relink, the row's audio TC should describe the newly-linked\n"
    .. "file (%d samples), not the previous file (%d samples).",
    trimmed_origin_samples, post:get_audio_start_tc()))

-- Unrelated metadata fields on the row must survive the TC update —
-- they describe things the relink doesn't touch (Set Timecode overrides,
-- future extensions).
local preserved_key, preserved_value = "file_original_timecode", 12345
local with_extras = json.decode(original_metadata_json)
with_extras[preserved_key] = preserved_value
local stmt_extras = assert(db:prepare(
    "UPDATE media SET metadata = ? WHERE id = ?"),
    "setup: failed to prepare metadata UPDATE")
stmt_extras:bind_value(1, json.encode(with_extras))
stmt_extras:bind_value(2, media_id)
assert(stmt_extras:exec(), "setup: metadata UPDATE exec failed")
stmt_extras:finalize()

local second_old_state = Media.batch_set_file_paths(
    { [media_id] = WAV },
    { [media_id] = probed_tc })
local reloaded = Media.load(media_id)
local reloaded_meta = json.decode(reloaded.metadata)
assert(reloaded_meta.start_tc_audio_samples == trimmed_origin_samples,
    "a second relink must re-apply the TC update")
assert(reloaded_meta[preserved_key] == preserved_value, string.format(
    "metadata field unrelated to TC (%s = %s) must survive the merge",
    preserved_key, tostring(preserved_value)))

-- -----------------------------------------------------------------------
-- (C) Undo restores the captured row state exactly.
-- -----------------------------------------------------------------------
print("\n--- (C) Undo restores both path and TC metadata ---")

Media.batch_restore_file_state(second_old_state)
local restored = Media.load(media_id)
assert(restored.metadata == second_old_state[media_id].metadata,
    "undo must restore the metadata JSON exactly as captured")
assert(restored:get_file_path() == second_old_state[media_id].file_path,
    "undo must restore the file_path exactly as captured")

database.shutdown()
os.remove(db_path)

print("✅ test_relink_tc_resync passed")
