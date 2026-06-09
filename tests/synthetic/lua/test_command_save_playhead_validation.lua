#!/usr/bin/env luajit

-- Regression: B1 — Command.save must not crash when playhead_value is nil or
-- playhead_rate is missing/invalid. command_manager must assert at capture time
-- with actionable context instead of letting a bare nil propagate to Command:save().
--
-- H1 (#28) UPDATE: the original contract was "captured nil = bug, assert at
-- capture." H1 reframed this: project-level commands and tests using
-- init_project_only legitimately capture nil (no displayed timeline, no
-- sequence-scoped playhead exists). Command.save now accepts nil for both
-- playhead_value and playhead_rate as a pair — they're co-required. The
-- INVALID-TYPE cases (non-nil, non-number) still assert; the NIL cases now
-- succeed and persist NULL in the nullable columns.

local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local strip_holder = require("ui.timeline.state.strip_holder")
require("command") -- Loaded for side effects

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
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

-- Stub timeline_state methods that the command pipeline calls during execute
-- but which need no real timeline UI (selection / viewport / mutation
-- pipeline). Playhead + rate come from a real install_displayed_tab_stub
-- cache per test below — the capture_displayed_playhead invariant requires
-- them to track the actual strip_holder state, not be monkey-patched
-- in isolation.
local timeline_state = require("ui.timeline.timeline_state")

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

-- Helper: rollback any leaked transaction from a prior assert-in-execute
local function rollback_leaked_tx()
    pcall(function() database.rollback() end)
end

-- ─── Test 1: Valid integer playhead → command saves OK ───
-- Displayed tab present (real strip_holder stub), playhead=10, rate set.
-- Both invariants pass; command saves with non-nil pair.
print("\n--- valid integer playhead → save succeeds ---")
do
    test_env.install_displayed_tab_stub({
        playhead_position = 10,
        sequence_frame_rate = {fps_numerator = 24000, fps_denominator = 1001},
    })
    local result = command_manager.execute("TestStub", {project_id = "proj1"})
    check("valid integer playhead → success", result.success == true)
end

-- ─── Test 2: Valid numeric playhead at frame 0 → command saves OK ───
print("\n--- valid numeric playhead → save succeeds ---")
do
    test_env.install_displayed_tab_stub({
        playhead_position = 0,
        sequence_frame_rate = {fps_numerator = 24000, fps_denominator = 1001},
    })
    local result = command_manager.execute("TestStub", {project_id = "proj1"})
    check("valid numeric playhead → success", result.success == true)
end

-- ─── Test 3: no displayed tab → save succeeds with NULL pair ───
-- Post-H1 contract: with no displayed tab installed, get_playhead_position
-- and get_sequence_frame_rate both return nil. The command_manager capture
-- helper accepts the (nil, nil) pair as legitimate; Command.save persists
-- NULL columns. Undo treats nil as "leave playhead alone".
print("\n--- no displayed tab → save succeeds (project-level) ---")
do
    strip_holder.set(nil)   -- clear: no strip, no displayed cache
    local result = command_manager.execute("TestStub", {project_id = "proj1"})
    rollback_leaked_tx()
    check("no-tab playhead → success", result and result.success == true)
end

-- ─── Test 4: displayed tab with playhead but missing rate → assert ───
-- The two are co-required: had_displayed_tab=true must produce non-nil for
-- both value AND rate. A missing rate with a present tab is a bug — the
-- capture-site invariant must surface it loudly.
print("\n--- nil rate with non-nil playhead → assert ---")
do
    local cache = test_env.install_displayed_tab_stub({
        playhead_position = 0,
        sequence_frame_rate = {fps_numerator = 24000, fps_denominator = 1001},
    })
    cache.sequence_frame_rate = nil  -- force the bug shape

    local ok, err = pcall(function()
        command_manager.execute("TestStub", {project_id = "proj1"})
    end)
    rollback_leaked_tx()
    check("playhead-without-rate → error raised", not ok)
    check("error mentions rate", err and tostring(err):find("rate") ~= nil)
end

-- ─── Test 5: Invalid table playhead (not a number, not nil) → assert ───
-- Bypasses the invariant by writing a table into cache.playhead_position
-- directly; Command.save's type assert catches it.
print("\n--- invalid table playhead → assert at save ---")
do
    local cache = test_env.install_displayed_tab_stub({
        playhead_position = 0,
        sequence_frame_rate = {fps_numerator = 24000, fps_denominator = 1001},
    })
    cache.playhead_position = {fps_numerator = 24000, fps_denominator = 1001}  -- table, not integer

    local ok, err = pcall(function()
        command_manager.execute("TestStub", {project_id = "proj1"})
    end)
    rollback_leaked_tx()
    check("invalid table playhead → error raised", not ok)
    check("error mentions playhead", err and tostring(err):find("playhead") ~= nil)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_command_save_playhead_validation.lua passed")
