#!/usr/bin/env luajit

-- Regression: mark-family commands (SetMark/SetMarkIn/SetMarkOut/ClearMark/
-- ClearMarkIn/ClearMarkOut/ClearMarks) mutate sequence-level mark state, not
-- clips. They must NOT log
--     "command <Name> produced no __timeline_mutations"
-- during execute, undo, or redo. That message is for commands that failed to
-- record clip mutations; mark commands legitimately have none and belong in
-- NON_CLIP_COMMAND_TYPES alongside SetSequenceMetadata.

require('test_env')

-- Wrap logger.for_area("commands").error BEFORE loading command_manager so
-- its captured closure is the wrapped one.
local captured_errors = {}
local logger = require('core.logger')
local original_for_area = logger.for_area
logger.for_area = function(name)
    local api = original_for_area(name)
    if name == "commands" then
        local original_error = api.error
        api.error = function(fmt, ...)
            local ok, msg = pcall(string.format, fmt, ...)
            if not ok then
                msg = tostring(fmt)
            end
            if msg:find("produced no __timeline_mutations", 1, true) then
                captured_errors[#captured_errors + 1] = msg
            end
            return original_error(fmt, ...)
        end
    end
    return api
end

-- test_harness preloads command_manager before this script; drop the cached
-- copy so the re-require picks up our wrapped logger.
package.loaded['core.command_manager'] = nil

local database = require('core.database')
local Sequence = require('models.sequence')
local command_manager = require('core.command_manager')

print("=== test_mark_commands_no_mutation_spam.lua ===")

local db_path = "/tmp/jve/test_mark_commands_no_mutation_spam.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test', 'resample', %d, %d);
]], now, now))

local seq = Sequence.create("Test Timeline", "project",
    { fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    { kind = "nested",id = "seq_1", audio_rate = 48000})
assert(seq:save(), "setup: failed to save sequence")

command_manager.init('seq_1', 'project')

local P, S = "project", "seq_1"

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or P
    command_manager.begin_command_event("script")
    local r = command_manager.execute(name, params)
    command_manager.end_command_event()
    return r
end

local function undo()
    command_manager.begin_command_event("script")
    local r = command_manager.undo()
    command_manager.end_command_event()
    return r
end

local function redo()
    command_manager.begin_command_event("script")
    local r = command_manager.redo()
    command_manager.end_command_event()
    return r
end

-- Exercise every mark command's execute + undo + redo path.
local cases = {
    {name = "SetMarkIn",    params = {sequence_id = S, frame = 48}},
    {name = "SetMarkOut",   params = {sequence_id = S, frame = 96}},
    {name = "ClearMarkIn",  params = {sequence_id = S}},
    {name = "ClearMarkOut", params = {sequence_id = S}},
    {name = "SetMarkIn",    params = {sequence_id = S, frame = 24}},
    {name = "SetMarkOut",   params = {sequence_id = S, frame = 72}},
    {name = "ClearMarks",   params = {sequence_id = S}},
}

for _, c in ipairs(cases) do
    local r = execute_cmd(c.name, c.params)
    assert(r.success, c.name .. " execute failed: " .. tostring(r.error_message))
    r = undo()
    assert(r.success, c.name .. " undo failed: " .. tostring(r.error_message))
    r = redo()
    assert(r.success, c.name .. " redo failed: " .. tostring(r.error_message))
end

-- Also exercise the positional aliases SetMark/ClearMark (these are what
-- the TSO traceback reported).
-- SetMark requires a playhead when frame is omitted; pass frame explicitly.
local r = execute_cmd("SetMark", {sequence_id = S, _positional = {"in"}, frame = 12})
assert(r.success, "SetMark in execute failed: " .. tostring(r.error_message))
r = undo()
assert(r.success, "SetMark in undo failed: " .. tostring(r.error_message))
r = redo()
assert(r.success, "SetMark in redo failed: " .. tostring(r.error_message))

r = execute_cmd("ClearMark", {sequence_id = S, _positional = {"in"}})
assert(r.success, "ClearMark in execute failed: " .. tostring(r.error_message))
r = undo()
assert(r.success, "ClearMark in undo failed: " .. tostring(r.error_message))
r = redo()
assert(r.success, "ClearMark in redo failed: " .. tostring(r.error_message))

-- Assertion: no mutation-spam errors should have been logged.
logger.for_area = original_for_area

if #captured_errors > 0 then
    print(string.format("FAIL: %d '__timeline_mutations' errors logged:", #captured_errors))
    for i, msg in ipairs(captured_errors) do
        print(string.format("  [%d] %s", i, msg))
    end
    os.exit(1)
end

print("✅ test_mark_commands_no_mutation_spam.lua passed")
