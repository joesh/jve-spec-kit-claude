#!/usr/bin/env luajit

-- Domain behavior: opening the same .drp twice must yield the SAME project
-- identity. A Resolve project carries its own stable key (the <SM_Project>
-- DbId on project.xml); JVE adopts it as the .jvp project_id so re-opening
-- the same export reuses one project — tab state, settings, and history
-- provenance persist across re-opens instead of resetting under a fresh
-- random id every time.
--
-- Needs the qt_xml_parse C++ binding + DB lifecycle, so it runs under
-- `jve --test` (mirrors test_drp_converter_bins.lua).

require("test_env")
local test_env   = require("test_env")
local database   = require("core.database")
local open_proj  = require("core.commands.open_project")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_single_clip.drp")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. label) end
end

-- Ground truth: the Resolve project key, read straight from the archive's
-- project.xml — independent of the importer under test (derive the expected
-- value from the fixture, never by tracing the code).
local function read_sm_project_db_id(drp_path)
    local p = assert(io.popen(string.format(
        "/usr/bin/unzip -p %q project.xml", drp_path)))
    local xml = p:read("*a"); p:close()
    local db_id = xml:match('SM_Project[^>]*DbId="([0-9a-fA-F%-]+)"')
    assert(db_id, "fixture project.xml has no <SM_Project DbId>")
    return db_id
end
local expected_id = read_sm_project_db_id(FIXTURE)
print("  Resolve project key (ground truth): " .. expected_id)

local function convert_and_get_project_id(jvp_path)
    os.remove(jvp_path); os.remove(jvp_path .. "-wal"); os.remove(jvp_path .. "-shm")
    local ok, err = open_proj._convert_drp_to_jvp(
        FIXTURE, jvp_path, nil, { audio_sample_rate = 48000 })
    assert(ok, "convert failed: " .. tostring(err))
    local db = assert(database.get_connection(), "no db after convert")
    local stmt = assert(db:prepare("SELECT id FROM projects LIMIT 1"))
    assert(stmt:exec())
    local id = stmt:next() and stmt:value(0) or nil
    stmt:finalize()
    return id
end

local A = "/tmp/jve/test_drp_stable_project_id_A.jvp"
local B = "/tmp/jve/test_drp_stable_project_id_B.jvp"
local id_a = convert_and_get_project_id(A)
local id_b = convert_and_get_project_id(B)
print(string.format("  open #1 project_id: %s", tostring(id_a)))
print(string.format("  open #2 project_id: %s", tostring(id_b)))

check("project id equals the Resolve project key (SM_Project DbId)",
    id_a == expected_id)
check("re-opening the same .drp yields the same project id",
    id_a ~= nil and id_a == id_b)

for _, p in ipairs({ A, B }) do
    os.remove(p); os.remove(p .. "-wal"); os.remove(p .. "-shm")
end

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_drp_stable_project_id.lua passed")
