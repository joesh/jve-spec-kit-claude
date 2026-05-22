#!/usr/bin/env luajit
--- sequence_content_changed signal contract.
---
--- After the central-emit refactor (2026-05-21), the contract for this
--- signal lives in ONE place: command_manager.notify_command_event.
--- Any command driven through command_manager.execute that carries a
--- sequence_id MUST cause sequence_content_changed(seq_id) to fire
--- exactly once per command event (execute, undo, redo).
---
--- Replaces the old per-command spy harness (T039a) that drove ~20
--- executors directly via stub command shims. Those tests pinned an
--- implementation detail ("each command emits the signal") that no
--- longer exists — emits now live at the framework boundary, not in
--- individual commands. The pre-2026-05-21 test had to be updated for
--- every new command class; this version doesn't.
---
--- Coverage: execute, undo, and redo via SetMarkIn (the simplest
--- representative UNDOABLE command with a sequence_id). The signal-
--- firing behavior is the same for every undoable command; testing one
--- is sufficient to pin the contract at the command_manager level.
--- Non-undoable commands (SetPlayhead, MovePlayhead) intentionally
--- skip this signal — they don't mutate clip content, so source viewer
--- + inspectors don't need to refresh on them.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

print("=== test_013_signal_sequence_content_changed.lua ===")

local db_path = "/tmp/jve/test_013_signal_sequence_content_changed.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('project', 'Test', 'resample',
        '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

local seq = Sequence.create("Test Timeline", "project",
    { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "sequence", id = "seq_1", audio_sample_rate = 48000 })
assert(seq:save(), "setup: failed to save sequence")

command_manager.init("seq_1", "project")

-- Spy on every sequence_content_changed emit; record the seq_id arg.
local events = {}
local conn_id = Signals.connect("sequence_content_changed", function(seq_id)
    events[#events + 1] = seq_id
end, 100)

local function reset_events()
    for i = #events, 1, -1 do events[i] = nil end
end

local function run_cmd_event(fn)
    command_manager.begin_command_event("script")
    fn()
    command_manager.end_command_event()
end

local pass_count, fail_count = 0, 0
local function check(label, ok, msg)
    if ok then
        pass_count = pass_count + 1
        print("  ✓ " .. label)
    else
        fail_count = fail_count + 1
        print("  ✗ " .. label .. (msg and ("  — " .. msg) or ""))
    end
end

-- ─── execute path ────────────────────────────────────────────────────────

reset_events()
run_cmd_event(function()
    command_manager.execute("SetMarkIn",
        { sequence_id = "seq_1", project_id = "project", frame = 42 })
end)
check("execute fires sequence_content_changed once for the target seq_id",
    #events == 1 and events[1] == "seq_1",
    string.format("got %d emit(s); ids=[%s]", #events, table.concat(events, ",")))

-- ─── undo path ───────────────────────────────────────────────────────────

reset_events()
command_manager.undo()
check("undo fires sequence_content_changed once for the target seq_id",
    #events == 1 and events[1] == "seq_1",
    string.format("got %d emit(s); ids=[%s]", #events, table.concat(events, ",")))

-- ─── redo path ───────────────────────────────────────────────────────────

reset_events()
command_manager.redo()
check("redo fires sequence_content_changed once for the target seq_id",
    #events == 1 and events[1] == "seq_1",
    string.format("got %d emit(s); ids=[%s]", #events, table.concat(events, ",")))

-- ─── seq_id correctness across distinct sequences ────────────────────────
-- A second sequence in the same project; running an execute against it
-- must emit ITS id, not seq_1's.

local seq2 = Sequence.create("Other", "project",
    { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "sequence", id = "seq_2", audio_sample_rate = 48000 })
assert(seq2:save(), "setup: failed to save seq_2")

reset_events()
run_cmd_event(function()
    command_manager.execute("SetMarkIn",
        { sequence_id = "seq_2", project_id = "project", frame = 7 })
end)
check("execute on seq_2 emits seq_2's id (not seq_1)",
    #events == 1 and events[1] == "seq_2",
    string.format("got %d emit(s); ids=[%s]", #events, table.concat(events, ",")))

Signals.disconnect(conn_id)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, "test_013_signal_sequence_content_changed.lua: some assertions failed")
print("✅ test_013_signal_sequence_content_changed.lua passed")
