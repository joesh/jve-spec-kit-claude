-- T004 (018): hard-error on opening pre-V11 .jvp (Clarification Q2).
-- Constructs a synthetic V10 schema_version row in a fresh DB, then attempts to
-- open via the standard Project.open path. Asserts the open fails loudly with a
-- message naming the old version and instructing re-import.
-- Initially fails because M.SCHEMA_VERSION is still 10. Flips green after T007.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_version_bump_hard_error.db"
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")

-- The CURRENT code's M.SCHEMA_VERSION is what fresh DBs are initialized with.
-- For this test we want to PROVE that V10 is rejected. Strategy: open a DB
-- (which writes whatever SCHEMA_VERSION currently is), then rewrite the
-- schema_version row to 10, then attempt to re-open. The second open must
-- fail with the rejection message.

-- Step 1: fresh open creates a DB at current SCHEMA_VERSION.
assert(database.init(DB_PATH), "initial DB creation failed")
local db = database.get_connection()
assert(db, "no connection after init")

-- Step 2: forcibly downgrade the schema_version row to V10.
assert(db:exec("DELETE FROM schema_version"), "could not clear schema_version")
assert(db:exec("INSERT INTO schema_version (version) VALUES (10)"),
    "could not insert V10 row")

-- Step 3: close the connection so we can re-open via the normal path.
database.shutdown()

-- Step 4: attempt to re-open. MUST raise an error mentioning V10 and re-import.
local ok, err = pcall(function()
    return database.init(DB_PATH)
end)

assert(not ok, "expected re-open of V10 DB to fail; it succeeded")
assert(type(err) == "string", "expected string error message; got " .. type(err))
assert(err:match("V10") or err:match("schema") or err:match("version"),
    "expected error to mention old version; got: " .. err)
assert(err:match("[Rr]e%-import") or err:match("[Rr]eimport"),
    "expected error to instruct re-import; got: " .. err)

-- Cleanup.
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")

print("✅ test_schema_version_bump_hard_error.lua passed")
