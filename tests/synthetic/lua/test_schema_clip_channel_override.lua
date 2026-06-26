-- T005 (013): clip_channel_override shape per data-model.md — Phase 4a.
-- PK (clip_id, master_track_id). enabled + gain_db are NOT NULL with no DEFAULT (rule 2.13).
-- master_track_id REFERENCES tracks(id) ON DELETE CASCADE — deleting a master AUDIO
-- track cascades the override row out automatically.
-- ON DELETE CASCADE from clips (row evaporates with its clip).

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
            type    = stmt:value(2),
            notnull = stmt:value(3),
            dflt    = stmt:value(4),
            pk      = stmt:value(5),
        }
    end
    stmt:finalize()
    return cols
end

local cols = read_columns("clip_channel_override")
assert(next(cols) ~= nil, "clip_channel_override table missing (T008 not landed?)")

-- New column set: clip_id, master_track_id, enabled, gain_db.
-- owner_sequence_id and channel_index columns must NOT exist.
assert(cols["clip_id"],        "clip_channel_override.clip_id missing")
assert(cols["master_track_id"],"clip_channel_override.master_track_id missing")
assert(cols["enabled"],        "clip_channel_override.enabled missing")
assert(cols["gain_db"],        "clip_channel_override.gain_db missing")
assert(not cols["channel_index"],
    "clip_channel_override.channel_index must NOT exist (Phase 4a renamed to master_track_id)")

for _, col in ipairs({"clip_id", "master_track_id", "enabled", "gain_db"}) do
    assert(cols[col].notnull == 1, "clip_channel_override." .. col .. " must be NOT NULL")
end
assert(cols["enabled"].dflt == nil,
    "clip_channel_override.enabled must have no DEFAULT (rule 2.13)")
assert(cols["gain_db"].dflt == nil,
    "clip_channel_override.gain_db must have no DEFAULT (rule 2.13)")
assert(cols["clip_id"].pk > 0 and cols["master_track_id"].pk > 0,
    "composite PK (clip_id, master_track_id) missing")

-- Scaffold: project, sequences, tracks, clip.
assert(db:exec("PRAGMA foreign_keys = ON"))
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-edit', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
-- Two master AUDIO tracks so we can test cascade on one while the other survives.
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-edit-a1', 'seq-edit', 'A1', 'AUDIO', 1), "
    .. "       ('trk-master-a1', 'seq-master', 'A1', 'AUDIO', 1), "
    .. "       ('trk-master-a2', 'seq-master', 'A2', 'AUDIO', 2)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('clip-1', 'p1', 'seq-edit', 'trk-edit-a1', 'seq-master', "
    .. "'c', 0, 100, 0, 100, 0, 0, 'passthrough', 1, 1.0, 0, 0, 0)"))

-- Good: INSERT with both master AUDIO tracks referenced.
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db) "
    .. "VALUES ('clip-1', 'trk-master-a1', 0, -6.0)"),
    "full INSERT into clip_channel_override (a1) failed")
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db) "
    .. "VALUES ('clip-1', 'trk-master-a2', 1, -3.0)"),
    "full INSERT into clip_channel_override (a2) failed")

-- Bad: missing enabled or gain_db.
assert(not db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, gain_db) "
    .. "VALUES ('clip-1', 'trk-master-a1', 0.0)"),
    "INSERT missing enabled was accepted; rule 2.13 violation")
assert(not db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, enabled) "
    .. "VALUES ('clip-1', 'trk-master-a1', 1)"),
    "INSERT missing gain_db was accepted; rule 2.13 violation")

-- CASCADE from master AUDIO track: delete trk-master-a1, its override row
-- must cascade out; the a2 override must survive.
assert(db:exec("DELETE FROM tracks WHERE id = 'trk-master-a1'"),
    "DELETE of master AUDIO track failed")
local stmt = db:prepare(
    "SELECT COUNT(*) AS c FROM clip_channel_override WHERE master_track_id = 'trk-master-a1'")
assert(stmt:exec()); stmt:next()
local count_a1 = stmt:value(0); stmt:finalize()
assert(count_a1 == 0,
    "clip_channel_override not cascaded on master track delete; ON DELETE CASCADE missing on tracks FK")

local stmt2 = db:prepare(
    "SELECT COUNT(*) AS c FROM clip_channel_override WHERE master_track_id = 'trk-master-a2'")
assert(stmt2:exec()); stmt2:next()
local count_a2 = stmt2:value(0); stmt2:finalize()
assert(count_a2 == 1, "a2 override must survive deletion of a1 track")

-- CASCADE from clips: delete the clip, all remaining override rows must vanish.
assert(db:exec("DELETE FROM clips WHERE id = 'clip-1'"))
local stmt3 = db:prepare("SELECT COUNT(*) AS c FROM clip_channel_override WHERE clip_id = 'clip-1'")
assert(stmt3:exec()); stmt3:next()
local count_clip = stmt3:value(0); stmt3:finalize()
assert(count_clip == 0,
    "clip_channel_override not cascaded on clip delete; ON DELETE CASCADE from clips missing")

print("✅ test_schema_clip_channel_override.lua passed")
