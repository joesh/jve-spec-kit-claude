-- Integration: first project open defaults the transport target to "record".
--
-- REPLACES (from tests/synthetic/lua/):
--   test_first_open_project_defaults_to_record_side.lua
--
-- Honest conversion: the original faked qt_constants wholesale. This runs
-- inside JVEEditor (--test) with the REAL bindings and a real DB project;
-- the only "state" the test arranges is the absence of any source-side UI
-- focus or displayed source tab — which is the genuine first-open
-- condition (FR-008a).
--
-- DOMAIN RULE (017 FR-008a):
--   FO-1  On a freshly opened project with no source-side UI state
--         (no source monitor focused, no source tab displayed), the
--         derived transport target is "record".
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_transport_first_open_defaults_to_record.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_transport_first_open_defaults_to_record.lua (integration) ===")

require("test_env")
local database  = require("core.database")
local transport = require("core.playback.transport")

local DB = "/tmp/jve/test_transport_first_open_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
      VALUES ('p', 'P', 'resample', %d, %d);
]], now, now)))

-- Guard against a sibling test leaving transport bootstrapped in-process.
if transport.is_bootstrapped() then transport.shutdown() end

print("\n-- (FO-1) fresh open → target 'record' --")
transport.init("p")
assert(transport.get_target() == "record", string.format(
    "FR-008a: a freshly opened project with no source-side UI state must "
    .. "derive the target to 'record'; got '%s'", tostring(transport.get_target())))
print("  PASS: first open defaults transport target to 'record'")

transport.shutdown()
database.shutdown()
print("\nPASS test_transport_first_open_defaults_to_record.lua")
os.exit(0)
