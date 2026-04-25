--- Black-box tests for the Media model's batch query methods.
-- Covers the four N+1-killing functions added during the relink speed
-- pass: load_for_project, load_many, batch_get_source_extents,
-- batch_set_file_paths. Each test describes what the batch API
-- observably does; expected values are derived from the domain
-- (how many media exist, what source ranges clips span, which paths
-- change), not from tracing the implementation.

require("test_env")

local database = require("core.database")
local Project = require("models.project")
local Media = require("models.media")
local Clip = require("models.clip")

local failed = 0
local function check(label, cond)
    if cond then
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- ---------------------------------------------------------------------------
-- Fixture setup: one project, three media, several clips per media so
-- the extent math has real ranges to aggregate.
-- ---------------------------------------------------------------------------
local db_path = "/tmp/jve/test_media_batch_queries_" .. os.time() .. ".jvp"
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local project = Project.create("Batch Project", { fps_mismatch_policy = 'resample' })
assert(project:save())

-- A second project to confirm load_for_project is scoped.
local other_project = Project.create("Other Project", { fps_mismatch_policy = 'resample' })
assert(other_project:save())

local function make_media(params)
    local m = Media.create(params)
    assert(m:save(), "save media " .. tostring(params.id))
    return m
end

-- Three media rows — loaded back from the DB by the queries under test;
-- the `Media` instances returned here aren't needed locally.
make_media({
    id = "media_a", project_id = project.id,
    file_path = "/mnt/footage/a.mov", name = "a.mov",
    duration_frames = 1000,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    codec = "prores", is_still = false,
})
make_media({
    id = "media_b", project_id = project.id,
    file_path = "/mnt/footage/b.mov", name = "b.mov",
    duration_frames = 2000,
    fps_numerator = 24, fps_denominator = 1,
    width = 3840, height = 2160,
    codec = "h264", is_still = false,
})
make_media({
    id = "media_c", project_id = project.id,
    file_path = "/mnt/footage/c.wav", name = "c.wav",
    duration_frames = 48000,
    fps_numerator = 48000, fps_denominator = 1,
    width = 0, height = 0,
    audio_sample_rate = 48000, audio_channels = 2,
    codec = "pcm_s16le", is_still = false,
})
-- A media that belongs to a different project — must never leak into
-- load_for_project(project.id).
make_media({
    id = "media_other", project_id = other_project.id,
    file_path = "/mnt/footage/other.mov", name = "other.mov",
    duration_frames = 500,
    fps_numerator = 30, fps_denominator = 1,
    width = 1280, height = 720,
    codec = "h264", is_still = false,
})

-- Track + sequence rows (referenced by clip FKs)
local db = database.get_connection()
local now = os.time()
db:exec(string.format(
    "INSERT INTO sequences (id, project_id, name, created_at, modified_at, "
    .. "fps_numerator, fps_denominator, audio_rate, width, height) "
    .. "VALUES ('seq1', '%s', 'Seq', %d, %d, 25, 1, 48000, 1920, 1080)",
    project.id, now, now))
db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1)")
db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('track_a1', 'seq1', 'A1', 'AUDIO', 1, 1)")
-- Second video track lets us drop a master clip that spans the whole
-- source range without colliding with timeline clips on track_v1.
db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('track_v2', 'seq1', 'V2', 'VIDEO', 2, 1)")

--- Make a clip on a named track at a specific timeline start so we
--- don't trip the VIDEO_OVERLAP trigger.
local function make_clip(params)
    local c = Clip.create("Clip " .. params.id, params.media_id, {
        id = params.id, project_id = project.id,
        clip_kind = params.clip_kind or "timeline",
        track_id = params.track_id,
        nested_sequence_id = "mc_" .. params.media_id,
        owner_sequence_id = "seq1",
        timeline_start = params.timeline_start,
        duration = params.source_out - params.source_in,
        source_in = params.source_in, source_out = params.source_out,
        fps_numerator = params.fps_num, fps_denominator = params.fps_den,
    })
    assert(c:save({skip_occlusion = true}))
    return c
end

-- media_a: two non-overlapping timeline clips on track_v1.
-- Source ranges [100, 300] and [500, 700] at 25fps — extent math
-- should pick up [100, 700].
make_clip({ id="clip_a1", media_id="media_a", track_id="track_v1",
    timeline_start=0,   source_in=100, source_out=300, fps_num=25, fps_den=1 })
make_clip({ id="clip_a2", media_id="media_a", track_id="track_v1",
    timeline_start=200, source_in=500, source_out=700, fps_num=25, fps_den=1 })
-- media_b: one clip on track_v1 (after media_a clips). Source [600, 900] at 24fps.
make_clip({ id="clip_b1", media_id="media_b", track_id="track_v1",
    timeline_start=400, source_in=600, source_out=900, fps_num=24, fps_den=1 })
