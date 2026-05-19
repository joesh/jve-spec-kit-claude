-- T006 (013): projects.fps_mismatch_policy column per data-model.md.
-- NOT NULL, values restricted to 'resample' or 'passthrough'.
-- Expected to FAIL until T008 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_projects_fps_policy.db"
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

local cols = read_columns("projects")
assert(cols["fps_mismatch_policy"],
    "projects.fps_mismatch_policy missing (T008 must add it)")
assert(cols["fps_mismatch_policy"].notnull == 1,
    "projects.fps_mismatch_policy must be NOT NULL (the project always has a default)")

local function insert_project(id, policy)
    return db:exec(string.format(
        "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
        .. "VALUES ('%s', 'n', '%s', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)",
        id, policy))
end

assert(insert_project("p-res", "resample"), "policy='resample' must be accepted")
assert(insert_project("p-pas", "passthrough"), "policy='passthrough' must be accepted")
for _, bad in ipairs({"resamp", "pass", "RESAMPLE", "", "none"}) do
    assert(not insert_project("p-bad-" .. bad, bad),
        string.format("policy='%s' was accepted; CHECK missing", bad))
end

print("✅ test_schema_projects_fps_policy.lua passed")
