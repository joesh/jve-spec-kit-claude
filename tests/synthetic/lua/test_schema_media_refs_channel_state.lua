-- T004 (013): media_refs_channel_state shape per data-model.md — Phase 4a.
-- PK: master_track_id (single column, TEXT, FK → tracks(id) ON DELETE CASCADE).
-- owner_sequence_id and channel_index columns DROPPED — owner is implied by
-- tracks.sequence_id; channel identity is the track UUID itself.
-- enabled + default_gain_db are NOT NULL with no DEFAULT (rule 2.13 — the
-- absence-of-row case is "inherit"; a materialized row must carry real values).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_media_refs_channel_state.db"
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
            type    = stmt:value(2),
            notnull = stmt:value(3),
            dflt    = stmt:value(4),
            pk      = stmt:value(5),
        }
    end
    stmt:finalize()
    return cols
end

local cols = read_columns("media_refs_channel_state")
assert(next(cols) ~= nil, "media_refs_channel_state table missing (T008 not landed?)")

-- New column set: master_track_id, enabled, default_gain_db.
-- owner_sequence_id and channel_index must NOT exist.
assert(cols["master_track_id"],  "media_refs_channel_state.master_track_id missing")
assert(cols["enabled"],          "media_refs_channel_state.enabled missing")
assert(cols["default_gain_db"],  "media_refs_channel_state.default_gain_db missing")
assert(not cols["owner_sequence_id"],
    "media_refs_channel_state.owner_sequence_id must NOT exist (dropped in Phase 4a)")
assert(not cols["channel_index"],
    "media_refs_channel_state.channel_index must NOT exist (dropped in Phase 4a)")

for _, col in ipairs({"master_track_id", "enabled", "default_gain_db"}) do
    assert(cols[col].notnull == 1,
        "media_refs_channel_state." .. col .. " must be NOT NULL")
end
assert(cols["enabled"].dflt == nil,
    "media_refs_channel_state.enabled must have no DEFAULT (rule 2.13)")
assert(cols["default_gain_db"].dflt == nil,
    "media_refs_channel_state.default_gain_db must have no DEFAULT (rule 2.13)")
assert(cols["master_track_id"].pk > 0,
    "media_refs_channel_state.master_track_id must be the sole PK")

-- Scaffold for behavioral INSERT tests.
assert(db:exec("PRAGMA foreign_keys = ON"))
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'seq-master', 'A1', 'AUDIO', 1), "
    .. "       ('m-a2', 'seq-master', 'A2', 'AUDIO', 2)"))

-- Good: single master_track_id PK.
assert(db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, enabled, default_gain_db) "
    .. "VALUES ('m-a1', 1, -3.0)"),
    "full INSERT into media_refs_channel_state failed")

-- Bad: INSERT missing enabled.
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, default_gain_db) "
    .. "VALUES ('m-a2', 0.0)"),
    "INSERT missing enabled was accepted; rule 2.13 — no column default")

-- Bad: INSERT missing default_gain_db.
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, enabled) "
    .. "VALUES ('m-a2', 1)"),
    "INSERT missing default_gain_db was accepted; rule 2.13 — no column default")

-- Good second row (a2 not yet inserted after failed attempts above).
assert(db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, enabled, default_gain_db) "
    .. "VALUES ('m-a2', 0, -6.0)"),
    "INSERT of second master track state failed")

-- Bad: duplicate PK.
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, enabled, default_gain_db) "
    .. "VALUES ('m-a1', 1, 0.0)"),
    "duplicate master_track_id accepted; PK missing")

-- CASCADE from tracks: deleting master AUDIO track cascades its state row out.
assert(db:exec("DELETE FROM tracks WHERE id = 'm-a1'"),
    "DELETE of master AUDIO track failed")
local stmt = db:prepare(
    "SELECT COUNT(*) FROM media_refs_channel_state WHERE master_track_id = 'm-a1'")
assert(stmt:exec()); stmt:next()
local c1 = stmt:value(0); stmt:finalize()
assert(c1 == 0,
    "media_refs_channel_state row not cascaded on master track delete; ON DELETE CASCADE missing")

-- a2 row must survive deletion of a1.
local stmt2 = db:prepare(
    "SELECT COUNT(*) FROM media_refs_channel_state WHERE master_track_id = 'm-a2'")
assert(stmt2:exec()); stmt2:next()
local c2 = stmt2:value(0); stmt2:finalize()
assert(c2 == 1, "a2 state row must survive deletion of a1 track")

print("✅ test_schema_media_refs_channel_state.lua passed")
