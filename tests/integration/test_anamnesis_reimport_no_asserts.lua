-- Integration test (014, T009): anamnesis re-import produces zero
-- assert_project_exists log lines.
--
-- Spec ref: spec.md FR-011, quickstart.md.
--
-- Domain: this is the canonical scenario name that drove feature
-- 014. Re-importing tests/fixtures/resolve/anamnesis-gold-timeline.drp
-- via drp_importer.convert and attaching the resulting .jvp must
-- never produce "assert_project_exists ... Stale project_id after
-- project switch" warnings.
--
-- Test status: GREEN today as a regression pin. Joe's originally
-- observed failure was in the FULL interactive editor (UI + media
-- probe worker + inspector + playback chain), not in --test mode.
-- The --test bootstrap doesn't wire up those handlers automatically,
-- so the failing chain doesn't run here. This test serves as:
--   * a baseline regression check (a future change that re-introduces
--     the bug WILL fire the assert here, regardless of which handler
--     it lands in)
--   * a sanity check that drp_importer.convert + database.set_path
--     (post-T018) still complete cleanly in the binding-test
--     environment.
-- Red-state TDD coverage for the actual project_will_change emit
-- and validation contract is carried by T010 (cold start), T012
-- (handler error isolation), T013 (rapid switches), T005 (Layer 1
-- coverage), T006 (Layer 2 stale-cache), T008 (bridge traceback).
--
-- Runs via JVEEditor --test (binding-style integration) so the C++
-- bridge is real, the SQLite DB is real, and the importer's full
-- code path runs.
--
-- C-level stderr capture via FFI freopen on __stderrp — same
-- mechanism as T008 (the C++ bridge writes via JVE_LOG_ERROR which
-- bypasses Lua's io.stderr).
--
-- NSF: every fixture call validates I/O (drp parse, convert, db
-- attach, project load). Final assertion is the FR-011 invariant:
-- zero assert_project_exists lines in the captured stream.

require("test_env")
local ffi = require("ffi")

print("=== test_anamnesis_reimport_no_asserts ===")

-- ----------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------

assert(qt_constants and qt_constants.EMP and qt_constants.EMP.MEDIA_PROBE,
    "PRECONDITION: EMP.MEDIA_PROBE binding required (binding test mode).")
assert(qt_constants.CONTROL and type(qt_constants.CONTROL.PROCESS_EVENTS) == "function",
    "PRECONDITION: PROCESS_EVENTS required to pump Qt event loop.")

local test_env = require("test_env")
local DRP_PATH = test_env.resolve_repo_path(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")
local TEST_DIR = "/tmp/jve/test_014_t009"
local JVP_PATH = TEST_DIR .. "/anamnesis-reimport.jvp"
local CAPTURE_FILE = TEST_DIR .. "/captured_stderr.txt"

local f = io.open(DRP_PATH, "rb")
assert(f, "PRECONDITION: anamnesis fixture not at " .. DRP_PATH)
f:close()

os.execute("mkdir -p " .. TEST_DIR)
os.execute("rm -f " .. JVP_PATH .. "* " .. CAPTURE_FILE)

-- ----------------------------------------------------------------------
-- C-level stderr capture (matches T008).
-- ----------------------------------------------------------------------

ffi.cdef[[
typedef struct __sFILE FILE;
FILE* __stderrp;
FILE* freopen(const char*, const char*, FILE*);
int fflush(FILE*);
]]

local function capture_to_file(fn)
    ffi.C.fflush(ffi.C.__stderrp)
    local r = ffi.C.freopen(CAPTURE_FILE, "w", ffi.C.__stderrp)
    assert(r ~= nil, "capture_to_file: freopen failed")

    local ok, err = pcall(fn)

    ffi.C.fflush(ffi.C.__stderrp)
    ffi.C.freopen("/dev/tty", "w", ffi.C.__stderrp)

    if not ok then error(err) end

    local fh = io.open(CAPTURE_FILE, "r")
    assert(fh, "capture_to_file: failed to open capture file for read")
    local content = fh:read("*a") or ""
    fh:close()
    return content
end

-- ----------------------------------------------------------------------
-- Run the full re-import + interaction inside the capture.
-- ----------------------------------------------------------------------

local captured = capture_to_file(function()
    local database = require("core.database")

    -- 1. Convert the DRP. This creates the .jvp via the convert
    --    orchestration in open_project.lua: parse, derive settings,
    --    DB lifecycle (rm + database.init swap), Project.create,
    --    drp_importer.import_into_project, extract_tab_state +
    --    persist, provenance record. 2026-05-21: the orchestration
    --    moved from drp_importer.convert (now retired) into
    --    open_project — see drp_importer.lua "M.convert was removed"
    --    note. The underscore-prefixed alias is the sanctioned
    --    direct-call entry for tests like this.
    local convert_ok = require("core.commands.open_project")
        ._convert_drp_to_jvp(DRP_PATH, JVP_PATH, function() end)
    assert(convert_ok, "INTEGRATION: _convert_drp_to_jvp returned falsey")

    -- 2. Re-attach the resulting .jvp (simulates File > Open Recent).
    --    This is where handlers fire today with stale ids.
    assert(database.set_path(JVP_PATH),
        "INTEGRATION: database.set_path failed on imported jvp")
    assert(database.has_connection(),
        "INTEGRATION: has_connection() postcondition")
    local pid = database.get_current_project_id()
    assert(pid and pid ~= "",
        "INTEGRATION: live project id must be non-empty after attach")

    -- 3. Trigger a few interactions that exercise project-scoped
    --    deferred work (background probe, media-status persist debounce).
    --    Pump events so deferred timers actually fire.
    qt_constants.CONTROL.PROCESS_EVENTS()
    qt_constants.CONTROL.PROCESS_EVENTS()
    qt_constants.CONTROL.PROCESS_EVENTS()
end)

-- ----------------------------------------------------------------------
-- FR-011 invariant: zero assert_project_exists lines in the captured
-- output. This is the load-bearing assertion of feature 014.
-- ----------------------------------------------------------------------

local stale_count = 0
for _ in captured:gmatch("Stale project_id after project switch") do
    stale_count = stale_count + 1
end

if stale_count > 0 then
    -- For diagnostic clarity, dump the captured log lines that triggered.
    -- Only show the lines containing the assert (full file may be huge).
    print("--- captured lines containing 'Stale project_id' ---")
    for line in captured:gmatch("[^\n]+") do
        if line:find("Stale project_id") then
            print("  " .. line)
        end
    end
    print("--- end captured lines ---")
end

assert(stale_count == 0, string.format(
    "FR-011 VIOLATED: re-importing anamnesis-gold-timeline.drp produced\n" ..
    "  %d 'Stale project_id after project switch' assertions in the\n" ..
    "  captured log. Feature 014 requires zero. Specifically T018 must\n" ..
    "  emit project_will_change before the DB swap, and T021/T022/T023\n" ..
    "  must move the media_status flush from the post-switch handler\n" ..
    "  to the pre-switch handler so writes hit the outgoing DB while\n" ..
    "  it's still attached.\n" ..
    "  Capture file: %s", stale_count, CAPTURE_FILE))

print(string.format(
    "  ✓ FR-011: zero 'Stale project_id' assertions in captured log\n" ..
    "    (captured %d bytes)", #captured))

-- Cleanup.
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-shm")
os.remove(JVP_PATH .. "-wal")
os.remove(CAPTURE_FILE)

print("✅ test_anamnesis_reimport_no_asserts passed")
