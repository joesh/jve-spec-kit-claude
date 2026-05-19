-- T002 (013): media_refs table shape per data-model.md.
-- Every state column is NOT NULL with no DEFAULT (rule 2.13). duration_frames > 0 CHECK.
-- Source timebase is NOT carried on the row — dereferences to media.fps_numerator/denominator.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_media_refs.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()

-- Scaffold: project + master sequence + track + media.
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('seq-master', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('trk-v1', 'seq-master', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med1', 'p1', 'x.mov', '/tmp/x.mov', 100, 24, 1, 0, 0)"),
    "media INSERT failed — check minimal media columns")

-- Column shape — fps_numerator/fps_denominator MUST NOT exist on media_refs.
local function read_columns(tbl)
    local stmt = db:prepare(string.format("PRAGMA table_info(%s)", tbl))
    assert(stmt, "PRAGMA prepare failed for " .. tbl)
    assert(stmt:exec(), "PRAGMA exec failed for " .. tbl)
    local cols = {}
    while stmt:next() do
        cols[stmt:value(1)] = {
            notnull = stmt:value(3),
            dflt = stmt:value(4),
        }
    end
    stmt:finalize()
    return cols
end

local cols = read_columns("media_refs")
assert(next(cols) ~= nil, "media_refs table missing (T008 not landed?)")
assert(cols["fps_numerator"] == nil,
    "media_refs.fps_numerator should not exist (dereference via media)")
assert(cols["fps_denominator"] == nil,
    "media_refs.fps_denominator should not exist (dereference via media)")

-- Good: full INSERT succeeds.
local ok_sql = "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr1', 'p1', 'seq-master', 'trk-v1', 'med1', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"
assert(db:exec(ok_sql), "full INSERT into media_refs failed; table or columns missing")

-- Bad: NULL in each required column must be rejected.
local function build_insert_with_null(id, null_col)
    local fields = {
        owner_sequence_id     = "'seq-master'",
        track_id              = "'trk-v1'",
        media_id              = "'med1'",
        source_in_frame       = "0",
        source_out_frame      = "100",
        sequence_start_frame  = "0",
        duration_frames       = "100",
        enabled               = "1",
        volume                = "1.0",
        playhead_frame        = "0",
    }
    fields[null_col] = "NULL"
    return string.format(
        "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
        .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
        .. "enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 0, 0)",
        id,
        fields.owner_sequence_id, fields.track_id, fields.media_id,
        fields.source_in_frame, fields.source_out_frame,
        fields.sequence_start_frame, fields.duration_frames,
        fields.enabled, fields.volume, fields.playhead_frame)
end

local required = {
    "owner_sequence_id", "track_id", "media_id", "source_in_frame", "source_out_frame",
    "sequence_start_frame", "duration_frames", "enabled", "volume", "playhead_frame",
}
for i, col in ipairs(required) do
    local stmt = build_insert_with_null("mr-null-" .. i, col)
    local ok = db:exec(stmt)
    assert(not ok, string.format(
        "INSERT with NULL %s was accepted; column should be NOT NULL per data-model.md", col))
end

-- Bad: duration_frames <= 0 must fail (CHECK from data-model.md).
local dur_zero = "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr-dur0', 'p1', 'seq-master', 'trk-v1', 'med1', 0, 0, 0, 0, 1, 1.0, 0, 0, 0)"
local ok = db:exec(dur_zero)
assert(not ok, "duration_frames=0 accepted; CHECK missing")

print("✅ test_schema_media_refs.lua passed")
