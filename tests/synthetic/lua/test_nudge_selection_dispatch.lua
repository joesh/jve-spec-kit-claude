#!/usr/bin/env luajit

-- NudgeSelection routing tests.
--
-- Domain behavior, expressed without naming internals:
--   * If only edges are selected, pressing a nudge key trims the edges
--     uniformly by direction*magnitude frames (ripple semantics — the
--     downstream block shifts).
--   * If only clips are selected, pressing a nudge key moves the clips
--     uniformly by direction*magnitude frames.
--   * Empty selection is a silent no-op.
--   * Edges win over clips when both happen to be selected (matches the
--     prior keyboard-layer behavior that callers depended on).
--
-- We stub command_manager.execute to capture the routed command and
-- params. timeline_state is also stubbed so we can drive the selection.

require("test_env")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== NudgeSelection: dispatch routing ===")

local Command = require("command")

-- Stubs ---------------------------------------------------------------

local routed = {}
package.loaded["core.command_manager"] = {
    execute = function(cmd_type, params)
        table.insert(routed, { cmd_type = cmd_type, params = params })
        return { success = true }
    end,
}

local stub_state = {
    selected_edges = {},
    selected_clips = {},
    clips = {},
}

package.loaded["ui.timeline.timeline_state"] = {
    get_selected_edges = function() return stub_state.selected_edges end,
    get_selected_clips = function() return stub_state.selected_clips end,
    -- 022/1.3c: src reads clips via strip.
    get_tab_strip = function()
        return require("test_env").make_strip_stub({ displayed_clips = stub_state.clips })
    end,
}

-- Register the executor under test.
local executors = {}
local undoers = {}
require("core.commands.nudge_selection").register(executors, undoers, nil, function() end)

local function reset()
    routed = {}
    stub_state.selected_edges = {}
    stub_state.selected_clips = {}
    stub_state.clips = {}
end

local function run(direction, magnitude)
    local cmd = Command.create("NudgeSelection", "p1")
    cmd:set_parameters({
        direction = direction,
        magnitude = magnitude,
        project_id = "p1",
        sequence_id = "s1",
    })
    return executors["NudgeSelection"](cmd)
end

-- Tests ---------------------------------------------------------------

print("\n--- Edge selection routes to ripple trim ---")
do
    reset()
    stub_state.clips = { { id = "clipA", track_id = "trackA" } }
    stub_state.selected_edges = {
        { clip_id = "clipA", edge_type = "out", trim_type = "ripple" },
    }

    local ok = run(1, 5)
    check("returns true", ok == true)
    check("routes one command", #routed == 1)
    if #routed > 0 then
        check("routes to ripple trim", routed[1].cmd_type == "BatchRippleEdit")
        check("delta = direction*magnitude (+5)", routed[1].params.delta_frames == 5)
        check("forwards a single edge_info", #routed[1].params.edge_infos == 1)
        local ei = routed[1].params.edge_infos[1]
        check("edge_info carries clip_id", ei.clip_id == "clipA")
        check("edge_info joined track_id from clip", ei.track_id == "trackA")
        check("edge_info preserves edge_type", ei.edge_type == "out")
        check("edge_info preserves trim_type", ei.trim_type == "ripple")
    end
end

print("\n--- Clip selection routes to clip nudge ---")
do
    reset()
    stub_state.selected_clips = { { id = "clipB" }, { id = "clipC" } }

    local ok = run(-1, 5)
    check("returns true", ok == true)
    check("routes one command", #routed == 1)
    if #routed > 0 then
        check("routes to clip nudge", routed[1].cmd_type == "Nudge")
        check("delta is negative for direction=-1", routed[1].params.nudge_amount == -5)
        check("forwards both clip ids", #routed[1].params.selected_clip_ids == 2)
    end
end

print("\n--- Magnitude is configurable per binding ---")
do
    reset()
    stub_state.selected_clips = { { id = "clipD" } }
    run(1, 1)
    check("magnitude=1 produces delta=+1", routed[1].params.nudge_amount == 1)

    reset()
    stub_state.selected_clips = { { id = "clipD" } }
    run(1, 5)
    check("magnitude=5 produces delta=+5", routed[1].params.nudge_amount == 5)
end

print("\n--- Empty selection is a silent no-op ---")
do
    reset()
    local ok = run(1, 1)
    check("returns true", ok == true)
    check("dispatches nothing", #routed == 0)
end

print("\n--- Edges win over clips when both are selected ---")
do
    reset()
    stub_state.clips = { { id = "clipE", track_id = "trackE" } }
    stub_state.selected_edges = {
        { clip_id = "clipE", edge_type = "in", trim_type = "ripple" },
    }
    stub_state.selected_clips = { { id = "clipE" } }

    run(1, 1)
    check("only one routed command", #routed == 1)
    check("edges took priority", routed[1].cmd_type == "BatchRippleEdit")
end

print("\n--- Asserts on bad direction / magnitude ---")
do
    reset()
    local ok = pcall(function() return run(2, 1) end)
    check("rejects direction=2", ok == false)

    reset()
    ok = pcall(function() return run(1, 0) end)
    check("rejects magnitude=0", ok == false)

    reset()
    ok = pcall(function() return run(1, -3) end)
    check("rejects negative magnitude", ok == false)
end

print("\n--- Stale selection (edge points at non-existent clip) asserts ---")
do
    -- Domain rule: the timeline's selection model is the authoritative
    -- source of truth. If the selection contains an edge whose clip is
    -- not on the timeline, something elsewhere has corrupted state —
    -- silently dropping the edge would let that bug accumulate. Crash
    -- fast with the offending clip_id so the upstream cause is fixable.
    reset()
    stub_state.clips = { { id = "ghost_other", track_id = "trackZ" } }
    stub_state.selected_edges = {
        { clip_id = "missing_from_timeline", edge_type = "out", trim_type = "ripple" },
    }

    local ok, err = pcall(function() return run(1, 1) end)
    check("rejects edge whose clip is missing from timeline", ok == false)
    check("error names the offending clip_id",
        type(err) == "string" and err:find("missing_from_timeline", 1, true) ~= nil)
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_nudge_selection_dispatch.lua passed")