-- media_c: audio clip on track_a1 (audio track). Source [1000, 4000] at 48kHz.
make_clip({ id="clip_c1", media_id="media_c", track_id="track_a1",
    timeline_start=0,   source_in=1000, source_out=4000, fps_num=48000, fps_den=1 })

-- Master clip for media_a spanning the full source range [0, 1000].
-- On a separate video track so it doesn't overlap timeline clips. If
-- batch_get_source_extents counted master clips, media_a's extent
-- would stretch to [0, 1000] instead of [100, 700]. The check below
-- verifies it does not.
make_clip({ id="mc_media_a", media_id="media_a", track_id="track_v2",
    timeline_start=0,   source_in=0, source_out=1000, fps_num=25, fps_den=1,
    clip_kind="master" })

-- ---------------------------------------------------------------------------
-- load_for_project: returns exactly the media in the specified project,
-- with all primary fields hydrated.
-- ---------------------------------------------------------------------------
print("\n--- load_for_project ---")
local project_media = Media.load_for_project(project.id)
check("returns the three media in this project",
    #project_media == 3)
local ids_seen = {}
for _, m in ipairs(project_media) do ids_seen[m.id] = true end
check("includes media_a", ids_seen["media_a"] == true)
check("includes media_b", ids_seen["media_b"] == true)
check("includes media_c", ids_seen["media_c"] == true)
check("excludes media from other project", ids_seen["media_other"] == nil)

local sample = project_media[1]
check("hydrated media has file_path", sample:get_file_path() ~= nil)
check("hydrated media has frame_rate with numerator", sample.frame_rate and sample.frame_rate.fps_numerator ~= nil)
check("hydrated media has codec", sample.codec ~= nil)

local empty_project_media = Media.load_for_project("nonexistent-project")
check("unknown project returns empty array",
    type(empty_project_media) == "table" and #empty_project_media == 0)

-- ---------------------------------------------------------------------------
-- load_many: given a set of ids, returns only those media.
-- ---------------------------------------------------------------------------
print("\n--- load_many ---")
local picked = Media.load_many({"media_a", "media_c"})
check("returns exactly the requested count",
    #picked == 2)
local picked_ids = {}
for _, m in ipairs(picked) do picked_ids[m.id] = true end
check("includes media_a", picked_ids["media_a"] == true)
check("includes media_c", picked_ids["media_c"] == true)
check("does not include unrequested media_b", picked_ids["media_b"] == nil)

local none = Media.load_many({})
check("empty input returns empty array", type(none) == "table" and #none == 0)

-- Nonexistent ids silently omitted (invariant: caller can detect by comparing
-- result length to input length).
local mixed = Media.load_many({"media_a", "does-not-exist"})
check("nonexistent ids silently omitted from result", #mixed == 1)

-- ---------------------------------------------------------------------------
-- batch_get_source_extents: min/max source_in/out across non-master clips
-- per media, normalized to each media's target rate.
-- ---------------------------------------------------------------------------
print("\n--- batch_get_source_extents ---")

-- media_a clips at native rate 25fps, target rate 25 → no normalization.
-- Expected min_in=100, max_out=700 (from clip_a1 and clip_a2).
local extents = Media.batch_get_source_extents({
    media_a = 25, media_b = 24, media_c = 48000,
})
check("media_a extent_start reflects earliest non-master source_in (100)",
    extents["media_a"][1] == 100)
check("media_a extent_end reflects latest non-master source_out (700)",
    extents["media_a"][2] == 700)

-- media_b clip at native 24fps, target 24 → no normalization. Single clip [600, 900].
check("media_b extent_start (600)", extents["media_b"][1] == 600)
check("media_b extent_end (900)", extents["media_b"][2] == 900)

-- media_c audio clip at 48kHz native and target → no normalization.
check("media_c extent_start (1000 samples)", extents["media_c"][1] == 1000)
check("media_c extent_end (4000 samples)", extents["media_c"][2] == 4000)

-- Master clips excluded: if master were counted, media_a's range would
-- stretch to [0, 1000]. Confirmed above.
check("master clip excluded from media_a extent",
    extents["media_a"][1] ~= 0 and extents["media_a"][2] ~= 1000)

-- Normalization: request media_a extent at rate 50 instead of 25.
-- Native clips at 25; target 50 means double each value.
local extents_doubled = Media.batch_get_source_extents({media_a = 50})
check("rate conversion doubles extent values (25→50)",
    extents_doubled["media_a"][1] == 200 and extents_doubled["media_a"][2] == 1400)

-- Media with no non-master clips gets {nil, nil} — not omitted entirely.
make_media({
    id = "media_empty", project_id = project.id,
    file_path = "/mnt/footage/empty.mov", name = "empty.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080, codec = "prores", is_still = false,
})
local extents_with_empty = Media.batch_get_source_extents({media_empty = 25})
check("media with no clips appears in result map",
    extents_with_empty["media_empty"] ~= nil)
check("media with no clips has nil extent bounds",
    extents_with_empty["media_empty"][1] == nil and extents_with_empty["media_empty"][2] == nil)

-- Invalid rate is a hard error (rule 1.14: no fabricated default fps).
local ok_bad_rate = pcall(Media.batch_get_source_extents, {media_a = 0})
check("zero target_rate is a hard error", not ok_bad_rate)

local ok_nil_rate = pcall(Media.batch_get_source_extents, {media_a = nil})
-- nil rate means the key isn't in the map (Lua semantic) — empty input case
check("nil rate via absent key is an empty input (not an error)", ok_nil_rate ~= false)

-- ---------------------------------------------------------------------------
-- batch_set_file_paths: changes persist; returns pre-change linked-file
-- state ({file_path, metadata}) for undo. With a tc_updates argument,
-- metadata's start_tc_* fields move atomically with the path.
-- ---------------------------------------------------------------------------
print("\n--- batch_set_file_paths ---")

local old_state = Media.batch_set_file_paths({
    media_a = "/new/a.mov",
    media_b = "/new/b.mov",
})
check("returns old state entry for media_a with file_path",
    type(old_state["media_a"]) == "table"
    and old_state["media_a"].file_path == "/mnt/footage/a.mov")
check("returns old state entry for media_b with file_path",
    type(old_state["media_b"]) == "table"
    and old_state["media_b"].file_path == "/mnt/footage/b.mov")

local reloaded_a = Media.load("media_a")
check("media_a file_path persisted to new value",
    reloaded_a:get_file_path() == "/new/a.mov")
local reloaded_b = Media.load("media_b")
check("media_b file_path persisted to new value",
    reloaded_b:get_file_path() == "/new/b.mov")

-- Media not in the change set is untouched.
local reloaded_c = Media.load("media_c")
check("media_c file_path unchanged",
    reloaded_c:get_file_path() == "/mnt/footage/c.wav")

-- Empty input is a no-op (returns empty map).
local nothing_changed = Media.batch_set_file_paths({})
check("empty change set returns empty map and changes nothing",
    type(nothing_changed) == "table" and next(nothing_changed) == nil)

-- Nonexistent media is a hard error (invariant: planner should never
-- reference a stale media_id).
local ok_bad_id = pcall(Media.batch_set_file_paths, {["nope"] = "/nope.mov"})
check("nonexistent media_id is a hard error", not ok_bad_id)

-- Empty string path is a hard error (file_path must be non-empty).
local ok_empty_path = pcall(Media.batch_set_file_paths, {media_a = ""})
check("empty new_path is a hard error", not ok_empty_path)

-- Round-trip: batch_restore_file_state with the captured old state must
-- put everything back where it was. This is exactly how RelinkClips undo
-- uses it.
Media.batch_restore_file_state(old_state)
local restored_a = Media.load("media_a")
check("round-trip restores original media_a path",
    restored_a:get_file_path() == "/mnt/footage/a.mov")

-- TC-update co-edit: supplying tc_updates alongside path_changes writes
-- start_tc_* into the metadata JSON atomically with the path move.
local probed_tc = {
    start_tc_value = 2063463,
    start_tc_rate = 25,
    start_tc_audio_samples = 3961848960,
    start_tc_audio_rate = 48000,
}
local old_state2 = Media.batch_set_file_paths(
    { media_a = "/trimmed/a.mov" },
    { media_a = probed_tc })
check("returns old file_path in round 2",
    old_state2.media_a.file_path == "/mnt/footage/a.mov")
check("captures pre-change metadata string for undo",
    type(old_state2.media_a.metadata) == "string")

local reloaded_a2 = Media.load("media_a")
local meta_json = reloaded_a2.metadata
local json = require("dkjson")
local meta = json.decode(meta_json)
check("start_tc_value written from probed_tc",
    meta and meta.start_tc_value == 2063463)
check("start_tc_audio_samples written from probed_tc",
    meta and meta.start_tc_audio_samples == 3961848960)

-- A tc_updates entry that doesn't correspond to any path change is a
-- planner bug: metadata would never be written, peaks would silently
-- break. Must surface, not be silently ignored.
local ok_stray_tc = pcall(Media.batch_set_file_paths,
    { media_a = "/another/a.mov" },
    { media_b = probed_tc })
check("tc_updates key without matching path_changes key is a hard error",
    not ok_stray_tc)

-- Restoration also reverts metadata to pre-change JSON.
Media.batch_restore_file_state(old_state2)
local restored_a2 = Media.load("media_a")
check("round-trip restores file_path after TC edit",
    restored_a2:get_file_path() == "/mnt/footage/a.mov")
check("round-trip restores metadata after TC edit",
    restored_a2.metadata == old_state2.media_a.metadata)

os.remove(db_path)

if failed > 0 then
    print(string.format("\n%d check(s) failed", failed))
    os.exit(1)
end
print("\n✅ test_media_batch_queries.lua passed")
