#!/usr/bin/env luajit
-- Regression: a mutation transaction must stay begin/commit balanced even when
-- no active record tab exists at begin time.
--
-- The blank-timeline drop flow opens an undo group while no sequence is active,
-- then creates the edit-target sequence INSIDE the group — so the active record
-- tab is nil at begin but a freshly-created tab by commit. The transaction must
-- remember the begin-time tab (nil here) so commit does not fire a snapshot on a
-- tab that never saw a begin. With no strip installed, the active record tab is
-- nil — exactly the begin-time condition the drop flow hits.
--
-- Also pins the actionable assert on the unpaired-commit/rollback error path.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")

data.reset()

-- No strip installed → no active record tab (the blank-drop begin-time state).
assert(not clip_state.has_active_mutation_snapshot(),
    "no transaction open before begin")

clip_state.begin_mutation_transaction()
assert(clip_state.has_active_mutation_snapshot(),
    "transaction frame must be open after begin even with no active record tab")

-- Commit must close the frame without crashing: there is no tab to commit on,
-- but the frame must still pop so begin/commit stay balanced.
clip_state.commit_mutation_transaction()
assert(not clip_state.has_active_mutation_snapshot(),
    "transaction frame must be closed after commit")
print("✓ begin/commit stays balanced with no active record tab")

-- Error path: commit with no paired begin asserts with an actionable message.
local ok, err = pcall(clip_state.commit_mutation_transaction)
assert(not ok, "commit with no open transaction must fail, not silently succeed")
assert(tostring(err):match("paired begin missing"),
    "commit assert must be actionable: " .. tostring(err))

-- Same guard on rollback.
local ok2, err2 = pcall(clip_state.rollback_mutation_transaction)
assert(not ok2, "rollback with no open transaction must fail, not silently succeed")
assert(tostring(err2):match("paired begin missing"),
    "rollback assert must be actionable: " .. tostring(err2))
print("✓ unpaired commit/rollback asserts with actionable message")

print("✅ test_clip_state_mutation_transaction_balance.lua passed")
