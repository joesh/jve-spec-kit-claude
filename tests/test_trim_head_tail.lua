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

local TEST_DB = "/tmp/jve/test_trim_head_tail.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('seq', 'proj', 'Sequence', 'sequence', 24, 1, 48000, 1920, 1080, 0, 10000, 0,
        '[]', '[]', '[]', 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

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
    local stmt = db:prepare("SELECT sequence_start_frame, duration_frames, source_in_frame, source_out_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    if stmt:next() then
        local c = {
            start = stmt:value(0),
            duration = stmt:value(1),
            source_in = stmt:value(2),
            source_out = stmt:value(3),
        }
        stmt:finalize()
        return c
    end
    stmt:finalize()
    return nil
end

local function set_db_playhead(val)
    -- viewport_state.set_playhead_position writes only to the UI cache; commands
    -- read playhead from the DB via Sequence.load. Bypass the persist_callback
    -- and write directly so TrimHead's pre-execute capture sees the value.
    local stmt = db:prepare("UPDATE sequences SET playhead_frame = ? WHERE id = 'seq'")
    stmt:bind_value(1, val)
    assert(stmt:exec())
    stmt:finalize()
end

local function get_db_playhead()
    local stmt = db:prepare("SELECT playhead_frame FROM sequences WHERE id = 'seq'")
    assert(stmt:exec())
    assert(stmt:next())
    local val = stmt:value(0)
    stmt:finalize()
    return val
end

local function create_clip(id, track_id, start, duration, source_in)
    source_in = source_in or 100  -- non-trivial source_in to catch bugs
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
    -- V13: clips reference master sequences, not media directly. Build the
    -- master via ensure_master, then place a clip on the timeline that
    -- references it.
    local Sequence = require('models.sequence')
    local master_seq_id = Sequence.ensure_master(media_id, 'proj')
    local now = os.time()
    local Clip = require('models.clip')
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
        created_at = now,
        modified_at = now,
    })
end

local function reset()
    db:exec("DELETE FROM clips;")
    db:exec("DELETE FROM media;")
    timeline_state.reload_clips()
    timeline_state.set_playhead_position(0)
end


-- ═══════════════════════════════════════════════════════════
-- TrimHead tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimHead: basic trim + ripple + playhead ---")
do
    reset()
    -- Clip: start=50, dur=100, source_in=100 → frames [50..150)
    -- Downstream: start=150, dur=80 → frames [150..230)
    -- Trim at 80 → remove [50,80), ripple by 30
    -- Expected: clip becomes [50..120) source_in=130, downstream at [120..200)
    create_clip("th1", "v1", 50, 100, 100)
    create_clip("th1_next", "v1", 150, 80, 200)
    timeline_state.reload_clips()
    -- Pre-trim playhead = 65 (NOT equal to trim_frame=80). The pass-17 fix
    -- captures prior_playhead from the DB and restores it on undo; if a
    -- regression made undo restore trim_frame, this assertion would fail.
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
    -- V1 clip: [20..120), A1 clip: [20..120) — linked pair
    -- Downstream V1: [120..200), downstream A1: [120..200)
    -- Trim at 60 → remove [20,60), ripple 40 frames
    -- Expected: clips become [20..80), downstreams at [80..160)
    create_clip("mt_v", "v1", 20, 100, 50)
    create_clip("mt_a", "a1", 20, 100, 50)
    create_clip("mt_v_next", "v1", 120, 80, 300)
    create_clip("mt_a_next", "a1", 120, 80, 300)
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
    -- Clip: start=50, dur=100, source_in=100 → frames [50..150)
    -- Downstream: start=150, dur=80 → frames [150..230)
    -- Trim at 110 → remove [110,150), ripple by 40
    -- Expected: clip becomes [50..110) source_out=160, downstream at [110..190)
    create_clip("tt1", "v1", 50, 100, 100)
    create_clip("tt1_next", "v1", 150, 80, 200)
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
    create_clip("tt_v", "v1", 20, 100, 50)
    create_clip("tt_a", "a1", 20, 100, 50)
    create_clip("tt_v_next", "v1", 120, 80, 300)
    create_clip("tt_a_next", "a1", 120, 80, 300)
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
    create_clip("edge1", "v1", 50, 100, 0)
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
    create_clip("edge2", "v1", 50, 100, 0)
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
