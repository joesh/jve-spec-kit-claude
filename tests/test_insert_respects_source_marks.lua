#!/usr/bin/env luajit

-- Regression: B6 — Insert/Overwrite must use source viewer in/out marks
-- when they are set, not the full media source_in/source_out range.

require("test_env")

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

print("\n=== B6: Insert respects source viewer marks ===")

require("command")

-- Stub dependencies
package.loaded["core.logger"] = {
    info = function() end, debug = function() end,
    warn = function() end, error = function() end,
    trace = function() end,
}

-- Capture what Insert/Overwrite command receives
local captured_params
local mock_cm = require("test_env").mock_command_manager()
mock_cm.execute = function(cmd_or_type, params)
    if type(cmd_or_type) == "table" and cmd_or_type.get_all_parameters then
        captured_params = cmd_or_type:get_all_parameters()
    elseif type(cmd_or_type) == "string" and params then
        captured_params = params
    end
    return { success = true }
end
mock_cm.begin_command_event = function() end
mock_cm.end_command_event = function() end

-- Mock source SequenceView (registered with panel_manager)
local _mock_mark_in = 10
local _mock_mark_out = 50
local mock_source_sv = {
    sequence_id = "master_1",  -- IS-a: masterclip IS a sequence
    total_frames = 100,
    fps_num = 24,
    fps_den = 1,
}
function mock_source_sv:has_clip() return self.sequence_id ~= nil end
function mock_source_sv:get_mark_in() return _mock_mark_in end
function mock_source_sv:get_mark_out() return _mock_mark_out end

local function set_mock_marks(mark_in, mark_out)
    _mock_mark_in = mark_in
    _mock_mark_out = mark_out
end
local function set_mock_sequence_id(id)
    mock_source_sv.sequence_id = id
end

local panel_manager = require("ui.panel_manager")
panel_manager.register_sequence_view("source_view", mock_source_sv)
panel_manager.register_sequence_view("timeline_view", mock_source_sv)

-- Mock focus_manager
package.loaded["core.focus_manager"] = {
    set_focused_panel = function() end,
    focus_panel = function() end,
}

-- Mock timeline_state
local mock_timeline_state = {
    get_sequence_id = function() return "seq1" end,
    get_project_id = function() return "proj1" end,
    get_playhead_position = function() return 0 end,
}

-- Mock timeline_panel
local mock_timeline_panel = {
    get_state = function() return mock_timeline_state end,
}

-- Load project_browser
local project_browser = require("ui.project_browser")
project_browser.timeline_panel = mock_timeline_panel

-- Create master clip with full source range (0-100)
-- Shape matches real data from database.load_master_clips: fps under clip.rate
-- and media.frame_rate, NOT flat on the object.
local master_clip = {
    clip_id = "master_1",
    project_id = "proj1",
    name = "TestMedia",
    media_id = "media_1",
    source_in = 0,
    source_out = 100,
    duration = 100,
    timeline_start = 0,
    rate = {fps_numerator = 24, fps_denominator = 1},
    media = {
        id = "media_1",
        duration_frames = 100,
        frame_rate = {fps_numerator = 24, fps_denominator = 1},
    },
}
project_browser.master_clip_map = { ["master_1"] = master_clip }
project_browser.media_map = { ["media_1"] = master_clip.media }
project_browser.selected_items = {{ type = "master_clip", clip_id = "master_1" }}

-- ─── Test 1: Insert with marks → clip uses mark range ───
print("\n--- insert with source marks → uses marks ---")
do
    captured_params = nil
    set_mock_sequence_id("master_1")
    set_mock_marks(10, 50)

    project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})

    assert(captured_params, "captured_params should be set")
    local si = captured_params.source_in
    local so = captured_params.source_out
    local si_frames = type(si) == "table" and si.frames or si
    local so_frames = type(so) == "table" and so.frames or so

    check("source_in = mark_in (10)", si_frames == 10)
    check("source_out = mark_out (50)", so_frames == 50)
end

-- ─── Test 2: Insert without marks → uses original source range ───
print("\n--- insert without marks → uses original range ---")
do
    captured_params = nil
    set_mock_sequence_id("master_1")
    set_mock_marks(nil, nil)

    project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})

    assert(captured_params, "captured_params should be set")
    -- When no marks, source_in/source_out are nil (command will use clip defaults)
    local si = captured_params.source_in
    local so = captured_params.source_out
    -- nil means use default from master clip, which is correct
    check("source_in = nil (use default)", si == nil)
    check("source_out = nil (use default)", so == nil)
end

-- ─── Test 3: Insert doesn't mutate the master clip object ───
print("\n--- insert doesn't mutate master_clip ---")
do
    set_mock_sequence_id("master_1")
    set_mock_marks(10, 50)

    project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})

    local orig_si = master_clip.source_in
    local orig_so = master_clip.source_out
    check("master_clip.source_in unchanged (0)", orig_si == 0)
    check("master_clip.source_out unchanged (100)", orig_so == 100)
end

-- ─── Test 4: Different clip in viewer → uses original range ───
print("\n--- different clip in viewer → original range ---")
do
    captured_params = nil
    set_mock_sequence_id("other_clip")  -- Not the selected master clip
    set_mock_marks(10, 50)

    project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})

    assert(captured_params, "captured_params should be set")
    -- Different clip in viewer → source_in/source_out nil (use master clip defaults)
    local si = captured_params.source_in
    check("different viewer clip → source_in nil (use default)", si == nil)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_insert_respects_source_marks.lua passed")
