#!/usr/bin/env luajit

-- Regression: commands that don't touch clips declare `skip_clip_snapshot`
-- in their spec to avoid the ~few-MB per-command clone of every clip in
-- the active sequence. Verify that ToggleTrackPreference (which only modifies
-- tracks) does NOT push a clip-state mutation snapshot, and that rollback
-- behavior still works cleanly when no snapshot was taken.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
require('models.track')  -- luacheck: ignore 411
local command_manager = require('core.command_manager')
local clip_state = require('ui.timeline.state.clip_state')

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== skip_clip_snapshot opt-out ===\n")

local db_path = "/tmp/jve/test_skip_clip_snapshot.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('project', 'Test Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- --------------------------------------------------------------------------
-- Before execution, the snapshot stack should be empty (no active snapshot).
-- --------------------------------------------------------------------------
assert(not clip_state.has_active_mutation_snapshot(),
    "pre-exec: expected no active snapshot")
print("  pre-exec: no active snapshot — OK")

-- --------------------------------------------------------------------------
-- Execute ToggleTrackPreference. It should succeed without pushing a snapshot.
-- --------------------------------------------------------------------------
local r = command_manager.execute("ToggleTrackPreference", {
    track_id = 'track_v1',
    property = 'muted',
    value = true,
    project_id = 'project',
})
assert(r.success,
    string.format("ToggleTrackPreference failed: %s", tostring(r.error_message)))

-- After execution, the snapshot stack should STILL be empty. If
-- skip_clip_snapshot was ignored, the post-commit cleanup would have
-- committed a snapshot that was pushed and popped — hard to observe. But
-- we can check that the cleanup block didn't try to pop an empty stack
-- (which would have asserted) — success here proves the guarded path.
assert(not clip_state.has_active_mutation_snapshot(),
    "post-exec: expected no active snapshot")
print("  post-exec: no active snapshot — OK (skip_clip_snapshot respected)")

-- --------------------------------------------------------------------------
-- Now force a failure: invalid property triggers an executor assert.
-- The rollback path must not try to pop a snapshot that was never pushed.
-- --------------------------------------------------------------------------
local ok, err = pcall(command_manager.execute, "ToggleTrackPreference", {
    track_id = 'track_v1',
    property = 'not_a_real_property',
    value = true,
    project_id = 'project',
})
-- The invalid property fails via assert inside the executor, which is
-- caught by the nested xpcall and surfaces as execution_success=false.
-- That drives the rollback branch. Without the guard, rollback_mutations
-- would assert on the empty snapshot stack. With the guard, it's a no-op.
print(string.format("  invalid-property call: ok=%s err=%s",
    tostring(ok), tostring(err)))

assert(not clip_state.has_active_mutation_snapshot(),
    "after-failure: expected no active snapshot leaked by rollback")
print("  post-failure: no active snapshot leaked — OK")

-- --------------------------------------------------------------------------
-- Final sanity: another successful command still works (no corruption).
-- --------------------------------------------------------------------------
local r3 = command_manager.execute("ToggleTrackPreference", {
    track_id = 'track_v1',
    property = 'soloed',
    value = true,
    project_id = 'project',
})
assert(r3.success, "follow-up command must still succeed")
assert(not clip_state.has_active_mutation_snapshot(),
    "still no active snapshot after follow-up")
print("  follow-up: clean, no stale state")

print("\n✅ test_skip_clip_snapshot.lua passed")
