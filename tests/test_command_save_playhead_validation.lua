#!/usr/bin/env luajit

-- Regression: B1 — Command.save must not crash when playhead_value is nil or
-- playhead_rate is missing/invalid. command_manager must assert at capture time
-- with actionable context instead of letting a bare nil propagate to Command:save().

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

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

print("\n=== B1: Command.save playhead validation ===")

-- Set up DB
local db_path = "/tmp/jve/test_command_save_playhead_validation.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

-- Stub timeline_state with valid defaults
local timeline_state = require("ui.timeline.timeline_state")
local Rational = require("core.rational")

timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 1000}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.set_edge_selection = function(_) end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.reload_clips = function() end
timeline_state.get_sequence_audio_sample_rate = function() return 48000 end
timeline_state.clear_edge_selection = function() end
timeline_state.clear_gap_selection = function() end
timeline_state.apply_mutations = function() return false end

command_manager.init("seq1", "proj1")

-- Register a trivial stub command AFTER init (init wipes registry)
local registry = require("core.command_registry")
registry.register_executor("TestStub", function(_cmd)
    return true
end, function(_cmd)
    return true
end, {
    args = { project_id = { required = true } },
})

-- ─── Test 1: Valid playhead (Rational) → command saves OK ───
print("\n--- valid Rational playhead → save succeeds ---")
do
    timeline_state.get_playhead_position = function()
        return Rational.new(10, 24000, 1001)
    end
    timeline_state.get_sequence_frame_rate = function()
        return {fps_numerator = 24000, fps_denominator = 1001}
    end

    local result = command_manager.execute("TestStub", {project_id = "proj1"})
    check("valid Rational playhead → success", result.success == true)
end

-- ─── Test 2: Valid numeric playhead → command saves OK ───
print("\n--- valid numeric playhead → save succeeds ---")
do
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_sequence_frame_rate = function()
        return {fps_numerator = 24000, fps_denominator = 1001}
    end

    local result = command_manager.execute("TestStub", {project_id = "proj1"})
    check("valid numeric playhead → success", result.success == true)
end

-- Helper: rollback any leaked transaction from a prior assert-in-execute
local function rollback_leaked_tx()
    pcall(function() database.rollback() end)
end

-- ─── Test 3: nil playhead → early assert with context ───
print("\n--- nil playhead_value → assert at capture ---")
do
    timeline_state.get_playhead_position = function() return nil end
    timeline_state.get_sequence_frame_rate = function()
        return {fps_numerator = 24000, fps_denominator = 1001}
    end

    local ok, err = pcall(function()
        command_manager.execute("TestStub", {project_id = "proj1"})
    end)
    rollback_leaked_tx()
    check("nil playhead → error raised", not ok)
    check("error mentions playhead", err and tostring(err):find("playhead") ~= nil)
    check("error mentions command type", err and tostring(err):find("TestStub") ~= nil)
end

-- ─── Test 4: nil frame rate → early assert with context ───
print("\n--- nil playhead_rate → assert at capture ---")
do
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_sequence_frame_rate = function() return nil end

    local ok, err = pcall(function()
        command_manager.execute("TestStub", {project_id = "proj1"})
    end)
    rollback_leaked_tx()
    check("nil frame rate → error raised", not ok)
    check("error mentions rate", err and tostring(err):find("rate") ~= nil)
end

-- ─── Test 5: Rational with nil frames field → early assert ───
print("\n--- Rational missing .frames → assert at capture ---")
do
    timeline_state.get_playhead_position = function()
        return {fps_numerator = 24000, fps_denominator = 1001}  -- table but no .frames
    end
    timeline_state.get_sequence_frame_rate = function()
        return {fps_numerator = 24000, fps_denominator = 1001}
    end

    local ok, err = pcall(function()
        command_manager.execute("TestStub", {project_id = "proj1"})
    end)
    rollback_leaked_tx()
    check("Rational missing frames → error raised", not ok)
    check("error mentions playhead", err and tostring(err):find("playhead") ~= nil)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_command_save_playhead_validation.lua passed")
