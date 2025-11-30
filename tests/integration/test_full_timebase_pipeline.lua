#!/usr/bin/env luajit
-- Full-Stack Integration Test: Timebase Pipeline
-- Verifies Command -> DB -> State flow using Rational time.

-- 1. Setup Environment
package.path = package.path .. ";src/lua/?.lua;./src/lua/?.lua"

local db = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Rational = require("core.rational")
local schema_sql = require("tests.import_schema")

print("=== Full-Stack Timebase Integration Test ===\n")

-- Test Stats
local passed = 0
local failed = 0
local current_test = ""

local function assert_true(cond, msg)
    if cond then
        print(string.format("  ✓ %s: %s", current_test, msg))
        passed = passed + 1
    else
        print(string.format("  ✗ %s: %s", current_test, msg))
        failed = failed + 1
    end
end

local function assert_rational_eq(actual, expected, msg)
    if actual == expected then
        print(string.format("  ✓ %s: %s (Frames: %d)", current_test, msg, actual.frames))
        passed = passed + 1
    else
        print(string.format("  ✗ %s: %s", current_test, msg))
        print(string.format("    Expected: %s", tostring(expected)))
        print(string.format("    Actual:   %s", tostring(actual)))
        failed = failed + 1
    end
end

-- 2. Initialize Database
print("Initializing In-Memory Database...")
local ok = db.set_path(":memory:")
if not ok then
    print("FATAL: Could not connect to memory DB")
    os.exit(1)
end
local db_conn = db.get_connection()
if not db_conn then
    print("FATAL: Could not retrieve DB connection")
    os.exit(1)
end

local ok, err = db_conn:exec(schema_sql)
if not ok then
    print("FATAL: Schema application failed: " .. tostring(err))
    os.exit(1)
end

-- Mock Qt timer bridge for timeline_state (notify_listeners)
_G.qt_create_single_shot_timer = function(delay, cb)
    cb() -- Execute immediately for tests
    return nil
end

-- 3. Scenarios

current_test = "Setup"
-- Create Project and Sequence
local proj_id = "test_project"
local seq_id = "test_sequence"
local fps_num = 24
local fps_den = 1

db_conn:exec(string.format([[ 
    INSERT INTO projects (id, name, created_at, modified_at) 
    VALUES ('%s', 'Test Project', 0, 0)
]], proj_id))

-- Sequence with 24fps
db_conn:exec(string.format([[ 
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, 
                           width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('%s', '%s', 'Sequence 1', 'timeline', %d, %d, 48000, 1920, 1080, 0, 0, 240, 0, 0)
]], seq_id, proj_id, fps_num, fps_den))
-- Tracks
db_conn:exec(string.format("INSERT INTO tracks (id, sequence_id, name, track_type, track_index) VALUES ('v1', '%s', 'V1', 'VIDEO', 1)", seq_id))

-- Initialize State
timeline_state.init(seq_id)
assert_true(timeline_state.get_sequence_id() == seq_id, "Timeline State initialized with sequence")
local rate = timeline_state.get_sequence_frame_rate()
assert_true(rate.fps_numerator == fps_num, "Frame rate loaded correctly")

-- Setup Command Manager
command_manager.init(db_conn)

current_test = "Insert Clip"
-- Create Media
local media_id = "media_1"
db_conn:exec(string.format([[ 
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, created_at, modified_at) 
    VALUES ('%s', '%s', 'Test Media', '/path/to/media', 100, 24, 1, 0, 0)
]], media_id, proj_id))
-- Execute Insert Command
-- We use the lower-level CreateClip / InsertClipToTimeline flow or just Insert command if refactored
-- Let's use "Insert" command if available, or build it.
-- "Insert" calls "InsertClipToTimeline"?
-- Let's use "CreateClip" to verify it handles Rational.

local Command = require("command")
local create_cmd = Command.create("CreateClip", proj_id)
create_cmd:set_parameter("track_id", "v1")
create_cmd:set_parameter("media_id", media_id)
create_cmd:set_parameter("start_value", Rational.new(24, fps_num, fps_den)) -- Start at 1s (24 frames)
create_cmd:set_parameter("duration", Rational.new(48, fps_num, fps_den)) -- 2s duration
create_cmd:set_parameter("sequence_id", seq_id)

