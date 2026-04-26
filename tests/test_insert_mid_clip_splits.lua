#!/usr/bin/env luajit
-- Regression: Insert at a frame strictly inside an existing clip's range
-- splits that clip into a left half (ending at the insertion frame) and a
-- right half (starting at the insertion frame). The right half plus all
-- downstream clips ripple forward by the inserted duration.
--
-- This matches Resolve / Premiere / FCP UX and the V8 behavior that
-- regressed during the V13 placement rewrite (T040).
--
-- Domain assertions only — no internal mutation-shape parsing, no
-- DB-trigger workarounds. Final-state queries on the clips table.

require('test_env')

local database        = require('core.database')
local command_manager = require('core.command_manager')
local Command         = require('command')
local Media           = require('models.media')
local Sequence        = require('models.sequence')
local test_env        = require('test_env')

_G.qt_create_single_shot_timer = function(_, cb) cb(); return nil end

local DB = "/tmp/jve/test_insert_mid_clip_splits.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require('import_schema'))

-- 24fps timeline, 1 V track.
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at)
        VALUES ('seq', 'proj', 'TL', 'nested', 24, 1, 48000, 1920, 1080, 0, 5000, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now))

command_manager.init('seq', 'proj')

-- Long media so existing clips can use a non-trivial source window without
-- bumping into INV-4 (clip source must fit in master's effective duration).
test_env.create_test_media({
    id = "med", project_id = "proj", file_path = "/tmp/jve/med.mov",
    name = "med", duration_frames = 5000,
    fps_numerator = 24, fps_denominator = 1,
    width = 1920, height = 1080, audio_channels = 0,
})
local master = Sequence.ensure_master("med", "proj")

-- Place A at timeline [0, 100), source [100, 200) — non-trivial source_in
-- catches off-by-one math in the split's source-side delta.
local Clip = require('models.clip')
local clip_a_id = Clip.create({
    name = "A", project_id = "proj",
    track_id = "v1", owner_sequence_id = "seq", nested_sequence_id = master,
    timeline_start_frame = 0, duration_frames = 100,
    source_in_frame = 100, source_out_frame = 200,
    fps_mismatch_policy = "resample", enabled = true, volume = 1.0,
    playhead_frame = 0,
})

-- Place C at timeline [200, 300), source [400, 500) — far enough downstream
-- that there's a gap between A and C (so the test isolates "ripple of C"
-- from "split of A").
local clip_c_id = Clip.create({
    name = "C", project_id = "proj",
    track_id = "v1", owner_sequence_id = "seq", nested_sequence_id = master,
    timeline_start_frame = 200, duration_frames = 100,
    source_in_frame = 400, source_out_frame = 500,
    fps_mismatch_policy = "resample", enabled = true, volume = 1.0,
    playhead_frame = 0,
})

-- Mark a 20-frame range on the master so Insert places a 20-frame clip.
do
    local m = Sequence.load(master)
    m:set_in(80); m:set_out(100); m:save()
end

-- Load the seed clips into timeline_state so command_manager's mutation
-- replay (bulk_shifts on the ripple) finds them. Real app does this when
-- the sequence becomes active; tests must mirror it.
local timeline_state = require('ui.timeline.timeline_state')
timeline_state.init('seq', 'proj')
timeline_state.reload_clips('seq')

-- Insert at frame 50 (strictly inside A: 0 < 50 < 100).
local cmd = Command.create("Insert", "proj")
cmd:set_parameter("nested_sequence_id", master)
cmd:set_parameter("target_video_track_id", "v1")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("timeline_start_frame", 50)
cmd:set_parameter("clip_name", "B")
local result = command_manager.execute(cmd)
assert(result.success, "Insert failed: " .. tostring(result.error_message))

