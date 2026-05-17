#!/usr/bin/env luajit

-- Regression: the Overwrite and Insert commands are wrapper commands that
-- delegate to AddClipsToSequence. Each clip inserted by the nested command
-- must appear in timeline_state.state.clips EXACTLY ONCE.
--
-- Previously both wrappers forwarded __timeline_mutations from the nested
-- command onto themselves; command_manager.apply_command_mutations then
-- re-applied those mutations on the outer command, duplicating every clip
-- in state. The duplicate was masked by the unconditional reload_clips
-- fallback until sibling commit 9f8e16f removed that fallback for mark-
-- family commands — which unmasked the duplicate via test_mark_range_edit
-- (a downstream reader that saw 2 clips from a single insert).
--
-- Domain behavior under test:
--   One Overwrite → one media clip in state.clips (plus derived gaps).
--   Ditto for Insert.
--   Subsequent commands that don't reload state MUST not find duplicates.

require('test_env')

_G.qt_create_single_shot_timer = function() end

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Sequence = require('models.sequence')
local Media = require('models.media')
-- Load the facade so command_manager's state init wires the per-module
-- instance the DB mutation path writes into. We then read the raw state
-- table directly to bypass get_clips's index rebuild (the rebuild would
-- filter the fields we care about).
require('ui.timeline.timeline_state')
local tsdata = require('ui.timeline.state.timeline_state_data')
local test_env = require('test_env')

local DB_PATH = "/tmp/jve/test_insert_overwrite_no_duplicate.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH))
local conn = database.get_connection()
conn:exec(require('import_schema'))

local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('seq', 'proj', 'TL', 'sequence', 25, 1, 48000, 1920, 1080, 0, 0, 8000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now))

command_manager.init('seq', 'proj')

-- Prepare a masterclip with known source marks.
local m = Media.create({
    id = "m1", project_id = 'proj',
    file_path = '/tmp/jve/m1.mov',
    name = "m1", duration_frames = 500,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080, audio_channels = 0,
})
m:save(conn)
local mc = test_env.create_test_masterclip_sequence('proj', 'm1 MC', 25, 1, 500, 'm1')
local mc_seq = Sequence.load(mc)
mc_seq:set_in(50)
mc_seq:set_out(350)
mc_seq:save()

print("=== Overwrite → state.clips has exactly one entry per inserted clip ===")

local cmd = Command.create("Overwrite", "proj")
cmd:set_parameters({
    source_sequence_id = mc, target_video_track_id = "v1", sequence_id = "seq",
    sequence_start_frame = 100, advance_playhead = false,
})
local res = command_manager.execute(cmd)
assert(res.success, "Overwrite failed: " .. tostring(res.error_message))
local clip_a = (cmd:get_parameter("created_clip_ids") or {})[1]
assert(clip_a, "Overwrite did not produce created_clip_ids")

-- Count media (non-gap) clips for id in state.
local function count_media_clips_in_state(clip_id)
    local n = 0
    for _, c in ipairs(tsdata.state.clips) do
        if not c.is_gap and c.id == clip_id then n = n + 1 end
    end
    return n
end

local count_a = count_media_clips_in_state(clip_a)
assert(count_a == 1, string.format(
    "Overwrite must insert each clip exactly once into state.clips; "
    .. "found %d copies of the new clip (duplicate-insert regression)", count_a))
print(string.format("  OK: Overwrite inserted new clip exactly once (%d occurrences)", count_a))

-- Sanity: DB count matches
local stmt = assert(conn:prepare("SELECT COUNT(*) FROM clips WHERE id=?"))
stmt:bind_value(1, clip_a)
assert(stmt:exec() and stmt:next())
local db_count = stmt:value(0)
stmt:finalize()
assert(db_count == 1, "DB should have exactly one new clip row; got " .. tostring(db_count))

print("=== Insert → same invariant ===")

local cmd2 = Command.create("Insert", "proj")
cmd2:set_parameters({
    source_sequence_id = mc, target_video_track_id = "v1", sequence_id = "seq",
    sequence_start_frame = 500, advance_playhead = false,
})
local res2 = command_manager.execute(cmd2)
assert(res2.success, "Insert failed: " .. tostring(res2.error_message))
local clip_b = (cmd2:get_parameter("created_clip_ids") or {})[1]
assert(clip_b, "Insert did not produce created_clip_ids")

local count_b = count_media_clips_in_state(clip_b)
assert(count_b == 1, string.format(
    "Insert must insert each clip exactly once into state.clips; "
    .. "found %d copies of the new clip (duplicate-insert regression)", count_b))
print(string.format("  OK: Insert inserted new clip exactly once (%d occurrences)", count_b))

print("✅ test_insert_overwrite_no_duplicate_state_clips.lua passed")
