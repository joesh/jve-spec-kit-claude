#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
-- core.command_implementations is deleted
-- local command_impl = require('core.command_implementations')
local Command = require('command')
local Media = require('models.media')

local TEST_DB = "/tmp/jve/test_cut_command.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1);
]], now, now, now, now))

local function clips_snapshot()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, timeline_start_frame, duration_frames FROM clips ORDER BY track_id, timeline_start_frame")
    assert(stmt, "Failed to prepare clips_snapshot query")
    assert(stmt:exec())
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            timeline_start_frame = stmt:value(2),
            duration_frames = stmt:value(3)
        }
    end
    stmt:finalize()
    return clips
end

local function clip_exists(id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    return stmt:value(0) > 0
end

local Rational = require('core.rational')

local timeline_state = {
    playhead_position = Rational.new(0, 30, 1),  -- Rational, not integer
    selected_clips = {},
    sequence_frame_rate = 30.0
}

local function load_clips_into_state()
    timeline_state.clips = clips_snapshot()
end

load_clips_into_state()

function timeline_state.get_sequence_id() return 'default_sequence' end
function timeline_state.get_project_id() return 'default_project' end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.clear_edge_selection() timeline_state.selected_clips = {} end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.reload_clips() load_clips_into_state() end
function timeline_state.persist_state_to_db() end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(time_ms) timeline_state.playhead_position = time_ms end
function timeline_state.get_clips()
    load_clips_into_state()
    return timeline_state.clips
end
function timeline_state.get_sequence_frame_rate() return timeline_state.sequence_frame_rate end

local viewport_guard = 0
timeline_state.viewport_start_value = timeline_state.viewport_start_value or 0
timeline_state.viewport_duration_frames_value = timeline_state.viewport_duration_frames_value or 10000

function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration = timeline_state.viewport_duration_frames_value,
    }
end

function timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration then
        timeline_state.viewport_duration_frames_value = snapshot.duration
    end

    if snapshot.start_value then
        timeline_state.viewport_start_value = snapshot.start_value
    end
end

function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
-- command_impl.register_commands(executors, undoers, db)

command_manager.init('default_sequence', 'default_project')

-- Helper to create clips using Insert command
local function create_clip_via_insert(spec)
    local media_id = spec.id .. "_media"
    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. spec.id .. '.mov',
        name = spec.id .. '.mov',
        duration = spec.duration,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080
    })
    assert(media, "failed to create media for clip " .. tostring(spec.id))
    assert(media:save(db), "failed to save media for clip " .. tostring(spec.id))

    local cmd = Command.create("Insert", "default_project")
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("track_id", spec.track)
    cmd:set_parameter("media_id", media_id)
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("insert_time", Rational.new(spec.start, 30, 1))
    cmd:set_parameter("duration", Rational.new(spec.duration, 30, 1))
    cmd:set_parameter("source_in", Rational.new(0, 30, 1))
    cmd:set_parameter("source_out", Rational.new(spec.duration, 30, 1))

    local result = command_manager.execute(cmd)
    assert(result and result.success, "Insert command failed for " .. spec.id)
    return true
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

load_clips_into_state()

print("=== Cut Command Tests ===\n")

-- Test 1: Cut deletes selected clips
timeline_state.set_selection({
    {id = "clip_a"},
    {id = "clip_c"},
})

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

-- Test 2: Cut with no selection is a no-op
timeline_state.set_selection({})
timeline_state.playhead_position = Rational.new(1300, 30, 1)
local before = clips_snapshot()
result = command_manager.execute("Cut", {project_id = "default_project"})
assert(result.success, "Cut with no selection should still succeed")
local after = clips_snapshot()

assert(#before == #after, "No clips should be removed when nothing is selected")
print("✅ Cut removes only selected clips and does nothing when nothing is selected")
