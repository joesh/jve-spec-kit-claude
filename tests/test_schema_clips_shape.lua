-- T003 (013): clips column changes per data-model.md.
-- DROPPED: clip_kind, media_id, offline. RENAMED: master_clip_id → sequence_id.
-- ADDED: master_layer_track_id (FK, ON DELETE SET NULL), fps_mismatch_policy (nullable).
-- NO DEFAULT on state columns (rule 2.13); name is NOT NULL.
-- Expected to FAIL until T008 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_clips_shape.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()

-- PRAGMA table_info returns rows of (cid, name, type, notnull, dflt_value, pk).
local function read_columns(tbl)
    local stmt = db:prepare(string.format("PRAGMA table_info(%s)", tbl))
    assert(stmt, "PRAGMA prepare failed for " .. tbl)
    assert(stmt:exec(), "PRAGMA exec failed for " .. tbl)
    local cols = {}
    while stmt:next() do
        cols[stmt:value(1)] = {
            type = stmt:value(2),
            notnull = stmt:value(3),
            dflt = stmt:value(4),
            pk = stmt:value(5),
        }
    end
    stmt:finalize()
    return cols
end

local cols = read_columns("clips")

-- Dropped columns must NOT exist.
for _, dead in ipairs({"clip_kind", "media_id", "offline", "master_clip_id"}) do
    assert(cols[dead] == nil,
        string.format("clips.%s still exists; T008 must drop it (FR-018 no back-compat)", dead))
end

-- New columns must exist.
assert(cols["sequence_id"], "clips.sequence_id missing")
assert(cols["master_layer_track_id"], "clips.master_layer_track_id missing")
assert(cols["fps_mismatch_policy"], "clips.fps_mismatch_policy missing")

-- Nullability.
assert(cols["sequence_id"].notnull == 1, "clips.sequence_id must be NOT NULL")
assert(cols["master_layer_track_id"].notnull == 0, "clips.master_layer_track_id must be nullable")
-- fps_mismatch_policy is NOT NULL on the clip: Insert computes duration_frames
-- under a specific policy and writes it here; flipping later is a structural
-- mutation, not a re-resolve.
assert(cols["fps_mismatch_policy"].notnull == 1, "clips.fps_mismatch_policy must be NOT NULL")

-- Source timebase (fps_numerator/fps_denominator) must NOT live on clips —
-- it's dereferenced from sequence_id to avoid denormalization.
assert(cols["fps_numerator"] == nil, "clips.fps_numerator should not exist (dereferenceable)")
assert(cols["fps_denominator"] == nil, "clips.fps_denominator should not exist (dereferenceable)")

-- name must be NOT NULL with no default.
assert(cols["name"], "clips.name missing")
assert(cols["name"].notnull == 1, "clips.name must be NOT NULL")
assert(cols["name"].dflt == nil, "clips.name must have no DEFAULT per rule 2.13")

-- State columns with no DEFAULT (rule 2.13): enabled, volume, playhead_frame.
for _, col in ipairs({"enabled", "volume", "playhead_frame"}) do
    assert(cols[col], string.format("clips.%s missing", col))
    assert(cols[col].dflt == nil,
        string.format("clips.%s must have no DEFAULT (rule 2.13); got %s",
            col, tostring(cols[col].dflt)))
end

print("✅ test_schema_clips_shape.lua passed")
