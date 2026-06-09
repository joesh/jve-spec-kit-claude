#!/usr/bin/env luajit
-- M#5: command_manager.with_undo_group must be exception-safe.
-- Asserts thrown by the body MUST: (1) re-raise to caller, (2) leave
-- no open group / dangling savepoint, (3) roll back in-memory mutations,
-- (4) leave the system usable for subsequent commands.

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local ripple_layout   = require("synthetic.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_with_undo_group_exception_safety.db"

local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_a"},
        v1_a = {
            id = "clip_a",
            track_key = "v1",
            sequence_start = 100,
            duration = 500,
            source_in = 1000,
        },
    }
})

local cm = command_manager

assert(type(cm.with_undo_group) == "function",
    "command_manager must expose with_undo_group(label, fn) helper")

-- Snapshot pre-group state.
local before = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(before.sequence_start == 100, "clip_a starts at 100")

-- Body executes one real command (succeeds, applies mutation) then
-- throws via plain Lua error mid-group. The helper MUST rethrow but
-- not leave a leak.
local rethrown
local ok, err = pcall(function()
    cm.with_undo_group("M5_test_throwing_body", function()
        local nudge_result = cm.execute("Nudge", {
            project_id = layout.project_id,
            sequence_id = layout.sequence_id,
            nudge_amount = 50,
            selected_clip_ids = {"clip_a"},
        })
        assert(nudge_result.success, "Nudge must succeed")
        -- Body throws — simulates a phase-function assert in
        -- sync_edits_from_resolve mid-group.
        error("synthetic phase failure")
    end)
end)
rethrown = err

-- 1. Error re-raised to caller.
assert(not ok, "with_undo_group must re-raise body errors")
assert(tostring(rethrown):find("synthetic phase failure"),
    "rethrown error must carry original message — got: " .. tostring(rethrown))

-- 2. No open group lingers — a new top-level command must dispatch
--    without inheriting the dangling group.
assert(cm.can_undo() == false,
    "aborted with_undo_group must NOT advance the undo cursor")

-- 3. In-memory state rolled back to pre-group.
local after = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(after.sequence_start == 100,
    string.format("clip_a must roll back to 100 after with_undo_group "
        .. "body throws, got %s (leak!)", tostring(after.sequence_start)))

-- 4. System usable after the abort.
local post_result = cm.execute("Nudge", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    nudge_amount = 25,
    selected_clip_ids = {"clip_a"},
})
assert(post_result.success, "post-abort command must succeed: "
    .. tostring(post_result.error_message))
local post = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(post.sequence_start == 125,
    string.format("post-abort nudge should land at 125, got %s",
        tostring(post.sequence_start)))

-- 5. Happy path: body returns normally → group commits, command undoable.
local pre_happy = timeline_state.get_tab_strip():clip_by_id("clip_a").sequence_start
cm.with_undo_group("M5_test_happy_path", function()
    local r = cm.execute("Nudge", {
        project_id = layout.project_id,
        sequence_id = layout.sequence_id,
        nudge_amount = 10,
        selected_clip_ids = {"clip_a"},
    })
    assert(r.success)
end)
local happy = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(happy.sequence_start == pre_happy + 10,
    "happy path with_undo_group commits the mutation")
assert(cm.can_undo() == true,
    "happy path with_undo_group leaves an undoable entry")

layout:cleanup()
print("✅ test_with_undo_group_exception_safety.lua passed")
