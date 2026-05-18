-- T011 (013): would_create_cycle DFS per research §3.
-- Every command that writes a clip's source_sequence_id must run this check first;
-- refusing a cycle at mutation time is FR-010 (containment DAG must be acyclic).
-- Expected to FAIL until T016 (cycle.lua) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_cycle_detection.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))

-- Build four non-master sequences A, B, C, D + one master M.
for _, id in ipairs({"A", "B", "C", "D"}) do
    assert(db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', '%s', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)", id, id)))
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('trk-%s-v1', '%s', 'V1', 'VIDEO', 1)", id, id)))
end
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('M', 'p1', 'M', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))

-- Insert a chain A → B → C (via clips). D is isolated; M is a master leaf.
local function insert_clip(id, owner, nested, track)
    assert(db:exec(string.format(
        "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
        .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
        .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', '%s', '%s', '%s', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)",
        id, owner, track, nested)))
end
insert_clip("c-A-in-B", "B", "A", "trk-B-v1")  -- B contains a clip → A
insert_clip("c-B-in-C", "C", "B", "trk-C-v1")  -- C contains a clip → B

local cycle = require("models.cycle")

-- Self-reference: owner = candidate. Must refuse.
assert(cycle.would_create_cycle("A", "A") == true,
    "self-reference must be a cycle")

-- Direct one-hop: C already contains a clip → B → A. Adding A → C would close
-- the loop A→C→B→A. would_create_cycle("A", "C") must be true.
assert(cycle.would_create_cycle("A", "C") == true,
    "transitive cycle A → C (via B) must be detected")

-- Two-hop in the other direction: B → C closes B→C→B (C already refs B).
assert(cycle.would_create_cycle("B", "C") == true,
    "one-hop cycle B → C (C already refs B) must be detected")

-- No cycle: D is isolated, can reference anything.
assert(cycle.would_create_cycle("D", "A") == false,
    "D → A creates no cycle; D is isolated")
assert(cycle.would_create_cycle("D", "C") == false,
    "D → C creates no cycle; D is isolated")

-- Referencing a master is never a cycle (masters have no clips in them).
assert(cycle.would_create_cycle("A", "M") == false,
    "referencing a master is never a cycle")
assert(cycle.would_create_cycle("C", "M") == false,
    "referencing a master is never a cycle")

-- Adjacent-but-not-cyclic: A → D is fine (D has no inbound refs).
assert(cycle.would_create_cycle("A", "D") == false,
    "A → D creates no cycle")

print("✅ test_cycle_detection.lua passed")
