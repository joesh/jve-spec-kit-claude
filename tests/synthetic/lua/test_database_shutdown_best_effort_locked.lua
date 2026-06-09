local database = require("core.database")
local sqlite3 = require("core.sqlite3")

local function remove_best_effort(path)
    if not path or path == "" then
        return
    end
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    os.execute(string.format("rm -rf %q", path .. ".events"))
end

local db_path = string.format("/tmp/jve/shutdown_best_effort_%d_%d.jvp", os.time(), math.random(100000))
remove_best_effort(db_path)

assert(database.init(db_path), "database.init failed")

-- Hold a lock from a second connection so PRAGMA journal_mode = DELETE cannot acquire it.
local other_db, open_err = sqlite3.open(db_path)
assert(other_db, "Failed to open secondary connection: " .. tostring(open_err))

local ok, lock_err = other_db:exec("BEGIN IMMEDIATE;")
assert(ok ~= false, "Failed to acquire lock: " .. tostring(lock_err))

-- Best-effort shutdown should not fail just because the DB is locked.
local shutdown_ok, shutdown_err = database.shutdown({ best_effort = true })
assert(shutdown_ok == true, "Expected best-effort shutdown to succeed, got: " .. tostring(shutdown_err))

-- Cleanup
other_db:exec("ROLLBACK;")
other_db:close()
remove_best_effort(db_path)

print("✅ database.shutdown({best_effort=true}) succeeds even when locked")