local result = command_manager.execute(create_cmd)
if not result.success then
    print("DEBUG: CreateClip Error: " .. tostring(result.error_message))
end
assert_true(result.success, "CreateClip command executed successfully")
local clip_id = create_cmd:get_parameter("clip_id") -- Get ID from command object
if not clip_id then
    -- Fallback: try to parse result_data if it's the command JSON
    local json = require("dkjson")
    local ok, cmd_data = pcall(json.decode, result.result_data)
    if ok and cmd_data and cmd_data.parameters then
        clip_id = cmd_data.parameters.clip_id
    end
end
print("DEBUG: Created Clip ID: " .. tostring(clip_id))

-- Verify DB
local stmt = db_conn:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
stmt:bind_value(1, clip_id)
stmt:exec()
if stmt:next() then
    local db_start = stmt:value(0)
    local db_dur = stmt:value(1)
    
    -- Let's verify state first, which goes through model.
    timeline_state.reload_clips()
    local clips = timeline_state.get_clips()
    assert_true(#clips == 1, "State has 1 clip")
    local clip = clips[1]
    
    assert_rational_eq(clip.timeline_start, Rational.new(24, fps_num, fps_den), "Clip start is 24 frames")
    assert_rational_eq(clip.duration, Rational.new(48, fps_num, fps_den), "Clip duration is 48 frames")
    
    -- Check DB raw value
    print(string.format("    DB Raw: Start=%s, Dur=%s", tostring(db_start), tostring(db_dur)))
    
    -- Verify DB consistency
    assert_true(db_start == 24, "DB Start Frame is 24")
    assert_true(db_dur == 48, "DB Duration Frames is 48")
else
    assert_true(false, "Clip not found in DB")
end
stmt:finalize()

current_test = "Nudge Clip"
-- Execute Nudge Command
local nudge_cmd = Command.create("Nudge", proj_id)
nudge_cmd:set_parameter("sequence_id", seq_id)
nudge_cmd:set_parameter("selected_clip_ids", {clip_id})
-- Pass Rational delta for Nudge
local nudge_delta = Rational.new(24, fps_num, fps_den) -- +1s
print("TEST DEBUG: nudge_delta metatable:", tostring(getmetatable(nudge_delta)))
nudge_cmd:set_parameter("nudge_amount_rat", nudge_delta)
print("TEST DEBUG: cmd param metatable:", tostring(getmetatable(nudge_cmd:get_parameter("nudge_amount_rat"))))

local nudge_res = command_manager.execute(nudge_cmd)assert_true(nudge_res.success, "Nudge command executed")

-- Verify State update
timeline_state.reload_clips()
local clips_after = timeline_state.get_clips()
local clip_after = clips_after[1]

-- Expected: 24 frames (start) + 24 frames (1s nudge) = 48 frames
assert_rational_eq(clip_after.timeline_start, Rational.new(48, fps_num, fps_den), "Clip start moved to 48 frames")

current_test = "Ripple Edit (State Update)"
-- Simulate Ripple Edit logic (Command -> State)
-- We tested logic in isolated test, now test persistence roundtrip.
local ripple_cmd = Command.create("RippleEdit", proj_id)
ripple_cmd:set_parameter("sequence_id", seq_id)
ripple_cmd:set_parameter("edge_info", {clip_id = clip_id, edge_type = "out", track_id = "v1", trim_type = "ripple"})
ripple_cmd:set_parameter("delta_ms", 500) -- +500ms = +12 frames
-- Expected duration: 48 + 12 = 60 frames.

local rip_res = command_manager.execute(ripple_cmd)
assert_true(rip_res.success, "RippleEdit command executed")

timeline_state.reload_clips()
local clip_ripple = timeline_state.get_clips()[1]
assert_rational_eq(clip_ripple.duration, Rational.new(60, fps_num, fps_den), "Clip duration extended to 60 frames")


-- Final Report
print("\n=== Summary ===")
print(string.format("Passed: %d", passed))
print(string.format("Failed: %d", failed))

if failed == 0 then
    print("✅ SUCCESS")
    os.exit(0)
else
    print("❌ FAILURE")
    os.exit(1)
end