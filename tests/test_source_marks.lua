#!/usr/bin/env luajit

-- Test SourceViewer mark commands (SetMarkIn, SetMarkOut, GoToMarkIn, GoToMarkOut, ClearMarks)
-- These are non-undoable commands that operate on the source viewer's SequenceMonitor.

require('test_env')

print("=== test_source_marks.lua ===")

--------------------------------------------------------------------------------
-- Mock SequenceMonitor for source_monitor
--------------------------------------------------------------------------------

local mock_sv = {
    sequence_id = "masterclip_1",
    playhead = 0,
    _mark_in = nil,
    _mark_out = nil,
    _has_clip = true,
}

function mock_sv:has_clip() return self._has_clip end
function mock_sv:get_mark_in() return self._mark_in end
function mock_sv:get_mark_out() return self._mark_out end
function mock_sv:set_mark_in(frame) self._mark_in = frame end
function mock_sv:set_mark_out(frame) self._mark_out = frame end
function mock_sv:clear_marks() self._mark_in = nil; self._mark_out = nil end
function mock_sv:seek_to_frame(frame) self.playhead = frame end

local function reset_mock()
    mock_sv._mark_in = nil
    mock_sv._mark_out = nil
    mock_sv.playhead = 0
    mock_sv._has_clip = true
end

-- Mock panel_manager to return our mock_sv for "source_monitor"
package.loaded['ui.panel_manager'] = {
    get_sequence_monitor = function(view_id)
        assert(view_id == "source_monitor",
            "source_marks should request 'source_monitor', got: " .. tostring(view_id))
        return mock_sv
    end,
}

-- Load source_marks module and register executors
local source_marks = require('core.commands.source_marks')
local executors = {}
local undoers = {}
source_marks.register(executors, undoers, nil)

-- Helper: build a minimal command object with parameters
local function make_command(params)
    return {
        get_all_parameters = function() return params or {} end,
    }
end

local pass_count = 0
local fail_count = 0

local function check(label, condition, msg)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (msg and (" — " .. msg) or ""))
    end
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------
print("\n--- Registration ---")

check("SetMarkIn registered", type(executors["SourceViewerSetMarkIn"]) == "function")
check("SetMarkOut registered", type(executors["SourceViewerSetMarkOut"]) == "function")
check("GoToMarkIn registered", type(executors["SourceViewerGoToMarkIn"]) == "function")
check("GoToMarkOut registered", type(executors["SourceViewerGoToMarkOut"]) == "function")
check("ClearMarks registered", type(executors["SourceViewerClearMarks"]) == "function")

--------------------------------------------------------------------------------
-- SetMarkIn
--------------------------------------------------------------------------------
print("\n--- SetMarkIn ---")

-- Explicit frame
reset_mock()
local r = executors["SourceViewerSetMarkIn"](make_command({ frame = 42 }))
check("SetMarkIn explicit frame succeeds", r.success)
check("SetMarkIn sets correct frame", mock_sv._mark_in == 42,
    "expected 42, got " .. tostring(mock_sv._mark_in))

-- Defaults to playhead when no frame arg
reset_mock()
mock_sv.playhead = 77
r = executors["SourceViewerSetMarkIn"](make_command({}))
check("SetMarkIn defaults to playhead", r.success and mock_sv._mark_in == 77,
    "expected 77, got " .. tostring(mock_sv._mark_in))

-- No clip loaded
reset_mock()
mock_sv._has_clip = false
r = executors["SourceViewerSetMarkIn"](make_command({ frame = 10 }))
check("SetMarkIn no-clip returns failure", not r.success)
check("SetMarkIn no-clip error message", r.error_message and r.error_message:find("no clip loaded") ~= nil)

--------------------------------------------------------------------------------
-- SetMarkOut
--------------------------------------------------------------------------------
print("\n--- SetMarkOut ---")

reset_mock()
r = executors["SourceViewerSetMarkOut"](make_command({ frame = 99 }))
check("SetMarkOut explicit frame succeeds", r.success)
check("SetMarkOut sets correct frame", mock_sv._mark_out == 99,
    "expected 99, got " .. tostring(mock_sv._mark_out))

-- Defaults to playhead
reset_mock()
mock_sv.playhead = 55
r = executors["SourceViewerSetMarkOut"](make_command({}))
check("SetMarkOut defaults to playhead", r.success and mock_sv._mark_out == 55,
    "expected 55, got " .. tostring(mock_sv._mark_out))

-- No clip loaded
reset_mock()
mock_sv._has_clip = false
r = executors["SourceViewerSetMarkOut"](make_command({ frame = 10 }))
check("SetMarkOut no-clip returns failure", not r.success)

--------------------------------------------------------------------------------
-- GoToMarkIn
--------------------------------------------------------------------------------
print("\n--- GoToMarkIn ---")

-- Happy path: mark set, navigates to it
reset_mock()
mock_sv._mark_in = 30
r = executors["SourceViewerGoToMarkIn"](make_command())
check("GoToMarkIn succeeds", r.success)
check("GoToMarkIn seeks to mark_in", mock_sv.playhead == 30,
    "expected 30, got " .. tostring(mock_sv.playhead))

-- No mark set
reset_mock()
r = executors["SourceViewerGoToMarkIn"](make_command())
check("GoToMarkIn no-mark returns failure", not r.success)
check("GoToMarkIn no-mark error message", r.error_message and r.error_message:find("no mark in set") ~= nil)

-- No clip loaded
reset_mock()
mock_sv._has_clip = false
mock_sv._mark_in = 30
r = executors["SourceViewerGoToMarkIn"](make_command())
check("GoToMarkIn no-clip returns failure", not r.success)

--------------------------------------------------------------------------------
-- GoToMarkOut
--------------------------------------------------------------------------------
print("\n--- GoToMarkOut ---")

reset_mock()
mock_sv._mark_out = 200
r = executors["SourceViewerGoToMarkOut"](make_command())
check("GoToMarkOut succeeds", r.success)
check("GoToMarkOut seeks to mark_out", mock_sv.playhead == 200,
    "expected 200, got " .. tostring(mock_sv.playhead))

-- No mark set
reset_mock()
r = executors["SourceViewerGoToMarkOut"](make_command())
check("GoToMarkOut no-mark returns failure", not r.success)
check("GoToMarkOut no-mark error message", r.error_message and r.error_message:find("no mark out set") ~= nil)

-- No clip loaded
reset_mock()
mock_sv._has_clip = false
mock_sv._mark_out = 200
r = executors["SourceViewerGoToMarkOut"](make_command())
check("GoToMarkOut no-clip returns failure", not r.success)

--------------------------------------------------------------------------------
-- ClearMarks
--------------------------------------------------------------------------------
print("\n--- ClearMarks ---")

reset_mock()
mock_sv._mark_in = 10
mock_sv._mark_out = 90
r = executors["SourceViewerClearMarks"](make_command())
check("ClearMarks succeeds", r.success)
check("ClearMarks clears mark_in", mock_sv._mark_in == nil)
check("ClearMarks clears mark_out", mock_sv._mark_out == nil)

-- No clip loaded
reset_mock()
mock_sv._has_clip = false
r = executors["SourceViewerClearMarks"](make_command())
check("ClearMarks no-clip returns failure", not r.success)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_source_marks.lua passed")
