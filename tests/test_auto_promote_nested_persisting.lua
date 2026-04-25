#!/usr/bin/env luajit

-- User contract: when an action opens a modal dialog and the user clicks
-- Apply, the resulting change appears as a single row in the undo history
-- and Cmd+Z rolls it back in one step. The dialog itself is not an
-- undoable action — only the thing it did.
--
-- Relink is the canonical case: Cmd+Shift+R opens the reconnect dialog,
-- the user picks a search directory and clicks Apply, and the project
-- relink becomes one undo entry. Before this fix, the relink landed in
-- the database but never surfaced in the history panel and Cmd+Z skipped
-- it entirely.
--
-- The test uses synthetic parent/child commands instead of the real Qt
-- relink dialog — the contract is about how the command layer routes a
-- persisting command dispatched from inside a non-persisting wrapper,
-- and that routing is independent of whether the wrapper is a real Qt
-- modal or a plain Lua executor.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
require('models.track')  -- luacheck: ignore 411
local command_manager = require('core.command_manager')
local history = require('core.command_history')

print("=== Auto-promote: persisting child of non-persisting parent ===\n")

local db_path = "/tmp/jve/test_auto_promote_nested_persisting.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('project', 'Auto Promote Project', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 'nested', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- ---------------------------------------------------------------------------
-- Test scaffolding: record whatever the history panel's refresh path would
-- receive (command_manager listener events) and the child execution count
-- (so we can distinguish "actually ran" from "recorded without running").
-- ---------------------------------------------------------------------------
local listener_events = {}
local listener = function(evt)
    table.insert(listener_events, {
        event = evt.event,
        type = evt.command and evt.command.type,
        sequence_number = evt.command and evt.command.sequence_number,
    })
end
command_manager.add_listener(listener)

local function count_events(event_name, command_type)
    local n = 0
    for _, evt in ipairs(listener_events) do
        if evt.event == event_name and evt.type == command_type then
            n = n + 1
        end
    end
    return n
end

local function history_contains(command_type)
    local entries = command_manager:list_history_entries()
    for _, entry in ipairs(entries) do
        if entry.command_type == command_type then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Register a persisting child command. It has no opt-out spec flag so it
-- takes the normal recording path when executed top-level.
-- ---------------------------------------------------------------------------
local child_executed = 0
command_manager.register_executor("TestAutoPromoteChild", function()
    child_executed = child_executed + 1
    return true
end, function()
    return true
end, {
    args = { project_id = { required = true } },
})

-- ---------------------------------------------------------------------------
-- Register a non-persisting parent (undoable=false) that dispatches the
-- persisting child from inside its executor. This is the ShowRelinkDialog
-- → RelinkClips shape without the Qt dialog.
-- ---------------------------------------------------------------------------
local parent_executed = 0
command_manager.register_executor("TestAutoPromoteParent", function(command)
    parent_executed = parent_executed + 1
    local child_result = command_manager.execute("TestAutoPromoteChild", {
        project_id = command.project_id,
    })
    assert(child_result.success,
        "parent executor: child dispatch failed: " .. tostring(child_result.error_message))
    return true
end, nil, {
    args = { project_id = { required = true } },
    undoable = false,
})

-- ---------------------------------------------------------------------------
-- Scenario 1: user triggers the parent, which dispatches the persisting
-- child. Expected outcome: the child is the single user-visible action in
-- the undo history; the parent is invisible (it has no undo entry).
-- ---------------------------------------------------------------------------
local result = command_manager.execute("TestAutoPromoteParent", { project_id = 'project' })
assert(result.success, string.format("parent dispatch failed: %s", tostring(result.error_message)))
assert(parent_executed == 1, "parent executor should run exactly once")
assert(child_executed == 1, "child executor should run exactly once")

-- The history panel's refresh path is driven by command_manager listener
-- events. The child must fire one (and the parent must fire zero).
assert(count_events("execute", "TestAutoPromoteChild") == 1,
    "child should fire exactly one top-level execute event")
assert(count_events("execute", "TestAutoPromoteParent") == 0,
    "non-persisting parent should not fire an execute listener event")

-- The global cursor is what list_history_entries walks to find the branch
-- tip. A nested child would leave it at 0.
assert((history.get_global_cursor() or 0) > 0,
    "global cursor should advance past 0 after top-level child save")

-- The history panel renders what list_history_entries returns.
assert(history_contains("TestAutoPromoteChild"),
    "child should appear in list_history_entries (history panel source of truth)")
assert(not history_contains("TestAutoPromoteParent"),
    "non-persisting parent should not appear in list_history_entries")

-- Cmd+Z: the child is the top-level user action, so undo unwinds it.
local undo_result = command_manager.undo()
assert(undo_result.success, string.format("undo failed: %s", tostring(undo_result.error_message)))
assert(count_events("undo", "TestAutoPromoteChild") == 1,
    "child should fire exactly one undo event")
print("  scenario 1: persisting child auto-promoted, visible in history, undoable")

