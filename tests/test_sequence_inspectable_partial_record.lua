#!/usr/bin/env luajit
-- Regression test: SequenceInspectable:get returns correct values when
-- opts.sequence was constructed by database.load_sequences() (the project
-- browser's source), which supplies only a subset of columns. Previously
-- mark_in_frame / mark_out_frame / playhead_frame / start_timecode_frame
-- all read as nil → blank in Inspector. Fix: lazy-load the full record via
-- Sequence.load on first read of a missing mapped field.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local SequenceInspectable = require("inspectable.sequence")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== SequenceInspectable: partial-record lazy DB fill ===\n")

-- Set up a real DB with one sequence that has marks + playhead set.
local db_path = "/tmp/jve/test_sequence_partial_record.db"
os.remove(db_path); os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
]], now, now))
-- Insert a sequence row with real values for marks, playhead, start tc.
db:exec(string.format([[
    INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
         width, height, playhead_frame, view_start_frame, view_duration_frames,
         mark_in_frame, mark_out_frame, start_timecode_frame,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         created_at, modified_at)
    VALUES
        ('seq', 'proj', 'TestSeq', 'nested', 25, 1, 48000,
         1920, 1080, 42, 0, 1000,
         91500, 93000, 90000,
         0, 0, 0.5,
         %d, %d);
]], now, now))

-- Simulate the browser's source: a minimal record like
-- database.load_sequences() produces. No mark_in / mark_out / playhead_* /
-- start_timecode_frame. Keys that DO exist on this record (audio_sample_rate,
-- name, frame_rate, width, height) must not trigger a reload.
local browser_record = {
    id                = "seq",
    project_id        = "proj",
    name              = "TestSeq",
    frame_rate        = { fps_numerator = 25, fps_denominator = 1 },
    audio_sample_rate = 48000,
    width             = 1920,
    height            = 1080,
}

local seq_ins = SequenceInspectable.new({
    sequence_id = "seq",
    project_id  = "proj",
    sequence    = browser_record,
})

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want))) end
end

-- Present on browser_record: returns without DB load.
check("name (from browser record)",        seq_ins:get("name"),        "TestSeq")
check("width (from browser record)",       seq_ins:get("width"),       1920)
check("audio_rate (map → audio_sample_rate, from browser record)",
    seq_ins:get("audio_rate"), 48000)

-- NOT on browser_record — must lazy-load from DB.
check("mark_in_frame (lazy DB load, 91500)",
    seq_ins:get("mark_in_frame"),      91500)
check("mark_out_frame (now-loaded record)",
    seq_ins:get("mark_out_frame"),     93000)
check("playhead_frame (map → playhead_position, 42)",
    seq_ins:get("playhead_frame"),     42)
check("start_timecode_frame (90000)",
    seq_ins:get("start_timecode_frame"), 90000)

-- frame_rate_display is synthetic — computed from the rate table always
-- available on the browser record (no DB load required).
check("frame_rate_display (25 fps synthetic)",
    seq_ins:get("frame_rate_display"), "25 fps")

-- Sanity: a fresh inspectable with NO opts.sequence falls straight to DB.
local seq_ins2 = SequenceInspectable.new({
    sequence_id = "seq",
    project_id  = "proj",
})
check("no-opts-sequence: reads mark_in_frame via DB load",
    seq_ins2:get("mark_in_frame"), 91500)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_sequence_inspectable_partial_record.lua passed")
