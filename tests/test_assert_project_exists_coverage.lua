-- Contract test (014, T005): Layer 1 assert_project_exists coverage.
--
-- Spec ref: contracts/persist_now_validation.md, FR-005.
--
-- Domain: every public database export that writes and takes a project_id
-- argument MUST validate that the project_id matches the live DB's sole
-- project. The validation is the assertion at database.lua:1493
-- (assert_project_exists). When a caller passes a stale or wrong id, the
-- call MUST hard-assert with the canonical message format:
--   assert_project_exists: project_id 'X' != sole project 'Y' in '...'.
--   Stale project_id after project switch?
--
-- Today's coverage (verified Phase 0):
--   - get_project_settings → calls assert_project_exists directly
--   - set_project_setting → calls get_project_settings (transitive)
--   - other writes (save_bins, add_to_bin, remove_from_bin, set_bin,
--     assign_master_clip(s)_to_bin, save_master_clip_bin_map) — coverage
--     unverified; this test enumerates them and forces a hard-assert.
--
-- Red today for any write that bypasses Layer 1. Turns green after T020
-- audits and adds direct calls where missing.
--
-- NSF: every fixture call validates I/O; every test sub-case asserts the
-- fail mode and the error message format independently.

require("test_env")

local database = require("core.database")
local Project = require("models.project")

print("=== test_assert_project_exists_coverage ===")

local TEST_DIR = "/tmp/jve/test_014_t005"
local BOGUS_ID = "00000000-stale-stale-stale-000000000000"

-- ----------------------------------------------------------------------
-- Helpers (NSF: validate I/O of every fixture call).
-- ----------------------------------------------------------------------

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

local function reset_test_dir()
    shell("mkdir -p " .. TEST_DIR)
    shell("rm -f " .. TEST_DIR .. "/p.jvp*")
end

local function attach_db(path)
    assert(type(path) == "string" and path ~= "",
        "attach_db: path required, got " .. tostring(path))
    local ok = database.set_path(path)
    assert(ok, "attach_db: set_path returned false for " .. path)
    assert(database.has_connection(),
        "attach_db: postcondition — has_connection() must be true after set_path")
end

local function create_real_project(label, path)
    attach_db(path)
    local project = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(project, "create_real_project: Project.create returned nil")
    assert(project:save(), "create_real_project: project:save() returned false")
    assert(type(project.id) == "string" and project.id ~= "",
        "create_real_project: postcondition — project.id non-empty string")
    return project.id
end

local function expect_stale_id_assert(label, fn)
    local ok, err = pcall(fn)
    assert(not ok, string.format(
        "COVERAGE GAP: '%s' did not assert when called with stale project_id.\n" ..
        "  Layer 1 (assert_project_exists) MUST cover every write taking a\n" ..
        "  project_id argument (FR-005). Add a direct call at the top of\n" ..
        "  the function or via a covered helper.", label))
    local err_str = tostring(err)
    assert(err_str:find("assert_project_exists", 1, true), string.format(
        "COVERAGE FORMAT: '%s' asserted but not via assert_project_exists.\n" ..
        "  Got: %s\n" ..
        "  The canonical Layer 1 message format must be reachable so\n" ..
        "  failures point operators at the staleness root cause.", label, err_str))
    assert(err_str:find("Stale project_id after project switch", 1, true), string.format(
        "COVERAGE FORMAT: '%s' assertion lacks the canonical staleness\n" ..
        "  diagnostic. Got: %s", label, err_str))
end

-- ----------------------------------------------------------------------
-- Setup: one real project, single row in the live DB.
-- ----------------------------------------------------------------------

reset_test_dir()
local real_id = create_real_project("the_real_project", TEST_DIR .. "/p.jvp")
assert(real_id ~= BOGUS_ID, "setup precondition: real id and bogus id must differ")
print("  setup: real project id = " .. real_id)
print("  setup: bogus project id = " .. BOGUS_ID)

-- ----------------------------------------------------------------------
-- Coverage table — every public write export taking project_id.
-- Each entry: {label, function-call closure}. The closure passes the
-- bogus id as the project_id and minimal-but-valid other args.
--
-- If a call fails to assert via assert_project_exists, the test reports
-- the specific function with a coverage gap.
-- ----------------------------------------------------------------------

local writes = {
    { "set_project_setting",
      function() database.set_project_setting(BOGUS_ID, "k", "v") end },
    { "save_bins",
      function() database.save_bins(BOGUS_ID, {}, {}) end },
    { "save_master_clip_bin_map",
      function() database.save_master_clip_bin_map(BOGUS_ID, {}) end },
    { "add_to_bin",
      function() database.add_to_bin(BOGUS_ID, {}, "bogus-bin-id", "clip") end },
    { "remove_from_bin",
      function() database.remove_from_bin(BOGUS_ID, {}, "bogus-bin-id", "clip") end },
    { "set_bin",
      function() database.set_bin(BOGUS_ID, {}, "bogus-bin-id", "clip") end },
    { "assign_master_clips_to_bin",
      function() database.assign_master_clips_to_bin(BOGUS_ID, {}, "bogus-bin-id") end },
    { "assign_master_clip_to_bin",
      function() database.assign_master_clip_to_bin(BOGUS_ID, "bogus-clip-id", "bogus-bin-id") end },
}

-- ----------------------------------------------------------------------
-- Run every coverage check.
-- ----------------------------------------------------------------------

for _, entry in ipairs(writes) do
    local label, fn = entry[1], entry[2]
    expect_stale_id_assert(label, fn)
    print(string.format("  ✓ %s asserts via assert_project_exists with stale id", label))
end

-- ----------------------------------------------------------------------
-- Cleanup.
-- ----------------------------------------------------------------------

shell("rm -f " .. TEST_DIR .. "/p.jvp*")

print("✅ test_assert_project_exists_coverage passed")