-- ---------------------------------------------------------------------------
-- Scenario 2: edge case. A non-persisting child dispatched from a
-- non-persisting parent must NOT be auto-promoted. Nothing persisting is
-- happening, so there's nothing for the history to show. Promoting a
-- non-persisting command would either crash or create a ghost entry.
-- ---------------------------------------------------------------------------
local events_before = #listener_events
local inner_executed = 0
command_manager.register_executor("TestInnerNonPersisting", function()
    inner_executed = inner_executed + 1
    return true
end, nil, {
    args = { project_id = { required = true } },
    undoable = false,
})

local outer_executed = 0
command_manager.register_executor("TestOuterNonPersisting", function(command)
    outer_executed = outer_executed + 1
    local r = command_manager.execute("TestInnerNonPersisting", { project_id = command.project_id })
    assert(r.success, "inner non-persisting dispatch failed")
    return true
end, nil, {
    args = { project_id = { required = true } },
    undoable = false,
})

local outer_result = command_manager.execute("TestOuterNonPersisting", { project_id = 'project' })
assert(outer_result.success, "outer non-persisting dispatch failed")
assert(outer_executed == 1 and inner_executed == 1, "both non-persisting commands should run")

-- Neither should fire an execute event (both are non-persisting, neither
-- has an undo row).
for i = events_before + 1, #listener_events do
    assert(listener_events[i].event ~= "execute",
        "non-persisting commands nested in non-persisting parents should not fire execute events")
end

assert(not history_contains("TestOuterNonPersisting"),
    "non-persisting outer should not appear in history")
assert(not history_contains("TestInnerNonPersisting"),
    "non-persisting inner should not appear in history")
print("  scenario 2: non-persisting child of non-persisting parent stays hidden")

-- ---------------------------------------------------------------------------
-- Scenario 3: a promoted command's own nested children must NOT promote
-- again. Once the persisting child has been auto-promoted to top-level, it
-- owns a DB transaction and an undo group; any nested command it dispatches
-- from inside its executor must nest cleanly under that transaction, not
-- try to start a new top-level one. Two observable failures if this breaks:
-- SQLite errors with "cannot start a transaction within a transaction", or
-- the grandchild lands on its own orphaned undo row outside the promoted
-- parent's atomic unit.
-- ---------------------------------------------------------------------------
local grandchild_executed = 0
command_manager.register_executor("TestAutoPromoteGrandchild", function()
    grandchild_executed = grandchild_executed + 1
    return true
end, function()
    return true
end, {
    args = { project_id = { required = true } },
})

local promoted_parent_executed = 0
command_manager.register_executor("TestAutoPromoteWithNestedChild", function(command)
    promoted_parent_executed = promoted_parent_executed + 1
    local grandchild_result = command_manager.execute("TestAutoPromoteGrandchild", {
        project_id = command.project_id,
    })
    assert(grandchild_result.success,
        "grandchild dispatch from promoted parent failed: " .. tostring(grandchild_result.error_message))
    return true
end, function()
    return true
end, {
    args = { project_id = { required = true } },
})

-- Wrap the whole chain in a non-persisting dispatcher so the middle command
-- is the one that gets promoted, and the grandchild is dispatched from
-- inside the promoted command's executor (same shape as a real command
-- that does batch work after relink).
command_manager.register_executor("TestAutoPromoteDispatcher", function(command)
    local middle_result = command_manager.execute("TestAutoPromoteWithNestedChild", {
        project_id = command.project_id,
    })
    assert(middle_result.success,
        "middle dispatch failed: " .. tostring(middle_result.error_message))
    return true
end, nil, {
    args = { project_id = { required = true } },
    undoable = false,
})

local scenario3_result = command_manager.execute("TestAutoPromoteDispatcher", { project_id = 'project' })
assert(scenario3_result.success,
    string.format("scenario 3 dispatch failed (likely transaction collision): %s",
        tostring(scenario3_result.error_message)))
assert(promoted_parent_executed == 1, "promoted parent should run exactly once")
assert(grandchild_executed == 1, "grandchild should run exactly once inside promoted parent")

-- The promoted middle command must have landed in the history as a
-- top-level entry.
assert(history_contains("TestAutoPromoteWithNestedChild"),
    "promoted middle command should appear in history")
-- The grandchild is nested under the promoted parent (it's part of the
-- same atomic action), so it should NOT also show up as a top-level row.
-- Otherwise users see two rows in the undo panel for what was one action.
local entries = command_manager:list_history_entries()
local top_level_grandchildren = 0
for _, entry in ipairs(entries) do
    if entry.command_type == "TestAutoPromoteGrandchild" then
        top_level_grandchildren = top_level_grandchildren + 1
    end
end
assert(top_level_grandchildren == 0,
    string.format("grandchild of promoted parent should nest, not appear top-level (got %d)",
        top_level_grandchildren))
print("  scenario 3: grandchild nests under promoted parent, not re-promoted")

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
command_manager.unregister_executor("TestAutoPromoteParent")
command_manager.unregister_executor("TestAutoPromoteChild")
command_manager.unregister_executor("TestOuterNonPersisting")
command_manager.unregister_executor("TestInnerNonPersisting")
command_manager.unregister_executor("TestAutoPromoteDispatcher")
command_manager.unregister_executor("TestAutoPromoteWithNestedChild")
command_manager.unregister_executor("TestAutoPromoteGrandchild")
command_manager.remove_listener(listener)

print("\n✅ test_auto_promote_nested_persisting.lua passed")
