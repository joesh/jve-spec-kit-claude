-- T018 / CT-R1 (013): master resolution (leaf).
-- Given a kind='master' sequence with 1 video + 2 audio media_refs, resolving
-- the full range returns 3 ResolvedEntry rows with correct media_path from each
-- media_ref's media_id, source_in/out in file-native units, and provenance of
-- length 1 (the media_ref id).
-- Expected to FAIL until T030 (resolve_in_range) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_master_leaf.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
-- Three tracks: V1, A1, A2.
for name, idx in pairs({ V1 = 1, A1 = 1, A2 = 2 }) do
    local ttype = name:sub(1,1) == "V" and "VIDEO" or "AUDIO"
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('trk-%s', 'm', '%s', '%s', %d)", name, name, ttype, idx)))
end
-- Three media files.
for _, m in ipairs({ { id = "mf-v", path = "/tmp/vid.mov" },
                     { id = "mf-a1", path = "/tmp/a1.wav" },
                     { id = "mf-a2", path = "/tmp/a2.wav" } }) do
    assert(db:exec(string.format(
        "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
        .. "fps_numerator, fps_denominator, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', 'n', '%s', 100, 24, 1, 0, 0)", m.id, m.path)))
end
-- Three media_refs covering 0..100 in each stream.
local refs = {
    { id = "mr-v",  track = "trk-V1", media = "mf-v"  },
    { id = "mr-a1", track = "trk-A1", media = "mf-a1" },
    { id = "mr-a2", track = "trk-A2", media = "mf-a2" },
}
for _, r in ipairs(refs) do
    assert(db:exec(string.format(
        "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
        .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
        .. "enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', 'm', '%s', '%s', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)",
        r.id, r.track, r.media)))
end

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("m", 0, 100, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "resample",
})

assert(type(entries) == "table", "resolve_in_range must return an array")
assert(#entries == 3, "expected 3 entries, got " .. tostring(#entries))

local by_path = {}
for _, e in ipairs(entries) do by_path[e.media_path] = e end
for _, p in ipairs({"/tmp/vid.mov", "/tmp/a1.wav", "/tmp/a2.wav"}) do
    assert(by_path[p], "missing entry for " .. p)
    assert(by_path[p].source_in == 0 and by_path[p].source_out == 100,
        "source range wrong for " .. p)
    assert(#by_path[p].provenance == 1,
        "provenance length must be 1 for a leaf master; got "
        .. tostring(#by_path[p].provenance) .. " for " .. p)
end

print("✅ test_resolve_master_leaf.lua passed")
