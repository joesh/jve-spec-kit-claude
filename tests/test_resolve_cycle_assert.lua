-- T024 / CT-R7 (013): resolver cycle defense-in-depth.
-- The mutation-time check refuses cycles (containment DAG must be acyclic). If a cycle somehow lands in
-- the DB (direct SQL bypassing the model's cycle check, or external mutation),
-- the resolver must assert loudly when it encounters one, naming both sequences
-- in the cycle and the provenance chain.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_cycle_assert.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

-- Two nested sequences A and B. We create A→B and B→A cycles directly via SQL,
-- bypassing the model layer's would_create_cycle check.
for _, id in ipairs({"A", "B"}) do
    assert(db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', '%s', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)", id, id)))
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('%s-v1', '%s', 'V1', 'VIDEO', 1)", id, id)))
end

local function raw_clip(id, owner, track, nested)
    return db:exec(string.format(
        "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
        .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
        .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', '%s', '%s', '%s', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)",
        id, owner, track, nested))
end
assert(raw_clip("c-A-in-B", "B", "B-v1", "A"), "raw clip B→A insert")
assert(raw_clip("c-B-in-A", "A", "A-v1", "B"), "raw clip A→B insert")

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local ok, err = pcall(function()
    Sequence:resolve_in_range("A", 0, 200, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
end)
assert(not ok, "resolver must assert loudly on a cycle (G-R2 defense-in-depth)")
local msg = tostring(err)
assert(msg:find("cycle") or msg:find("recurs"),
    "error must mention cycle/recursion; got: " .. msg)
assert(msg:find("A") and msg:find("B"),
    "error must name both sequences in the cycle; got: " .. msg)

print("✅ test_resolve_cycle_assert.lua passed")
