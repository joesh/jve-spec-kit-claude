#!/usr/bin/env luajit

-- Regression: RippleEdit on a non-existent gap should be a no-op.
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local Command = require('command')
local command_manager = require('core.command_manager')
local Project = require('models.project')
local Sequence = require('models.sequence')
local Track = require('models.track')
local Media = require('models.media')

print("=== RippleEdit No-Op Test ===\n")

local TEST_DB = "/tmp/jve/test_ripple_noop.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()

-- Disable overlap triggers for cleaner testing
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local project = Project.create("Test Project")
project:save()

local seq = Sequence.create("Test Sequence", project.id,
    { fps_numerator = 30, fps_denominator = 1 }, 1920, 1080)
seq:save()

local track_v1 = Track.create_video("V1", seq.id, { index = 1 })
track_v1:save()

for _, info in ipairs({
    { id = "media_a", name = "Media A" },
    { id = "media_b", name = "Media B" },
}) do
    Media.create({
        id = info.id,
        project_id = project.id,
        file_path = "/tmp/jve/" .. info.id .. ".mov",
        name = info.name,
        duration_frames = 4000,
        fps_numerator = 30,
        fps_denominator = 1,
    }):save(db)
end

-- Two back-to-back clips with no gap: clip_a [0,4000), clip_b [4000,8000)
local now = "strftime('%s','now')"
db:exec(string.format([[
    INSERT INTO clips (id, project_id, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, media_id, clip_kind, enabled, offline,
        created_at, modified_at)
    VALUES
        ('clip_a', '%s', '%s', '%s', 0, 4000, 0, 4000, 30, 1, 'media_a', 'timeline', 1, 0, %s, %s),
        ('clip_b', '%s', '%s', '%s', 4000, 4000, 0, 4000, 30, 1, 'media_b', 'timeline', 1, 0, %s, %s);
]], project.id, track_v1.id, seq.id, now, now,
    project.id, track_v1.id, seq.id, now, now))

-- Init command system with REAL timeline_state
command_manager.init(seq.id, project.id)

-- Attempt RippleEdit on clip_a's gap_after — no gap exists (clip_b is flush)
local ripple_cmd = Command.create("RippleEdit", project.id)
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    edge_type = "gap_after",
    track_id = track_v1.id,
})
ripple_cmd:set_parameter("delta_frames", 30)
ripple_cmd:set_parameter("sequence_id", seq.id)

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit no-op should succeed")

-- Black-box: no-op should not add undo history
assert(not command_manager.can_undo(), "No-op ripple should not add undo history")

-- Black-box: clips unchanged in DB
local clips = database.load_clips(seq.id)
local found = {}
for _, c in ipairs(clips) do
    if c.id == "clip_a" or c.id == "clip_b" then
        found[c.id] = c
    end
end
assert(found.clip_a, "clip_a should still exist")
assert(found.clip_b, "clip_b should still exist")
assert(found.clip_a.timeline_start == 0,
    "clip_a should still start at 0, got " .. tostring(found.clip_a.timeline_start))
assert(found.clip_b.timeline_start == 4000,
    "clip_b should still start at 4000, got " .. tostring(found.clip_b.timeline_start))

print("✅ RippleEdit no-op skips undo recording and leaves clips unchanged")
