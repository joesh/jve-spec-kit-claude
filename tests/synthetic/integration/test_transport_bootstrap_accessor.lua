-- Integration: transport.is_bootstrapped() / bound_project_id() accessors.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_transport_bootstrap_accessor.lua
--
-- Honest conversion: the original faked qt_constants so transport.init
-- could construct PlaybackEngines without Qt. This runs inside JVEEditor
-- (--test) with the REAL bindings, so transport.init builds REAL engines
-- bound to a REAL project — exactly the production path the accessors
-- serve (command_manager + sequence_monitor read these instead of poking
-- the private _project_id field).
--
-- DOMAIN RULES PINNED (017 contracts/transport.md §is_bootstrapped/bound_project_id):
--   BA-1  Both accessors are functions.
--   BA-2  Pre-init: is_bootstrapped() == false, bound_project_id() == nil.
--   BA-3  Post-init: is_bootstrapped() == true, bound_project_id() returns
--         the project_id transport was initialized for.
--   BA-4  Post-shutdown: is_bootstrapped() flips back to false and
--         bound_project_id() clears to nil.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_transport_bootstrap_accessor.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_transport_bootstrap_accessor.lua (integration) ===")

require("test_env")
local database  = require("core.database")
local transport = require("core.playback.transport")

-- ── BA-1  accessors present ──────────────────────────────────────────────
print("\n-- (BA-1) accessors are functions --")
do
    assert(type(transport.is_bootstrapped) == "function",
        "transport.is_bootstrapped must be a function")
    assert(type(transport.bound_project_id) == "function",
        "transport.bound_project_id must be a function")
    print("  PASS: is_bootstrapped / bound_project_id are functions")
end

-- Guard against a sibling test leaving transport up in-process.
if transport.is_bootstrapped() then transport.shutdown() end

-- ── BA-2  pre-init state ─────────────────────────────────────────────────
print("\n-- (BA-2) pre-init: not bootstrapped, no bound project --")
do
    assert(transport.is_bootstrapped() == false,
        "is_bootstrapped() pre-init must be false")
    assert(transport.bound_project_id() == nil,
        "bound_project_id() pre-init must be nil")
    print("  PASS: pre-init is_bootstrapped=false, bound_project_id=nil")
end

-- ── DB bootstrap ─────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_transport_bootstrap_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
      VALUES ('proj_x', 'P', 'resample', %d, %d);
]], now, now)))

-- ── BA-3  post-init state ────────────────────────────────────────────────
print("\n-- (BA-3) post-init: bootstrapped, bound to initializing project --")
do
    transport.init("proj_x")
    assert(transport.is_bootstrapped() == true,
        "is_bootstrapped() post-init must be true")
    assert(transport.bound_project_id() == "proj_x", string.format(
        "bound_project_id() post-init must return the initializing project_id; got %s",
        tostring(transport.bound_project_id())))
    print("  PASS: post-init is_bootstrapped=true, bound_project_id='proj_x'")
end

-- ── BA-4  post-shutdown state ────────────────────────────────────────────
print("\n-- (BA-4) post-shutdown: predicate flips, bound id clears --")
do
    transport.shutdown()
    assert(transport.is_bootstrapped() == false,
        "is_bootstrapped() post-shutdown must be false")
    assert(transport.bound_project_id() == nil,
        "bound_project_id() post-shutdown must be nil")
    print("  PASS: post-shutdown is_bootstrapped=false, bound_project_id=nil")
end

database.shutdown()
print("\nPASS test_transport_bootstrap_accessor.lua")
os.exit(0)
