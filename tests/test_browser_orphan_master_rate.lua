#!/usr/bin/env luajit
--- Regression: orphan master sequences (left behind after Media:delete)
-- must still expose a valid frame rate to the project browser. Before the
-- fix, project_browser.add_master_clip_item read clip.frame_rate (nil for
-- V13 master entries — they use `rate`) and fell back to media.frame_rate,
-- which from load_master_clips' LEFT JOIN was a stub `{fps_numerator=nil,
-- fps_denominator=nil}` table when media was deleted. format_timecode then
-- exploded inside frame_utils.normalize_rate. See models/media.lua:1271
-- (Media:delete intentionally leaves master shells; relink/undo callers
-- own teardown).
require("test_env")

print("=== test_browser_orphan_master_rate.lua ===")

local database = require("core.database")
local frame_utils = require("core.frame_utils")
local Media = require("models.media")
local Sequence = require("models.sequence")

local TEST_DB = "/tmp/jve/test_browser_orphan_master_rate.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-orphan-master"
local media_id = "media-doomed"

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Orphan Project', 'resample', %d, %d, '{}');

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('%s', '%s', 'A001.mov', '/tmp/A001.mov', 240, 25, 1,
        1920, 1080, 0, 'prores', %d, %d, '{"start_tc_value":0,"start_tc_rate":25}');
]], project_id, now, now,
    media_id, project_id, now, now))

-- Create master sequence (with media_ref). Then delete media, which leaves
-- the master shell behind (per Media:delete contract).
Sequence.ensure_master(media_id, project_id)
local m = Media.load(media_id)
assert(m, "media should load before delete")
m:delete()

-- Domain invariant: an orphan master is still listable (Media:delete
-- contract leaves the shell), and the listing carries a frame rate that
-- can format a timecode without error. Anything less means the browser
-- crashes when the user deletes media.
local clips = database.load_master_clips(project_id)
assert(#clips == 1,
    string.format("expected 1 orphaned master, got %d", #clips))

local clip = clips[1]
local tc = frame_utils.format_timecode(0, clip.frame_rate)
assert(type(tc) == "string" and tc ~= "",
    string.format("orphan master must format a timecode; got %s",
        tostring(tc)))
print("  ✓ orphan master listing yields a valid frame rate")

print("\n✅ test_browser_orphan_master_rate.lua passed")
