#!/usr/bin/env luajit

-- Cut command: deletes selected clips, copies to clipboard, undo restores.
-- Uses REAL timeline_state — no mock.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require('models.media')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_cut_command.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080,
            0, 0, 240, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Init with REAL timeline_state
command_manager.init('default_sequence', 'default_project')

local function clip_exists(id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ? AND owner_sequence_id = 'default_sequence'")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
end

-- Helper to create clips using Insert command
local function create_clip_via_insert(spec)
    local media_id = spec.id .. "_media"
    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. spec.id .. '.mov',
        name = spec.id .. '.mov',
        duration_frames = spec.duration,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080
    })
    assert(media, "failed to create media for clip " .. tostring(spec.id))
    assert(media:save(db), "failed to save media for clip " .. tostring(spec.id))

    -- Create masterclip sequence for this media
    local master_clip_id = test_env.create_test_masterclip_sequence(
        'default_project', spec.id .. ' Master', 30, 1, spec.duration, media_id)

    local cmd = Command.create("Insert", "default_project")
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("track_id", spec.track)
    cmd:set_parameter("master_clip_id", master_clip_id)
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("insert_time", spec.start)
    cmd:set_parameter("duration", spec.duration)
    cmd:set_parameter("source_in", 0)
    cmd:set_parameter("source_out", spec.duration)

    local result = command_manager.execute(cmd)
    assert(result and result.success, "Insert command failed for " .. spec.id)
end

-- Create four clips as setup
local clip_specs = {
    {id = "clip_a", track = "track_v1", start = 0,    duration = 1500},
    {id = "clip_b", track = "track_v1", start = 3000, duration = 1500},
    {id = "clip_c", track = "track_v2", start = 1200, duration = 1200},
    {id = "clip_d", track = "track_v2", start = 5000, duration = 1500},
}

for _, spec in ipairs(clip_specs) do
    create_clip_via_insert(spec)
end

print("=== Cut Command Tests ===\n")

-- Test 1: Cut deletes selected clips
local clip_a = timeline_state.get_clip_by_id("clip_a")
local clip_c = timeline_state.get_clip_by_id("clip_c")
assert(clip_a, "clip_a should exist in timeline cache")
assert(clip_c, "clip_c should exist in timeline cache")
timeline_state.set_selection({clip_a, clip_c})

local result = command_manager.execute("Cut", {project_id = "default_project"})
assert(result.success, "Cut with selection should succeed")
assert(not clip_exists("clip_a"), "clip_a should be removed")
assert(not clip_exists("clip_c"), "clip_c should be removed")
assert(clip_exists("clip_b"), "clip_b should remain")
assert(clip_exists("clip_d"), "clip_d should remain")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo Cut should succeed")
assert(clip_exists("clip_a"), "clip_a should be restored after undo")
assert(clip_exists("clip_c"), "clip_c should be restored after undo")

-- Test 2: Cut with no selection returns false (nothing to do = not undoable)
timeline_state.set_selection({})
timeline_state.set_playhead_position(1300)
local before_count = #database.load_clips("default_sequence")
result = command_manager.execute("Cut", {project_id = "default_project"})
assert(not result.success, "Cut with no selection should return false (nothing to do)")
local after_count = #database.load_clips("default_sequence")

assert(before_count == after_count, "No clips should be removed when nothing is selected")
print("✅ Cut removes only selected clips and returns false when nothing is selected")
