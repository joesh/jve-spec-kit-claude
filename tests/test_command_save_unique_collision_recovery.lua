#!/usr/bin/env luajit

-- Regression: when the commands table contains rows written by another
-- writer (external process, test harness, previous session whose state
-- the running editor doesn't know about), the in-memory allocator can be
-- stale. A new command saved with a stale sequence_number collides with
-- an existing row and fails with SQLite UNIQUE constraint.
--
-- The editor must recover: refresh the allocator from the DB's real MAX
-- and retry the save with a fresh sequence_number. Without this recovery,
-- the editor becomes unusable — every subsequent command picks the same
-- colliding number, decrements on failure, and loops forever.
--
-- This test simulates the external writer by directly inserting a commands
-- row with a sequence_number that the in-memory allocator doesn't know
-- about, then verifying that command_manager.execute() can still persist
-- a new command without erroring.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
require('models.track')  -- luacheck: ignore 411
local command_manager = require('core.command_manager')
local history = require('core.command_history')

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== Command save: UNIQUE collision recovery ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_command_save_unique_collision_recovery.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('project', 'Test Project', 'resample', %d, %d);
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

-- --------------------------------------------------------------------------
-- Phase 1: Execute one command normally, seq advances to 1
-- --------------------------------------------------------------------------
local r1 = command_manager.execute("SetTrackProperty", {
    track_id = 'track_v1',
    property = 'muted',
    value = true,
    project_id = 'project',
})
assert(r1.success,
    string.format("Phase 1: first command failed unexpectedly: %s",
        tostring(r1.error_message)))

local max_q = db:prepare("SELECT MAX(sequence_number) FROM commands")
max_q:exec(); max_q:next()
local max_seq_after_1 = max_q:value(0) or 0
max_q:finalize()
assert(max_seq_after_1 == 1,
    string.format("Phase 1: expected max_seq=1, got %d", max_seq_after_1))
print(string.format("  phase 1: OK — first command persisted at seq=%d", max_seq_after_1))

-- --------------------------------------------------------------------------
-- Phase 2: Simulate an external writer inserting rows 2..5 directly.
-- The in-memory allocator still thinks last_sequence_number == 1.
-- --------------------------------------------------------------------------
for seq = 2, 5 do
    db:exec(string.format([[
        INSERT INTO commands
            (id, sequence_number, command_type, command_args, timestamp,
             playhead_value, playhead_rate)
        VALUES ('external-%d', %d, 'ExternalWriter', '{}', %d, 0, 30.0);
    ]], seq, seq, now))
end

local ext_check = db:prepare("SELECT COUNT(*) FROM commands")
ext_check:exec(); ext_check:next()
local total = ext_check:value(0)
ext_check:finalize()
assert(total == 5,
    string.format("Phase 2: expected 5 total rows (1 ours + 4 external), got %d", total))
print("  phase 2: OK — 4 external rows inserted (seq 2..5)")

-- Verify allocator is stale
assert(history.get_last_sequence_number() == 1,
    "Phase 2: expected in-memory allocator to still be at 1 (stale)")
print("  phase 2: allocator still at 1 — stale, as expected")

-- --------------------------------------------------------------------------
-- Phase 3: Execute a second command. Before the fix, it would allocate 2,
--          hit UNIQUE constraint, decrement to 1, and return failure.
--          After the fix, it should refresh from DB MAX=5 and allocate 6.
-- --------------------------------------------------------------------------
local r2 = command_manager.execute("SetTrackProperty", {
    track_id = 'track_v1',
    property = 'soloed',
    value = true,
    project_id = 'project',
})
assert(r2.success,
    string.format("Phase 3: second command failed — expected recovery from UNIQUE collision. error=%s",
        tostring(r2.error_message)))

-- Verify the command persisted at a sequence_number greater than the
-- external writer's highest row.
max_q = db:prepare("SELECT MAX(sequence_number) FROM commands")
max_q:exec(); max_q:next()
local max_seq_after_2 = max_q:value(0) or 0
max_q:finalize()
assert(max_seq_after_2 >= 6,
    string.format("Phase 3: expected max_seq >= 6 after recovery, got %d",
        max_seq_after_2))
print(string.format("  phase 3: OK — second command persisted at seq=%d (recovered from collision)",
    max_seq_after_2))

-- Verify our new row is there
local our_q = db:prepare("SELECT command_type FROM commands WHERE sequence_number = ?")
our_q:bind_value(1, max_seq_after_2)
our_q:exec(); our_q:next()
local our_type = our_q:value(0)
our_q:finalize()
assert(our_type == 'SetTrackProperty',
    string.format("Phase 3: expected SetTrackProperty at seq=%d, got %s",
        max_seq_after_2, tostring(our_type)))

-- Verify allocator now reflects the true DB state
assert(history.get_last_sequence_number() >= 6,
    string.format("Phase 3: expected allocator >= 6 after refresh, got %d",
        history.get_last_sequence_number()))
print("  phase 3: allocator refreshed to reflect DB MAX")

print("\n✅ test_command_save_unique_collision_recovery.lua passed")
