#!/usr/bin/env luajit
-- Regression test: SetSequenceMetadata's whitelist column names MUST all
-- exist as actual columns in the `sequences` table. Drift here silently
-- breaks every Inspector sequence-field write (Failed to prepare select).
-- Until a single source of truth is consolidated, this test catches drift.
--
-- Bug reproduced (TSO 2026-04-20 10:48:07 onward): whitelist had
--   timecode_start_frame (DDL is start_timecode_frame)
--   playhead_value       (DDL is playhead_frame)
--   mark_in_value        (DDL is mark_in_frame)
--   mark_out_value       (DDL is mark_out_frame)
--   viewport_start_value, viewport_duration_frames_value (don't exist at all)
-- Every Inspector commit silently failed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== SetSequenceMetadata whitelist vs DDL columns ===\n")

-- Create a minimal DB with the real schema.
local db_path = "/tmp/jve/test_set_sequence_metadata_columns.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Read the actual sequences table columns back out of the DB.
local pragma = db:prepare("PRAGMA table_info(sequences)")
assert(pragma, "PRAGMA table_info(sequences) failed to prepare")
pragma:exec()
local actual_columns = {}
while pragma:next() do
    local name = pragma:value(1)  -- PRAGMA table_info: (cid, name, type, notnull, dflt_value, pk)
    actual_columns[name] = true
end
pragma:finalize()

-- Extract the whitelist from set_sequence_metadata.lua by executing the
-- registration pattern. The command registry drops the column table inside
-- register(). Easiest access: read the source file and parse.
local mod_path = test_env.resolve_repo_path("src/lua/core/commands/set_sequence_metadata.lua")
local fh = assert(io.open(mod_path, "r"),
    "cannot open " .. mod_path .. " to scan whitelist")
local source = fh:read("*a"); fh:close()
-- Match the `local sequence_metadata_columns = { ... }` block, line by line.
local whitelist = {}
local in_block = false
for line in source:gmatch("[^\n]+") do
    if line:match("local%s+sequence_metadata_columns%s*=%s*{") then
        in_block = true
    elseif in_block then
        local key = line:match("^%s*([%w_]+)%s*=%s*{")
        if key then whitelist[key] = true end
        if line:match("^%s*}") then in_block = false; break end
    end
end

local pass, fail = 0, 0
local function check(label, ok, msg) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. (msg and (" — " .. msg) or "")) end end

-- Basic sanity: the whitelist isn't empty.
local count = 0; for _ in pairs(whitelist) do count = count + 1 end
check("whitelist parsed non-empty", count > 0, "count=" .. count)

-- Every whitelisted column must exist in the DDL.
for key in pairs(whitelist) do
    check("whitelist column '" .. key .. "' exists in sequences table",
        actual_columns[key] == true,
        actual_columns[key] and "" or ("no such column in DDL"))
end

-- Spot-check: a few columns Inspector depends on must be in the whitelist.
local required_for_inspector = {
    "name",
    "start_timecode_frame",
    "playhead_frame",
    "mark_in_frame",
    "mark_out_frame",
}
for _, col in ipairs(required_for_inspector) do
    check("Inspector-required column '" .. col .. "' is whitelisted",
        whitelist[col] == true,
        whitelist[col] and "" or "missing from whitelist")
    check("Inspector-required column '" .. col .. "' exists in DDL",
        actual_columns[col] == true,
        actual_columns[col] and "" or "missing from DDL")
end

-- Functional end-to-end: SetSequenceMetadata actually persists a write.
-- Insert a minimal sequence row + run the command + read it back.
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Test', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator,
                           audio_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'OldName', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

command_manager.init_project_only("proj")

local Command = require("command")
local cmd = Command.create("SetSequenceMetadata", "proj")
cmd:set_parameters({
    ["sequence_id"] = "seq",
    ["field"]       = "name",
    ["value"]       = "NewName",
    project_id      = "proj",
})
local result = command_manager.execute_interactive(cmd)
check("SetSequenceMetadata(name) executes",
    type(result) == "table" and result.success == true,
    result and (result.error_message or "no error") or "nil result")

local check_stmt = db:prepare("SELECT name FROM sequences WHERE id = ?")
check_stmt:bind_value(1, "seq")
check_stmt:exec()
assert(check_stmt:next(), "could not read back sequence row")
local new_name = check_stmt:value(0)
check_stmt:finalize()
check("name actually updated in DDL", new_name == "NewName",
    "got " .. tostring(new_name))

-- And a TIMECODE column that was previously broken.
local cmd2 = Command.create("SetSequenceMetadata", "proj")
cmd2:set_parameters({
    ["sequence_id"] = "seq",
    ["field"]       = "start_timecode_frame",
    ["value"]       = 3600,
    project_id      = "proj",
})
local res2 = command_manager.execute_interactive(cmd2)
check("SetSequenceMetadata(start_timecode_frame) executes",
    type(res2) == "table" and res2.success == true,
    res2 and (res2.error_message or "no error") or "nil result")

local check2 = db:prepare("SELECT start_timecode_frame FROM sequences WHERE id = ?")
check2:bind_value(1, "seq"); check2:exec(); check2:next()
local stv = check2:value(0); check2:finalize()
check("start_timecode_frame persisted", stv == 3600, "got " .. tostring(stv))

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_set_sequence_metadata_columns.lua passed")
