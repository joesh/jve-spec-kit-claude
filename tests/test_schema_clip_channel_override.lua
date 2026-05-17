-- T005 (013): clip_channel_override shape per data-model.md.
-- PK (clip_id, channel_index). enabled + gain_db are NOT NULL with no DEFAULT (rule 2.13).
-- ON DELETE CASCADE from clips (row evaporates with its clip).
-- Expected to FAIL until T008 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_clip_channel_override.db"
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

local cols = read_columns("clip_channel_override")
assert(next(cols) ~= nil, "clip_channel_override table missing (T008 not landed?)")

for _, col in ipairs({"clip_id", "channel_index", "enabled", "gain_db"}) do
    assert(cols[col], "clip_channel_override." .. col .. " missing")
    assert(cols[col].notnull == 1, "clip_channel_override." .. col .. " must be NOT NULL")
end
assert(cols["enabled"].dflt == nil, "clip_channel_override.enabled must have no DEFAULT (rule 2.13)")
assert(cols["gain_db"].dflt == nil, "clip_channel_override.gain_db must have no DEFAULT (rule 2.13)")
assert(cols["clip_id"].pk > 0 and cols["channel_index"].pk > 0,
    "composite PK (clip_id, channel_index) missing")

-- Scaffold: project, nested sequence with a clip, + master for the clip to reference.
assert(db:exec("PRAGMA foreign_keys = ON"))
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-edit', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-a1', 'seq-edit', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('clip-1', 'p1', 'seq-edit', 'trk-a1', 'seq-master', "
    .. "'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

-- Good.
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db) "
    .. "VALUES ('clip-1', 0, 0, -6.0)"),
    "full INSERT into clip_channel_override failed")

-- Bad: missing enabled or gain_db.
assert(not db:exec(
    "INSERT INTO clip_channel_override (clip_id, channel_index, gain_db) "
    .. "VALUES ('clip-1', 1, 0.0)"),
    "INSERT missing enabled was accepted; rule 2.13 violation")
assert(not db:exec(
    "INSERT INTO clip_channel_override (clip_id, channel_index, enabled) "
    .. "VALUES ('clip-1', 2, 1)"),
    "INSERT missing gain_db was accepted; rule 2.13 violation")

-- CASCADE: delete the clip, override row must be gone.
assert(db:exec("DELETE FROM clips WHERE id = 'clip-1'"))
local stmt = db:prepare("SELECT COUNT(*) AS c FROM clip_channel_override WHERE clip_id = 'clip-1'")
assert(stmt:exec())
stmt:next()
local count = stmt:value(0)
stmt:finalize()
assert(count == 0, "clip_channel_override not cascaded on clip delete; ON DELETE CASCADE missing")

print("✅ test_schema_clip_channel_override.lua passed")
