#!/usr/bin/env luajit

-- Persisting a master's playhead must NOT fail just because the cached
-- in-memory sequence object has unrelated stale fields. The current
-- implementation calls Sequence:save() — a full upsert that re-binds
-- every column, including FK-bearing ones (project_id,
-- default_video_layer_track_id) — when all we want is to persist the
-- playhead frame.
--
-- Reproduction (mirrors the TSO crash):
--   1. Create master sequence in project A.
--   2. Load the sequence model into memory.
--   3. Delete project A from the DB (or otherwise corrupt the FK).
--   4. Try to persist just the playhead.
-- Current behavior: full upsert tries to re-bind project_id → FK fails.
-- Expected behavior: a surgical UPDATE of playhead_frame succeeds because
-- it doesn't touch project_id at all. The "unrelated stale field" is a
-- separate bug to track down — but it MUST NOT take down playhead persist.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")

print("=== test_015_save_playhead_surgical.lua ===")

local DB = "/tmp/jve/test_015_save_playhead_surgical.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj_a', 'A', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('msa', 'proj_a', 'A012', 'master', 24, 1, NULL, 1920, 1080,
            100, 0, 300, %d, %d);
]], now,now, now,now))

-- 1. Load the master sequence into memory (simulating sequence_monitor.self.sequence).
local seq = Sequence.load("msa")
assert(seq and seq.kind == "master", "setup: expected master sequence")
assert(seq.playhead_position == 100, "setup: initial playhead is 100")

-- 2. Corrupt the project FK reference: delete the project. Sequences
--    rows would normally cascade-delete, but we disable FK temporarily
--    so the master row stays orphaned (mimicking the in-the-wild state
--    where source_monitor's cached sequence references a no-longer-valid
--    project_id).
db:exec("PRAGMA foreign_keys = OFF;")
db:exec("DELETE FROM projects WHERE id = 'proj_a';")
db:exec("PRAGMA foreign_keys = ON;")

-- 3. Try to persist just the playhead. The new behavior must succeed.
seq.playhead_position = 250
local ok, err = pcall(function()
    Sequence.update_playhead("msa", 250)
end)
assert(ok, string.format(
    "FAIL: Sequence.update_playhead must NOT trigger FK constraint failure "
    .. "even when other fields on the cached sequence are stale; got: %s",
    tostring(err)))
print("  surgical update_playhead succeeded despite broken project FK — OK")

-- 4. Verify the row's playhead actually changed.
local stmt = db:prepare("SELECT playhead_frame FROM sequences WHERE id = ?")
stmt:bind_value(1, "msa")
stmt:exec(); stmt:next()
local actual = stmt:value(0); stmt:finalize()
assert(actual == 250, string.format(
    "FAIL: expected playhead_frame=250 after update_playhead, got %s",
    tostring(actual)))
print("  playhead_frame in DB == 250 — OK")

-- 5. Sanity: full Sequence:save() on the same orphaned sequence MUST still
--    fail (the FK violation is real — we just shouldn't trigger it for a
--    surgical playhead persist). This pins the "narrow surface" property:
--    update_playhead is intentionally not equivalent to save.
local ok2 = pcall(function() seq:save() end)
assert(not ok2,
    "FAIL: full Sequence:save() on FK-broken sequence should still fail "
    .. "(this assertion pins update_playhead as a narrow surface, not a "
    .. "general-purpose alternative to save)")
print("  full save still fails — narrow-surface contract held — OK")

print("\n✅ test_015_save_playhead_surgical.lua passed")
