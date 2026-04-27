-- Helper: create a fresh .jvp with minimal project + sequence.
-- Called via --test mode to set up the DB before the real startup test.
-- The actual startup test is run by test_editor_startup.sh which launches
-- the editor normally (not --test) with JVE_QUIT_AFTER_INIT=1.

print("\n=== Editor Startup: Create Test DB ===")

local database = require("core.database")
local import_schema = require("import_schema")
local uuid = require("uuid")

local test_db = os.getenv("TEST_DB_PATH")
assert(test_db and test_db ~= "", "TEST_DB_PATH env var required")

os.remove(test_db)
os.remove(test_db .. "-wal")
os.remove(test_db .. "-shm")

assert(database.set_path(test_db), "failed to create test db")
local db = database.get_connection()
assert(db, "no db connection")
assert(db:exec(import_schema), "failed to apply schema")

local project_id = uuid.generate()
local seq_id = uuid.generate()
local now = os.time()

assert(db:exec(string.format([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('%s', 'Startup Test', %d, %d);
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES('%s', '%s', 'Test Timeline', 'timeline', 25, 1, 48000, 1920, 1080,
        0, 0, 250, %d, %d);
]], project_id, now, now, seq_id, project_id, now, now)), "failed to seed project")

database.shutdown()
print("  Created test DB: " .. test_db)
print("✅ test_editor_startup.lua passed")
