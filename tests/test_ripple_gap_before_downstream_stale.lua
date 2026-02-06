#!/usr/bin/env luajit

-- Regression test: RippleEdit gap_before downstream clamping uses stale clip positions
--
-- BUG: When doing gap_before ripple (moving a clip left), the downstream
-- clamping logic at lines 392-415 iterates `all_clips` which contains STALE
-- positions for the edited clip. The edited clip was loaded separately
-- (Clip.load) and its timeline_start already updated, but the all_clips list
-- has a different object with the OLD position. When the edited clip is the
-- immediate predecessor of a downstream clip, the computed available gap is 0
-- (stale end == downstream start), so the downstream shift is clamped to 0.
-- Result: clip moves but downstream clips don't follow, leaving an unintended gap.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== RippleEdit gap_before downstream stale position bug ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_ripple_gap_before_downstream_stale.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'project', 'Seq', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'seq', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('seq', 'project')

local media = Media.create({
    id = "media1",
    project_id = "project",
    file_path = "/tmp/jve/video.mov",
    name = "Video",
    duration_frames = 1000,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

local function execute_cmd(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
    command_manager.end_command_event()
    return result
end

local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function create_clip(id, start_frame, duration_frames, source_in)
    source_in = source_in or 0
    local clip = Clip.create("Clip " .. id, "media1", {
        id = id,
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "seq",
        timeline_start = Rational.new(start_frame, 30, 1),
        duration = Rational.new(duration_frames, 30, 1),
        source_in = Rational.new(source_in, 30, 1),
        source_out = Rational.new(source_in + duration_frames, 30, 1),
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save clip " .. id)
    return clip
end

local function get_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    assert(stmt:next(), "clip " .. clip_id .. " not found")
    local val = stmt:value(0)
    stmt:finalize()
    return val
end

local function reset()
    db:exec("DELETE FROM clips")
end

-- =============================================================================
-- TEST 1: gap_before — adjacent clips, edited clip is predecessor of downstream
-- =============================================================================
print("Test 1: gap_before with adjacent downstream clip uses stale predecessor position")
reset()

-- Setup: A [100, 200], B [200, 300] — adjacent, no gap between them
create_clip("clip_a", 100, 100, 0)
create_clip("clip_b", 200, 100, 100)

-- Move A left by 50 via gap_before (there's a 100-frame gap to the left of A)
local cmd = Command.create("RippleEdit", "project")
cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "gap_before"
})
cmd:set_parameter("delta_frames", -50)

local result = execute_cmd(cmd)
assert(result.success, "RippleEdit should succeed: " .. tostring(result.error_message))

local a_start = get_start("clip_a")
local b_start = get_start("clip_b")

-- A should be at 50 (moved left by 50)
assert(a_start == 50, string.format(
    "clip_a should be at 50, got %d", a_start))

-- B should ALSO shift left by 50, to 150. This is the bug: B stays at 200
-- because the downstream clamping uses A's OLD end (200) to compute the gap
-- to B (200 - 200 = 0), so the shift is clamped to 0.
assert(b_start == 150, string.format(
    "BUG: clip_b should follow to 150 (shifted left by 50), got %d — "
    .. "downstream clamping used stale position of edited clip", b_start))

print("  A at " .. a_start .. ", B at " .. b_start .. " — both shifted correctly")

-- =============================================================================
-- TEST 2: Undo should restore both clips to original positions
-- =============================================================================
print("Test 2: Undo restores both clips")
undo()

local a_start2 = get_start("clip_a")
local b_start2 = get_start("clip_b")
assert(a_start2 == 100, "clip_a should be back at 100, got " .. a_start2)
assert(b_start2 == 200, "clip_b should be back at 200, got " .. b_start2)
print("  A at " .. a_start2 .. ", B at " .. b_start2 .. " — restored")

-- =============================================================================
-- TEST 3: gap_before with gap between clips (non-adjacent)
-- =============================================================================
print("Test 3: gap_before with gap between edited clip and downstream")
reset()

-- A [100, 200], B [250, 350] — 50-frame gap between A and B
create_clip("clip_c", 100, 100, 0)
create_clip("clip_d", 250, 100, 100)

cmd = Command.create("RippleEdit", "project")
cmd:set_parameter("edge_info", {
    clip_id = "clip_c",
    track_id = "track_v1",
    edge_type = "gap_before"
})
cmd:set_parameter("delta_frames", -50)

result = execute_cmd(cmd)
assert(result.success, "RippleEdit should succeed")

local c_start = get_start("clip_c")
local d_start = get_start("clip_d")

assert(c_start == 50, string.format("clip_c should be at 50, got %d", c_start))
-- D should also shift by -50 to 200. Even with the stale-position bug,
-- the OLD gap was 50 frames (250-200=50), so allowed = -50, which matches
-- shift_rat. This case might pass even with the bug.
assert(d_start == 200, string.format(
    "clip_d should shift to 200, got %d", d_start))

print("  C at " .. c_start .. ", D at " .. d_start .. " — shifted correctly")

-- =============================================================================
-- TEST 4: gap_before with multiple downstream clips on same track
-- =============================================================================
print("Test 4: gap_before with chain of adjacent downstream clips")
reset()

-- A [100, 200], B [200, 300], C [300, 400] — all adjacent
create_clip("clip_e", 100, 100, 0)
create_clip("clip_f", 200, 100, 100)
create_clip("clip_g", 300, 100, 200)

cmd = Command.create("RippleEdit", "project")
cmd:set_parameter("edge_info", {
    clip_id = "clip_e",
    track_id = "track_v1",
    edge_type = "gap_before"
})
cmd:set_parameter("delta_frames", -30)

result = execute_cmd(cmd)
assert(result.success, "RippleEdit should succeed")

local e_start = get_start("clip_e")
local f_start = get_start("clip_f")
local g_start = get_start("clip_g")

assert(e_start == 70, string.format("clip_e should be at 70, got %d", e_start))
assert(f_start == 170, string.format(
    "BUG: clip_f should follow to 170, got %d", f_start))
assert(g_start == 270, string.format(
    "BUG: clip_g should follow to 270, got %d", g_start))

print("  E at " .. e_start .. ", F at " .. f_start .. ", G at " .. g_start)

print("\n✅ test_ripple_gap_before_downstream_stale.lua passed")
