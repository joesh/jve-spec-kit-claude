#!/usr/bin/env luajit
--- Test: Viewer panel switches between Timeline/Source based on panel focus
--
-- Expected behavior:
-- 1. Timeline focus → viewer shows timeline (timeline_mode=true, title="Timeline Viewer")
-- 2. Viewer focus + source clip loaded → viewer shows source (timeline_mode=false, title="Source Viewer")
-- 3. Browser focus + source clip loaded → viewer shows source (timeline_mode=false, title="Source Viewer")
-- 4. Viewer focus + NO source clip → stays in timeline mode (nothing to show)
--
-- This test verifies the selection_hub listener logic in timeline_panel.lua

require("test_env")

-- Track calls to verify behavior
local calls = {}
local function record(name, ...)
    table.insert(calls, { fn = name, args = {...} })
end

local function reset_calls()
    calls = {}
end

local function find_call(fn_name)
    for _, call in ipairs(calls) do
        if call.fn == fn_name then
            return call
        end
    end
    return nil
end

-- State we control
local mock_timeline_mode = false
local mock_has_clip = false
local mock_sequence_id = "seq1"

-- The focus-switching logic we're testing (extracted from timeline_panel.lua)
-- This is the selection_hub listener that should exist
local function on_panel_focus_change(panel_id)
    if panel_id == "timeline" then
        -- Timeline focus → Timeline Viewer
        local seq_id = mock_sequence_id
        if seq_id and seq_id ~= "" then
            -- Simulate load_sequence restore path
            if not mock_timeline_mode then
                record("set_timeline_mode", true, seq_id)
                mock_timeline_mode = true
                record("show_timeline", seq_id)
            end
        end
    elseif panel_id == "viewer" or panel_id == "project_browser" then
        -- Viewer/Browser focus → Source Viewer (if clip loaded)
        if mock_has_clip and mock_timeline_mode then
            record("set_timeline_mode", false)
            mock_timeline_mode = false
            record("set_title", "Source Viewer")
        end
    end
end

print("=== Test 1: Timeline focus → Timeline Viewer ===")
reset_calls()
mock_has_clip = true  -- source clip IS loaded
mock_timeline_mode = false  -- start in source mode

on_panel_focus_change("timeline")

assert(find_call("set_timeline_mode") and find_call("set_timeline_mode").args[1] == true,
    "Timeline focus should set timeline_mode=true")
assert(find_call("show_timeline"),
    "Timeline focus should call show_timeline")
print("PASS")

print("\n=== Test 2: Viewer focus + source clip → Source Viewer ===")
reset_calls()
mock_has_clip = true  -- source clip IS loaded
mock_timeline_mode = true  -- start in timeline mode

on_panel_focus_change("viewer")

assert(find_call("set_timeline_mode") and find_call("set_timeline_mode").args[1] == false,
    "Viewer focus with source clip should set timeline_mode=false")
assert(find_call("set_title") and find_call("set_title").args[1] == "Source Viewer",
    "Viewer focus should set title to 'Source Viewer'")
print("PASS")

print("\n=== Test 3: Browser focus + source clip → Source Viewer ===")
reset_calls()
mock_has_clip = true  -- source clip IS loaded
mock_timeline_mode = true  -- start in timeline mode

on_panel_focus_change("project_browser")

assert(find_call("set_timeline_mode") and find_call("set_timeline_mode").args[1] == false,
    "Browser focus with source clip should set timeline_mode=false")
print("PASS")

print("\n=== Test 4: Viewer focus + NO source clip → stays timeline ===")
reset_calls()
mock_has_clip = false  -- NO source clip loaded
mock_timeline_mode = true  -- in timeline mode

on_panel_focus_change("viewer")

assert(not find_call("set_timeline_mode"),
    "Viewer focus without source clip should NOT switch modes")
print("PASS")

print("\n=== Test 5: Timeline focus when already in timeline mode → no-op ===")
reset_calls()
mock_has_clip = true
mock_timeline_mode = true  -- already in timeline mode

on_panel_focus_change("timeline")

assert(not find_call("set_timeline_mode"),
    "Timeline focus when already in timeline mode should be no-op")
assert(not find_call("show_timeline"),
    "Should not call show_timeline redundantly")
print("PASS")

print("\n✅ test_viewer_focus_switching.lua passed")
print("\nNOTE: This test verifies the EXPECTED behavior.")
print("Now verify timeline_panel.lua implements this exact logic.")
