#!/usr/bin/env luajit

-- TrimHead / TrimTail black-box tests with real database.
-- Verifies: clip trimming via ExtractRange delegation, playhead movement,
-- multi-track, undo/redo, edge cases.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Project = require('models.project')
local Sequence = require('models.sequence')
local Track = require('models.track')
local Clip = require('models.clip')

local TEST_DB = "/tmp/jve/test_trim_head_tail.db"
os.execute("mkdir -p /tmp/jve")
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

-- Setup: Project, Sequence, Tracks
local project = Project.create('Test Project', {
    id = 'proj',
    fps_mismatch_policy = 'resample',
    settings = { master_clock_hz = 192000, default_fps = { num = 24, den = 1 } }
})
assert(project:save(), "failed to save project")

local sequence = Sequence.create('Sequence', 'proj', { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
    id = 'seq',
    kind = 'sequence',
    audio_sample_rate = 48000,
    view_start_frame = 0,
    view_duration_frames = 10000,
    playhead_frame = 0
})
assert(sequence:save(), "failed to save sequence")

local v1 = Track.create_video("V1", 'seq', { index = 1 })
assert(v1:save(), "failed to save V1")
local a1 = Track.create_audio("A1", 'seq', { index = 1 })
assert(a1:save(), "failed to save A1")

command_manager.init('seq', 'proj')

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function get_clip(clip_id)
    local c = Clip.load(clip_id)
    if c then
        return {
            start = c.sequence_start,
            duration = c.duration,
            source_in = c.source_in,
            source_out = c.source_out,
        }
    end
    return nil
end

local function set_db_playhead(val)
    local s = Sequence.load('seq')
    s.playhead_position = val
    assert(s:save())
end

local function get_db_playhead()
    local s = Sequence.load('seq')
    return s.playhead_position
end

