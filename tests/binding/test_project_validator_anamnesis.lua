#!/usr/bin/env luajit

-- Validate the project validator against a freshly-imported anamnesis
-- gold-timeline project. The goal is to ensure the validator produces no
-- false positives on real-shaped production data.
--
-- Runs as a binding test because DRP import requires C++ XML-parser
-- bindings that are only available inside JVEEditor --test mode.

require("test_env")
local test_env = require("test_env")

local database = require("core.database")
local drp = require("importers.drp_importer")
local validator = require("tests.helpers.project_validator")

local drp_path = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")
local jvp_path = "/tmp/jve/anamnesis_validate.jvp"

os.execute('mkdir -p /tmp/jve')
os.remove(jvp_path)
os.remove(jvp_path .. "-wal")
os.remove(jvp_path .. "-shm")

local convert_ok, convert_err = drp.convert(drp_path, jvp_path)
assert(convert_ok, "DRP convert failed: " .. tostring(convert_err))

local db = database.get_connection()
assert(db, "no database connection after import")

local t0 = os.clock()
local jvp_result = validator.validate_jvp(db)
local t1 = os.clock()
print(string.format("  JVP validation: %s (%.3fs, %d errors)",
    jvp_result.ok and "PASS" or "FAIL", t1 - t0, #jvp_result.errors))
for _, err in ipairs(jvp_result.errors) do
    print("    " .. err)
end

local t2 = os.clock()
local undo_result = validator.validate_undo_stack(db)
local t3 = os.clock()
print(string.format("  Undo stack validation: %s (%.3fs, %d errors)",
    undo_result.ok and "PASS" or "FAIL", t3 - t2, #undo_result.errors))
for _, err in ipairs(undo_result.errors) do
    print("    " .. err)
end

database.shutdown()
os.remove(jvp_path)
os.remove(jvp_path .. "-wal")
os.remove(jvp_path .. "-shm")

assert(jvp_result.ok, "Anamnesis JVP validation failed:\n  "
    .. table.concat(jvp_result.errors, "\n  "))
assert(undo_result.ok, "Anamnesis undo-stack validation failed:\n  "
    .. table.concat(undo_result.errors, "\n  "))

print("✅ test_project_validator_anamnesis.lua passed")
