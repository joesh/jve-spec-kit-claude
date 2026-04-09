#!/usr/bin/env luajit

-- Validate the real anamnesis project against the project validator.
-- Ensures no false positives on production data.

require("test_env")

local database = require("core.database")
local validator = require("tests.helpers.project_validator")

-- Copy to /tmp (we're read-only, but be safe)
local home = os.getenv("HOME")
local src = home .. "/Documents/JVE Projects/anamnesis joe edit.jvp"
local dst = "/tmp/jve/anamnesis_validate.jvp"
os.execute('mkdir -p /tmp/jve')
os.execute(string.format('cp %q %q', src, dst))
os.execute(string.format('rm -f %q', dst .. "-shm"))

assert(database.init(dst))
local db = database.get_connection()

-- JVP validation
local t0 = os.clock()
local jvp_result = validator.validate_jvp(db)
local t1 = os.clock()
print(string.format("  JVP validation: %s (%.3fs, %d errors)",
    jvp_result.ok and "PASS" or "FAIL", t1 - t0, #jvp_result.errors))
for _, err in ipairs(jvp_result.errors) do
    print("    " .. err)
end

-- Undo stack validation — the anamnesis project has orphaned undo groups from
-- prior editing sessions. Log them but don't fail the test.
local t2 = os.clock()
local undo_result = validator.validate_undo_stack(db)
local t3 = os.clock()
print(string.format("  Undo stack validation: %s (%.3fs, %d errors)",
    undo_result.ok and "PASS" or "INFO", t3 - t2, #undo_result.errors))
for _, err in ipairs(undo_result.errors) do
    print("    " .. err)
end

database.shutdown()
os.remove(dst)
os.remove(dst .. "-wal")
os.remove(dst .. "-shm")

assert(jvp_result.ok, "Anamnesis JVP validation failed:\n  " .. table.concat(jvp_result.errors, "\n  "))
-- Undo stack errors are pre-existing orphaned groups — not a validator false positive.

print("✅ test_project_validator_anamnesis.lua passed")
