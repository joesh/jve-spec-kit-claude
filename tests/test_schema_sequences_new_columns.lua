-- T007 (013): sequences gains four new columns per data-model.md.
--   default_video_layer_track_id  TEXT, FK to tracks(id), ON DELETE SET NULL
--   video_start_tc_frame          INTEGER, nullable
--   audio_start_tc_samples        INTEGER, nullable
--   fps_mismatch_policy           TEXT, nullable (NULL = inherit project default)
-- Expected to FAIL until T008 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_sequences_new_columns.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()

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
        }
    end
    stmt:finalize()
    return cols
end

local function read_fks(tbl)
    local stmt = db:prepare(string.format("PRAGMA foreign_key_list(%s)", tbl))
    assert(stmt, "PRAGMA foreign_key_list prepare failed for " .. tbl)
    assert(stmt:exec(), "PRAGMA foreign_key_list exec failed for " .. tbl)
    -- Columns per row: id(0), seq(1), table(2), from(3), to(4), on_update(5), on_delete(6), match(7)
    local fks = {}
    while stmt:next() do
        fks[#fks + 1] = {
            from = stmt:value(3),
            to_table = stmt:value(2),
            on_delete = stmt:value(6),
        }
    end
    stmt:finalize()
    return fks
end

local cols = read_columns("sequences")
for _, col in ipairs({
    "default_video_layer_track_id", "video_start_tc_frame",
    "audio_start_tc_samples", "fps_mismatch_policy",
}) do
    assert(cols[col], "sequences." .. col .. " missing (T008 must add it)")
    assert(cols[col].notnull == 0, "sequences." .. col .. " must be nullable (inherit semantics)")
end

local fks = read_fks("sequences")
local found_default_layer_fk = false
for _, fk in ipairs(fks) do
    if fk.from == "default_video_layer_track_id" then
        found_default_layer_fk = true
        assert(fk.to_table == "tracks", "default_video_layer_track_id must FK to tracks")
        assert(fk.on_delete == "SET NULL",
            "default_video_layer_track_id FK must be ON DELETE SET NULL, got " .. tostring(fk.on_delete))
    end
end
assert(found_default_layer_fk, "default_video_layer_track_id FK to tracks missing")

-- Behavioral: when the referenced track is deleted, the column goes back to NULL.
assert(db:exec("PRAGMA foreign_keys = ON"))
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, default_video_layer_track_id, "
    .. "created_at, modified_at) "
    .. "VALUES ('seq1', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, NULL, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-v1', 'seq1', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "UPDATE sequences SET default_video_layer_track_id = 'trk-v1' WHERE id = 'seq1'"))

assert(db:exec("DELETE FROM tracks WHERE id = 'trk-v1'"),
    "DELETE of referenced track failed; FK should allow with SET NULL")

local stmt = db:prepare(
    "SELECT default_video_layer_track_id FROM sequences WHERE id = 'seq1'")
assert(stmt:exec())
stmt:next()
local after = stmt:value(0)
stmt:finalize()
assert(after == nil,
    "default_video_layer_track_id should be NULL after track delete; got " .. tostring(after))

print("✅ test_schema_sequences_new_columns.lua passed")
