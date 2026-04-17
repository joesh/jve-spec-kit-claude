require('test_env')

local db_module = require("core.database")
local dkjson = require("dkjson")

local test_db_dir = "/tmp/jve/test_bug_capture"
os.execute("rm -rf " .. test_db_dir)
os.execute("mkdir -p " .. test_db_dir)

local db_path = test_db_dir .. "/test.jvp"
db_module.init(db_path)

-- Insert a dummy project so the DB is valid
local conn = db_module.get_connection()
assert(conn, "no DB connection")
conn:exec("INSERT INTO projects (id, name) VALUES ('p1', 'TestProject')")
conn:exec([[INSERT INTO commands (id, sequence_number, command_type, command_args, timestamp, pre_hash, post_hash, sequence_id)
            VALUES ('cmd1', 1, 'TestCmd', '{"foo":"bar"}', 1000, 'aaa', 'bbb', 'seq1')]])
conn:exec([[INSERT INTO commands (id, sequence_number, command_type, command_args, timestamp, pre_hash, post_hash, sequence_id)
            VALUES ('cmd2', 2, 'AnotherCmd', '{"x":1}', 1001, 'bbb', 'ccc', 'seq1')]])

-- -----------------------------------------------------------------------
-- Test 1: capture creates expected files
-- -----------------------------------------------------------------------
print("Test 1: capture creates expected files")
local bug_capture = require("bug_reporter.bug_capture")
local capture_dir = bug_capture.capture({ description = "Test bug" })
assert(capture_dir, "capture returned nil")

local function file_exists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

assert(file_exists(capture_dir .. "/project.jvp"),
    "project.jvp not found in capture dir")
assert(file_exists(capture_dir .. "/recent_commands.json"),
    "recent_commands.json not found")
assert(file_exists(capture_dir .. "/metadata.json"),
    "metadata.json not found")

-- -----------------------------------------------------------------------
-- Test 2: recent_commands.json contains the inserted commands
-- -----------------------------------------------------------------------
print("Test 2: recent_commands.json contains inserted commands")
local f = assert(io.open(capture_dir .. "/recent_commands.json", "r"))
local raw = f:read("*a")
f:close()
local commands = assert(dkjson.decode(raw))
assert(#commands == 2,
    "expected 2 commands, got " .. tostring(#commands))
-- Ordered by sequence_number DESC
assert(commands[1].command_type == "AnotherCmd",
    "first entry should be most recent command")
assert(commands[2].command_type == "TestCmd",
    "second entry should be earliest command")

-- -----------------------------------------------------------------------
-- Test 3: metadata.json contains description
-- -----------------------------------------------------------------------
print("Test 3: metadata.json contains description")
local mf = assert(io.open(capture_dir .. "/metadata.json", "r"))
local meta_raw = mf:read("*a")
mf:close()
local meta = assert(dkjson.decode(meta_raw))
assert(meta.description == "Test bug",
    "description mismatch: " .. tostring(meta.description))
assert(meta.timestamp and meta.timestamp ~= "",
    "timestamp missing")

-- -----------------------------------------------------------------------
-- Test 4: capture without description omits metadata.json
-- -----------------------------------------------------------------------
print("Test 4: capture without description omits metadata.json")
-- Need a small delay so timestamp differs (filenames use seconds)
os.execute("sleep 1")
local dir2 = bug_capture.capture()
assert(dir2, "second capture returned nil")
assert(not file_exists(dir2 .. "/metadata.json"),
    "metadata.json should not exist when no description given")
assert(file_exists(dir2 .. "/project.jvp"),
    "project.jvp should exist in second capture")

-- -----------------------------------------------------------------------
-- Test 5: capture asserts when no database connection
-- -----------------------------------------------------------------------
print("Test 5: capture asserts when no database connection")
db_module.shutdown()
local ok, err = pcall(bug_capture.capture)
assert(not ok, "should have asserted with no DB connection")
assert(err:find("no database connection"),
    "error should mention no database connection, got: " .. tostring(err))

-- cleanup
os.execute("rm -rf " .. test_db_dir)

print("✅ test_bug_capture.lua passed")
