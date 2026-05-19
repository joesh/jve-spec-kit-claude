#!/usr/bin/env luajit

-- Regression: RelinkClips mid-executor failure must produce ZERO DB
-- side-effects. The failure point exercised here is the orphan-duration
-- check (line ~179 in relink_clips.lua), which fires AFTER Phase 2
-- batch_set_file_paths has already written new media paths. If the
-- transaction doesn't wrap the full executor (or if ShowRelinkDialog's
-- non-recording parent fails to auto-promote the nested RelinkClips to
-- its own top-level transaction), the path updates persist and the
-- project ends up half-relinked.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_transaction_safety.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Media           = require("models.media")

local DB = "/tmp/jve/test_relink_transaction_safety.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p','P','resample','{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',%d,%d);

    -- Two media rows that WILL be touched by Phase 2.
    INSERT INTO media (id, project_id, name, file_path,
        duration_frames, fps_numerator, fps_denominator,
        audio_sample_rate, audio_channels, width, height, codec,
        metadata, created_at, modified_at)
    VALUES
      ('m-a', 'p', 'a.mov', '/orig/a.mov',
            240, 24, 1, 48000, 2, 1920, 1080, 'prores',
            '{"start_tc_value":0,"start_tc_rate":24}', %d, %d),
      ('m-b', 'p', 'b.mov', '/orig/b.mov',
            240, 24, 1, 48000, 2, 1920, 1080, 'prores',
            '{"start_tc_value":0,"start_tc_rate":24}', %d, %d);

    -- Bootstrap record sequence so command_manager.init has a non-master.
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 48000,
            1920, 1080, 0, 0, 300, %d, %d);
]], now, now, now, now, now, now, now, now))

command_manager.init('rec', 'p')

local function load_path(media_id)
    local m = Media.load(media_id)
    return m and m:get_file_path()
end

-- Sanity: paths start at /orig/*.
assert(load_path("m-a") == "/orig/a.mov", "test setup: m-a path")
assert(load_path("m-b") == "/orig/b.mov", "test setup: m-b path")

-- ── The triggering call ───────────────────────────────────────────────────
-- Phase 2 will batch-update both m-a and m-b paths to /relinked/*.
-- THEN the orphan-duration check fires for "m-orphan" (no entry in
-- media_path_changes), asserts, executor unwinds. command_manager must
-- ROLLBACK so neither m-a nor m-b retains its new path.
local asserts = require("core.asserts")
asserts._set_enabled_for_tests(false)
local result = command_manager.execute("RelinkClips", {
    project_id      = "p",
    clip_relink_map = {},
    media_path_changes = {
        ["m-a"] = "/relinked/a.mov",
        ["m-b"] = "/relinked/b.mov",
    },
    media_duration_updates = {
        ["m-orphan"] = {  -- triggers the orphan assert after Phase 2 writes
            duration_frames = 100,
            audio_duration_samples = 200000,
        },
    },
})
asserts._set_enabled_for_tests(true)

assert(result and result.success == false,
    "FAIL: RelinkClips must refuse on orphan duration update")

-- ── Rollback invariants ───────────────────────────────────────────────────
local a_after = load_path("m-a")
local b_after = load_path("m-b")
assert(a_after == "/orig/a.mov", string.format(
    "FAIL: m-a path leaked through failed transaction: %q (expected /orig/a.mov)",
    tostring(a_after)))
assert(b_after == "/orig/b.mov", string.format(
    "FAIL: m-b path leaked through failed transaction: %q (expected /orig/b.mov)",
    tostring(b_after)))
print("  ✓ failed RelinkClips left both media paths intact")

print("✅ test_relink_transaction_safety.lua passed")