-- Final DB state: 4 clips on v1 in order A_left, B, A_right, C.
local function load_track_clips()
    local out = {}
    local q = db:prepare([[
        SELECT id, name, timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame
        FROM clips WHERE owner_sequence_id='seq' AND track_id='v1'
        ORDER BY timeline_start_frame ASC
    ]])
    assert(q:exec())
    while q:next() do
        out[#out+1] = {
            id            = q:value(0),
            name          = q:value(1),
            timeline_start = q:value(2),
            duration      = q:value(3),
            source_in     = q:value(4),
            source_out    = q:value(5),
        }
    end
    q:finalize()
    return out
end

local clips = load_track_clips()
assert(#clips == 4, string.format(
    "expected 4 clips on track v1 (A_left, B, A_right, C); got %d", #clips))

local A_left, B, A_right, C = clips[1], clips[2], clips[3], clips[4]

-- A_left: untouched start, shrunk to the insertion frame, source_in unchanged.
assert(A_left.timeline_start == 0,
    "A_left.timeline_start expected 0, got " .. A_left.timeline_start)
assert(A_left.duration == 50,
    "A_left.duration expected 50, got " .. A_left.duration)
assert(A_left.source_in == 100,
    "A_left.source_in expected 100, got " .. A_left.source_in)
assert(A_left.source_out == 150,
    "A_left.source_out expected 150 (100 + 50 frames @ resample 1:1), got "
    .. A_left.source_out)
assert(A_left.id == clip_a_id,
    "A_left should be the original A row (id preserved on the left half)")

-- B (new): occupies [50, 70). 20-frame range from the master's mark window.
assert(B.timeline_start == 50,
    "B.timeline_start expected 50, got " .. B.timeline_start)
assert(B.duration == 20,
    "B.duration expected 20, got " .. B.duration)
assert(B.source_in == 80,
    "B.source_in expected 80 (mark_in on master), got " .. B.source_in)
assert(B.source_out == 100,
    "B.source_out expected 100 (mark_out on master), got " .. B.source_out)

-- A_right: starts at the insertion frame plus the inserted duration,
-- source picks up where A_left left off.
assert(A_right.timeline_start == 70,
    "A_right.timeline_start expected 70 (50 + 20), got " .. A_right.timeline_start)
assert(A_right.duration == 50,
    "A_right.duration expected 50 (the half not consumed by A_left), got "
    .. A_right.duration)
assert(A_right.source_in == 150,
    "A_right.source_in expected 150 (continues from A_left's source_out), got "
    .. A_right.source_in)
assert(A_right.source_out == 200,
    "A_right.source_out expected 200 (A's original source_out), got "
    .. A_right.source_out)
assert(A_right.id ~= clip_a_id,
    "A_right is a NEW row; A_left keeps the original id")

-- C: rippled forward by the inserted duration; source range untouched.
assert(C.id == clip_c_id, "C should be the original C row")
assert(C.timeline_start == 220,
    "C.timeline_start expected 220 (200 + 20), got " .. C.timeline_start)
assert(C.duration == 100,
    "C.duration expected unchanged at 100, got " .. C.duration)
assert(C.source_in == 400 and C.source_out == 500,
    "C source range expected [400, 500), got [" .. C.source_in .. ", " .. C.source_out .. ")")

-- Undo restores everything: A whole, no B, C back at 200.
local und = command_manager.undo()
assert(und.success, "undo failed: " .. tostring(und.error_message))
clips = load_track_clips()
assert(#clips == 2, "after undo expected 2 clips (A, C); got " .. #clips)
assert(clips[1].id == clip_a_id and clips[1].timeline_start == 0
       and clips[1].duration == 100
       and clips[1].source_in == 100 and clips[1].source_out == 200,
    "after undo A should be its original [0,100) src [100,200)")
assert(clips[2].id == clip_c_id and clips[2].timeline_start == 200
       and clips[2].duration == 100,
    "after undo C should be back at [200, 300)")

-- Redo re-applies the split.
local red = command_manager.redo()
assert(red.success, "redo failed: " .. tostring(red.error_message))
clips = load_track_clips()
assert(#clips == 4, "after redo expected 4 clips again; got " .. #clips)

print("✅ test_insert_mid_clip_splits.lua passed")
