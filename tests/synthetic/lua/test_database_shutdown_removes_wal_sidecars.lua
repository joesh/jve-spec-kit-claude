#!/usr/bin/env luajit

-- Regression: after a clean shutdown, project DB should not leave -wal/-shm
-- sidecar files behind (single-file DB at rest).

require("test_env")

local database = require("core.database")

local TEST_DB = "/tmp/jve/test_database_shutdown_removes_wal_sidecars.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

assert(database.init(TEST_DB))
local conn = database.get_connection()
assert(conn, "expected database connection")

-- Force WAL file creation.
assert(conn:exec("CREATE TABLE IF NOT EXISTS wal_probe(id INTEGER PRIMARY KEY, v INTEGER);"))
assert(conn:exec("INSERT INTO wal_probe(v) VALUES(1);"))

local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- In WAL mode the sidecars are expected to exist at runtime.
assert(exists(TEST_DB .. "-wal") or exists(TEST_DB .. "-shm"), "expected WAL sidecar files during runtime")

local ok, err = database.shutdown()
assert(ok, err or "database.shutdown failed")

assert(not exists(TEST_DB .. "-wal"), "expected -wal removed after shutdown")
assert(not exists(TEST_DB .. "-shm"), "expected -shm removed after shutdown")

os.remove(TEST_DB)
print("✅ database.shutdown removes WAL sidecars")

