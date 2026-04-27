-- T004 (013): media_refs_channel_state shape per data-model.md.
-- PK (owner_sequence_id, channel_index). Both enabled and default_gain_db are NOT NULL
-- with no DEFAULT (rule 2.13 — the absence-of-row case is "inherit"; a materialized row
-- must carry real values).
-- Expected to FAIL until T008 lands.

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
            type = stmt:value(2),
            notnull = stmt:value(3),
            dflt = stmt:value(4),
            pk = stmt:value(5),
        }
    end
    stmt:finalize()
    return cols
end

local cols = read_columns("media_refs_channel_state")
assert(next(cols) ~= nil, "media_refs_channel_state table missing (T008 not landed?)")

for _, col in ipairs({"owner_sequence_id", "channel_index", "enabled", "default_gain_db"}) do
    assert(cols[col], "media_refs_channel_state." .. col .. " missing")
    assert(cols[col].notnull == 1, "media_refs_channel_state." .. col .. " must be NOT NULL")
end
assert(cols["enabled"].dflt == nil,
    "media_refs_channel_state.enabled must have no DEFAULT (rule 2.13)")
assert(cols["default_gain_db"].dflt == nil,
    "media_refs_channel_state.default_gain_db must have no DEFAULT (rule 2.13)")
assert(cols["owner_sequence_id"].pk > 0 and cols["channel_index"].pk > 0,
    "composite PK (owner_sequence_id, channel_index) missing")

-- Scaffold for behavioral INSERT tests.
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))

-- Good.
assert(db:exec(
    "INSERT INTO media_refs_channel_state (owner_sequence_id, channel_index, enabled, default_gain_db) "
    .. "VALUES ('seq-master', 0, 1, 0.0)"),
    "full INSERT into media_refs_channel_state failed")

-- Bad: INSERT missing enabled or default_gain_db.
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (owner_sequence_id, channel_index, default_gain_db) "
    .. "VALUES ('seq-master', 1, 0.0)"),
    "INSERT missing enabled was accepted; rule 2.13 — no column default")
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (owner_sequence_id, channel_index, enabled) "
    .. "VALUES ('seq-master', 2, 1)"),
    "INSERT missing default_gain_db was accepted; rule 2.13 — no column default")

-- Bad: duplicate PK.
assert(not db:exec(
    "INSERT INTO media_refs_channel_state (owner_sequence_id, channel_index, enabled, default_gain_db) "
    .. "VALUES ('seq-master', 0, 1, 0.0)"),
    "duplicate (owner_sequence_id, channel_index) accepted; PK missing")

print("✅ test_schema_media_refs_channel_state.lua passed")
