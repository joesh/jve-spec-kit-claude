-- Regression: _convert_drp_to_jvp must produce a self-contained .jvp.
--
-- "Self-contained" means the main .jvp file alone — without its -wal /
-- -shm sidecars — carries every write the convert performed (project
-- settings, including last_open_sequence_id / open_sequence_ids;
-- provenance row; media; sequences; clips).
--
-- Why this matters: cross-process consumers see only the .jvp.
-- The smoke build (tests/smoke/runner/build_template.py) does
-- shutil.move(scratch.jvp, template.jvp) — moving the main file but
-- not the sidecars. Backup / sync tools commonly do the same. If the
-- convert leaves recent writes in the WAL, those consumers silently
-- get a .jvp missing the tab state — symptom: editor opens on an
-- arbitrary sequence (or none) instead of the one the DRP marked
-- active.
--
-- Domain assertion: after convert returns, the WAL must be checkpointed
-- (truncated to zero bytes by PRAGMA wal_checkpoint(TRUNCATE), or
-- equivalent). Tested by file-system observation, not internal call
-- counts.

require("test_env")

local open_project = require("core.commands.open_project")
local test_env = require("test_env")

local drp_fixture = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")
local JVP_PATH = "/tmp/jve/test_convert_self_contained.jvp"

for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    os.remove(JVP_PATH .. suffix)
end

print("=== test_convert_self_contained.lua ===")

local ok, err = open_project._convert_drp_to_jvp(drp_fixture, JVP_PATH)
assert(ok, "convert failed: " .. tostring(err))

local function file_size_bytes(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

local wal_size = file_size_bytes(JVP_PATH .. "-wal")
assert(wal_size == 0, string.format(
    "_convert_drp_to_jvp must checkpoint the WAL — the resulting .jvp must be "
    .. "self-contained for cross-process consumers (smoke runner moves only "
    .. "the .jvp; backup tools may too). WAL still has %d bytes after convert, "
    .. "meaning recent writes (likely project settings, tab state, provenance) "
    .. "have not been flushed to the main .jvp file. Path: %s-wal",
    wal_size, JVP_PATH))

print(string.format("  ✓ WAL is truncated (%d bytes) — .jvp is self-contained", wal_size))

-- Also do a second-order check: the .jvp main file (which is now the only
-- file with the data) should contain the project's name as plain UTF-8 bytes
-- because the projects.name TEXT column stores strings verbatim. If the
-- WAL had been the only place carrying recent writes, the name (written
-- during create_project_record) might not be in the main file. Catches a
-- subtler form of the bug where the checkpoint runs but somehow doesn't
-- flush.
local function file_contains_bytes(path, needle)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*all")
    f:close()
    return content:find(needle, 1, true) ~= nil
end

-- sample_project.drp's project_name (set in DRP project.xml); the actual
-- value lives in the .jvp's projects.name column post-convert. We don't
-- pin which exact value here — the import-side test pins that — but the
-- main file MUST contain something that distinguishes a populated DB from
-- an empty schema-only one. A reliable witness: SQLite stores the
-- projects table's row data inline once the WAL is checkpointed. Look
-- for "resample" — the fps_mismatch_policy literal create_project_record
-- writes — which the schema's defaults don't otherwise include in the
-- main file outside a populated row.
assert(file_contains_bytes(JVP_PATH, "resample"), string.format(
    ".jvp main file does not contain the projects.fps_mismatch_policy text "
    .. "value 'resample' after convert + checkpoint. Means the projects row "
    .. "write never reached the main file. Path: %s", JVP_PATH))

print("  ✓ projects row text is present in main file (write reached disk)")

print("✅ test_convert_self_contained.lua passed")