local function create_clip(id, track_id, start, duration, source_in)
    source_in = source_in or 100
    local media_id = id .. "_media"
    require("test_env").create_test_media({
        id = media_id,
        project_id = 'proj',
        name = id .. '.mov',
        file_path = '/tmp/jve/' .. id .. '.mov',
        duration_frames = 1000,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    local master_seq_id = Sequence.ensure_master(media_id, 'proj')
    local sub_in, sub_out = Clip.subframe_defaults_for(db, track_id)
    Clip.create({
        id = id,
        project_id = 'proj',
        owner_sequence_id = 'seq',
        track_id = track_id,
        sequence_id = master_seq_id,
        name = "Clip " .. id,
        sequence_start_frame = start,
        duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_in + duration,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = "resample",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end

local function reset()
    db:exec("DELETE FROM clips;")
    db:exec("DELETE FROM media;")
    db:exec("DELETE FROM sequences WHERE kind = 'master';")
    timeline_state.reload_clips()
    timeline_state.set_playhead_position(0)
end


-- ═══════════════════════════════════════════════════════════
-- TrimHead tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimHead: basic trim + ripple + playhead ---")
do
    reset()
    create_clip("th1", v1.id, 50, 100, 100)
    create_clip("th1_next", v1.id, 150, 80, 200)
    timeline_state.reload_clips()
    set_db_playhead(65)
    timeline_state.set_playhead_position(65)

    local result = command_manager.execute("TrimHead", {
        clip_ids = {"th1"},
        trim_frame = 80,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("TrimHead executes", result.success)

    local c = get_clip("th1")
    check("clip start = 50 (rippled back)", c.start == 50)
    check("clip duration = 70", c.duration == 70)
    check("source_in advanced by 30 = 130", c.source_in == 130)
    check("source_out unchanged = 200", c.source_out == 200)

    local next_c = get_clip("th1_next")
    check("downstream start rippled from 150 to 120", next_c.start == 120)
    check("downstream duration unchanged = 80", next_c.duration == 80)

    check("playhead moved to earliest_start = 50", get_db_playhead() == 50)
end

print("\n--- TrimHead: undo restores everything ---")
do
    local result = command_manager.undo()
    check("undo succeeds", result.success)

    local c = get_clip("th1")
    check("undo: start = 50", c.start == 50)
    check("undo: duration = 100", c.duration == 100)
    check("undo: source_in = 100", c.source_in == 100)

    local next_c = get_clip("th1_next")
    check("undo: downstream start = 150", next_c.start == 150)

    check("undo: playhead restored to pre-trim position = 65", get_db_playhead() == 65)
end

print("\n--- TrimHead: redo re-applies ---")
do
    local result = command_manager.redo()
    check("redo succeeds", result.success)

    local c = get_clip("th1")
    check("redo: start = 50", c.start == 50)
    check("redo: duration = 70", c.duration == 70)
    check("redo: source_in = 130", c.source_in == 130)

    local next_c = get_clip("th1_next")
    check("redo: downstream start = 120", next_c.start == 120)
end

print("\n--- TrimHead: multi-track (video + audio) ---")
do
    reset()
    create_clip("mt_v", v1.id, 20, 100, 50)
    create_clip("mt_a", a1.id, 20, 100, 50)
    create_clip("mt_v_next", v1.id, 120, 80, 300)
    create_clip("mt_a_next", a1.id, 120, 80, 300)
    timeline_state.reload_clips()
    timeline_state.set_playhead_position(60)

    local result = command_manager.execute("TrimHead", {
        clip_ids = {"mt_v", "mt_a"},
        trim_frame = 60,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("multi-track TrimHead executes", result.success)

    local v = get_clip("mt_v")
    local a = get_clip("mt_a")
    check("V1 start = 20", v.start == 20)
    check("V1 duration = 60", v.duration == 60)
    check("V1 source_in = 90", v.source_in == 90)
    check("A1 start = 20", a.start == 20)
    check("A1 duration = 60", a.duration == 60)
    check("A1 source_in = 90", a.source_in == 90)

    local vn = get_clip("mt_v_next")
    local an = get_clip("mt_a_next")
    check("V1 downstream rippled to 80", vn.start == 80)
    check("A1 downstream rippled to 80", an.start == 80)

    check("playhead = 20", get_db_playhead() == 20)
end


-- ═══════════════════════════════════════════════════════════
-- TrimTail tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimTail: basic trim + ripple ---")
do
    reset()
    create_clip("tt1", v1.id, 50, 100, 100)
    create_clip("tt1_next", v1.id, 150, 80, 200)
    timeline_state.reload_clips()
    timeline_state.set_playhead_position(110)

    local result = command_manager.execute("TrimTail", {
        clip_ids = {"tt1"},
        trim_frame = 110,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("TrimTail executes", result.success)

    local c = get_clip("tt1")
    check("clip start unchanged = 50", c.start == 50)
    check("clip duration = 60", c.duration == 60)
    check("source_in unchanged = 100", c.source_in == 100)
    check("source_out = 160", c.source_out == 160)

    local next_c = get_clip("tt1_next")
    check("downstream start rippled from 150 to 110", next_c.start == 110)

end

print("\n--- TrimTail: undo restores everything ---")
do
    local result = command_manager.undo()
    check("undo succeeds", result.success)

    local c = get_clip("tt1")
    check("undo: duration = 100", c.duration == 100)
    check("undo: source_out = 200", c.source_out == 200)

    local next_c = get_clip("tt1_next")
    check("undo: downstream start = 150", next_c.start == 150)

end

print("\n--- TrimTail: redo re-applies ---")
do
    local result = command_manager.redo()
    check("redo succeeds", result.success)

    local c = get_clip("tt1")
    check("redo: duration = 60", c.duration == 60)

    local next_c = get_clip("tt1_next")
    check("redo: downstream start = 110", next_c.start == 110)
end

print("\n--- TrimTail: multi-track ---")
do
    reset()
    create_clip("tt_v", v1.id, 20, 100, 50)
    create_clip("tt_a", a1.id, 20, 100, 50)
    create_clip("tt_v_next", v1.id, 120, 80, 300)
    create_clip("tt_a_next", a1.id, 120, 80, 300)
    timeline_state.reload_clips()
    timeline_state.set_playhead_position(70)

    local result = command_manager.execute("TrimTail", {
        clip_ids = {"tt_v", "tt_a"},
        trim_frame = 70,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("multi-track TrimTail executes", result.success)

    local v = get_clip("tt_v")
    local a = get_clip("tt_a")
    check("V1 duration = 50", v.duration == 50)
    check("A1 duration = 50", a.duration == 50)

    local vn = get_clip("tt_v_next")
    local an = get_clip("tt_a_next")
    check("V1 downstream rippled to 70", vn.start == 70)
    check("A1 downstream rippled to 70", an.start == 70)
end

-- ═══════════════════════════════════════════════════════════
-- Edge cases
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimHead: playhead outside clip fails ---")
do
    reset()
    create_clip("edge1", v1.id, 50, 100, 0)
    timeline_state.reload_clips()

    local result = command_manager.execute("TrimHead", {
        clip_ids = {"edge1"},
        trim_frame = 5,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("TrimHead outside clip fails", not result.success)
end

print("\n--- TrimTail: playhead outside clip fails ---")
do
    reset()
    create_clip("edge2", v1.id, 50, 100, 0)
    timeline_state.reload_clips()

    local result = command_manager.execute("TrimTail", {
        clip_ids = {"edge2"},
        trim_frame = 200,
        sequence_id = "seq",
        project_id = "proj",
    })
    check("TrimTail outside clip fails", not result.success)
end


-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_trim_head_tail.lua passed")
