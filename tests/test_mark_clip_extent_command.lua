-- Tests for MarkClipExtent command (X key) — marks clip boundaries under playhead.
-- Uses real command_manager + DB for SetMarkIn/SetMarkOut, stubs timeline_state for clip data.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")

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

print("\n=== MarkClipExtent Command Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_mark_clip_extent.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

local seq = Sequence.create("Timeline", "proj1",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "seq1", audio_rate = 48000})
assert(seq:save(), "setup: save sequence")

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq1', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

command_manager.init("seq1", "proj1")

-- Stub timeline_state for MarkClipExtent
local test_playhead = 50
local test_clips = {}
local test_tracks = {}

local timeline_state_stub = {
    get_playhead_position = function() return test_playhead end,
    get_clips = function() return test_clips end,
    get_sequence_id = function() return "seq1" end,
    get_track_by_id = function(track_id) return test_tracks[track_id] end,
    get_track_index = function(track_id)
        local t = test_tracks[track_id]
        return t and t.track_index
    end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    get_selected_gaps = function() return {} end,
    set_playhead_position = function() end,
    reload_clips = function() end,
}
package.loaded["ui.timeline.timeline_state"] = timeline_state_stub

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or "proj1"
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

local function reload_seq()
    return Sequence.load("seq1")
end

-- Set up test tracks
test_tracks["v1"] = {track_type = "VIDEO", track_index = 1}
test_tracks["a1"] = {track_type = "AUDIO", track_index = 1}

-- ── Test 1: Single video clip under playhead ──
print("\n--- Single video clip ---")
test_clips = {
    {id = "clip1", track_id = "v1", timeline_start = 20, duration = 80},
}
test_playhead = 50

local r = execute_cmd("MarkClipExtent", {sequence_id = "seq1"})
check("single clip: succeeds", r == true or (type(r) == "table" and r.success))

local s = reload_seq()
check("mark_in = clip start (20)", s.mark_in == 20)
-- mark_out is exclusive: last_frame=20+80-1=99, stored as 99+1=100
check("mark_out = clip end exclusive (100)", s.mark_out == 100)

-- ── Test 2: Playhead outside clip ──
print("\n--- Playhead outside clip ---")
-- Clear marks first
execute_cmd("ClearMarks", {sequence_id = "seq1"})
s = reload_seq()
check("marks cleared", s.mark_in == nil and s.mark_out == nil)

test_clips = {
    {id = "clip1", track_id = "v1", timeline_start = 200, duration = 50},
}
test_playhead = 10  -- before clip

execute_cmd("MarkClipExtent", {sequence_id = "seq1"})
-- Should succeed but not set marks (no clip under playhead)
s = reload_seq()
check("no clip under playhead: marks unchanged", s.mark_in == nil and s.mark_out == nil)

-- ── Test 3: Video clip wins over audio clip at same position ──
print("\n--- Video prioritized over audio ---")
test_clips = {
    {id = "audio_clip", track_id = "a1", timeline_start = 0, duration = 200},
    {id = "video_clip", track_id = "v1", timeline_start = 100, duration = 50},
}
test_playhead = 120

execute_cmd("MarkClipExtent", {sequence_id = "seq1"})
s = reload_seq()
check("video wins: mark_in = 100", s.mark_in == 100)
check("video wins: mark_out = 150", s.mark_out == 150)  -- 100+50-1=149, stored 150

-- ── Test 4: Playhead exactly at clip boundary (inclusive end) ──
print("\n--- Playhead at clip end boundary ---")
execute_cmd("ClearMarks", {sequence_id = "seq1"})
test_clips = {
    {id = "clip1", track_id = "v1", timeline_start = 0, duration = 100},
}
test_playhead = 100  -- clip_end = 0+100 = 100, condition is playhead <= clip_end

execute_cmd("MarkClipExtent", {sequence_id = "seq1"})
s = reload_seq()
check("boundary: mark_in = 0", s.mark_in == 0)
check("boundary: mark_out = 100", s.mark_out == 100)  -- last_frame=99, stored 100

-- ── Test 5: Non-trivial values (DRP-scale) ──
print("\n--- DRP-scale values ---")
execute_cmd("ClearMarks", {sequence_id = "seq1"})
test_clips = {
    {id = "drp_clip", track_id = "v1", timeline_start = 89849, duration = 12345},
}
test_playhead = 90000

execute_cmd("MarkClipExtent", {sequence_id = "seq1"})
s = reload_seq()
check("drp: mark_in = 89849", s.mark_in == 89849)
-- last_frame = 89849+12345-1 = 102193, stored 102194
check("drp: mark_out = 102194", s.mark_out == 102194)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_mark_clip_extent_command.lua passed")
