#!/usr/bin/env luajit

-- Regression: mark-family commands mutate sequence-level mark state, not
-- clips, and emit their own `marks_changed` signal for UI refresh. They must
-- NOT trigger the recovery-path `timeline_state.reload_clips` that
-- command_manager falls back to when a command produces no
-- __timeline_mutations. That fallback is meant for delegation / test-env
-- cases where clip state may be stale; for mark commands it's pure wasted
-- work and masks the fact that they legitimately have no clip mutations.
--
-- Covers execute, undo, and redo paths (three separate consult sites in
-- command_manager).

require('test_env')

-- test_harness preloads command_manager; drop it so we can install our
-- reload_clips counter on timeline_state before command_manager wires up.
package.loaded['core.command_manager'] = nil
package.loaded['ui.timeline.timeline_state'] = nil

local timeline_state = require('ui.timeline.timeline_state')
local reload_calls = {}
timeline_state.reload_clips = function(seq_id, opts)
    reload_calls[#reload_calls + 1] = { seq_id = seq_id, opts = opts }
end

local database = require('core.database')
local Sequence = require('models.sequence')
local command_manager = require('core.command_manager')

print("=== test_mark_commands_no_reload.lua ===")

local db_path = "/tmp/jve/test_mark_commands_no_reload.db"
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
    {kind = "nested", fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "seq_1", audio_rate = 48000})
assert(seq:save(), "setup: failed to save sequence")

command_manager.init('seq_1', 'project')

local function exec(name, params)
    params = params or {}
    params.project_id = 'project'
    command_manager.begin_command_event("script")
    local r = command_manager.execute(name, params)
    command_manager.end_command_event()
    assert(r.success, name .. " execute failed: " .. tostring(r.error_message))
end

local function undo()
    command_manager.begin_command_event("script")
    local r = command_manager.undo()
    command_manager.end_command_event()
    assert(r.success, "undo failed: " .. tostring(r.error_message))
end

local function redo()
    command_manager.begin_command_event("script")
    local r = command_manager.redo()
    command_manager.end_command_event()
    assert(r.success, "redo failed: " .. tostring(r.error_message))
end

-- Clear counter after setup (Sequence.create etc. don't run through
-- command_manager, but be defensive).
reload_calls = {}

-- Exercise every mark-family command across execute / undo / redo.
local cases = {
    { "SetMarkIn",    { sequence_id = 'seq_1', frame = 48 } },
    { "SetMarkOut",   { sequence_id = 'seq_1', frame = 96 } },
    { "ClearMarkIn",  { sequence_id = 'seq_1' } },
    { "ClearMarkOut", { sequence_id = 'seq_1' } },
    { "SetMarkIn",    { sequence_id = 'seq_1', frame = 24 } },
    { "SetMarkOut",   { sequence_id = 'seq_1', frame = 72 } },
    { "ClearMarks",   { sequence_id = 'seq_1' } },
}

for _, c in ipairs(cases) do
    exec(c[1], c[2])
    undo()
    redo()
end

-- Positional aliases from the original TSO traceback.
exec("SetMark",   { sequence_id = 'seq_1', _positional = { "in" }, frame = 12 })
undo()
redo()
exec("ClearMark", { sequence_id = 'seq_1', _positional = { "in" } })
undo()
redo()

if #reload_calls > 0 then
    print(string.format("FAIL: %d unexpected reload_clips calls from mark commands:",
        #reload_calls))
    for i, c in ipairs(reload_calls) do
        print(string.format("  [%d] seq_id=%s", i, tostring(c.seq_id)))
    end
    os.exit(1)
end

print("✅ test_mark_commands_no_reload.lua passed")
