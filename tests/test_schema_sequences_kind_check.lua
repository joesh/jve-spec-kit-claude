-- T001 (013): sequences.kind must accept only 'master' and 'sequence'.
-- Pre-013 kind values ('timeline', 'masterclip', 'compound', 'multicam') must be rejected.
-- This test is expected to FAIL until T008 lands; proves T008 does what data-model.md §sequences says.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_sequences_kind_check.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()

-- Arrange: need a project row so the FK is satisfied.
local PROJECT_ID = "proj-T001"
assert(db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('%s', 'p', 'resample', 0, 0)", PROJECT_ID)),
    "projects INSERT failed — projects.fps_mismatch_policy column missing (T008 not landed?)")

local function kind_insert(kind)
    -- 018 INV-7: masters must have NULL audio_sample_rate.
    local asr = kind == "master" and "NULL" or "48000"
    local sql = string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('s-%s', '%s', 'n', '%s', 24, 1, %s, 1920, 1080, 0, 0)",
        kind, PROJECT_ID, kind, asr)
    return db:exec(sql)
end

-- Good: accepted values.
assert(kind_insert("master"), "kind='master' must be accepted")
assert(kind_insert("sequence"), "kind='sequence' must be accepted")

-- Bad: every pre-013 kind must be rejected.
for _, bad in ipairs({"timeline", "masterclip", "compound", "multicam", "garbage", ""}) do
    local ok = kind_insert(bad)
    assert(not ok, string.format(
        "kind='%s' was accepted; CHECK constraint from T008 not enforced", bad))
end

print("✅ test_schema_sequences_kind_check.lua passed")
