#!/usr/bin/env luajit

-- ExtendEdit command tests: extends selected edge(s) to meet the playhead.
-- Delegates to RippleEdit/BatchRippleEdit with computed delta.
-- Honors trim_type (ripple vs roll).

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

print("\n=== ExtendEdit command tests ===")

local Command = require("command")

-- Track RippleEdit/BatchRippleEdit calls
local ripple_calls = {}

-- Stub command_manager.execute to capture delegation
package.loaded["core.command_manager"] = {
    execute = function(cmd_type, params)
        if cmd_type == "RippleEdit" or cmd_type == "BatchRippleEdit" then
            table.insert(ripple_calls, {
                cmd_type = cmd_type,
                params = params,
            })
            return { success = true }
        end
        error("Unexpected command: " .. tostring(cmd_type))
    end,
}

-- Clip store
local clip_store = {}

-- All coordinates are integer frames
local function make_clip(id, start, dur, src_in, src_out, track_id)
    return {
        id = id,
        timeline_start = start,
        duration = dur,
        source_in = src_in,
        source_out = src_out,
        track_id = track_id or "track1",
    }
end

package.loaded["models.clip"] = {
    load = function(id)
        local c = clip_store[id]
        if not c then return nil end
        return make_clip(c.id, c.timeline_start, c.duration, c.source_in, c.source_out, c.track_id)
    end,
}

package.loaded["core.database"] = {}

-- Register command
local executors = {}
local undoers = {}
local last_error
require("core.commands.extend_edit").register(executors, undoers, nil, function(msg) last_error = msg end)

-- ═══════════════════════════════════════════════════════════
-- Test: Extend out-point to playhead (ripple)
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: extend out-point forward (ripple) ---")
do
    ripple_calls = {}
    last_error = nil
    -- Clip: [0..100), out-point at 100, playhead at 150
    -- Expected delta = 150 - 100 = +50
    clip_store["c1"] = {
        id = "c1",
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t1",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "c1",
            edge_type = "out",
            track_id = "t1",
            trim_type = "ripple",
        }},
        playhead_frame = 150,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend out ripple: executor returns true", ok == true)
    check("extend out ripple: no error", last_error == nil)
    check("extend out ripple: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend out ripple: delta_frames = 50", ripple_calls[1].params.delta_frames == 50)
        check("extend out ripple: edge_type = out", ripple_calls[1].params.edge_info.edge_type == "out")
        check("extend out ripple: trim_type = ripple", ripple_calls[1].params.edge_info.trim_type == "ripple")
    end
end

-- ═══════════════════════════════════════════════════════════
-- Test: Extend in-point to playhead (ripple)
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: extend in-point backward (ripple) ---")
do
    ripple_calls = {}
    -- Clip: [100..200), in-point at 100, playhead at 50
    -- Expected delta = 50 - 100 = -50 (move in-point left)
    clip_store["c2"] = {
        id = "c2",
        timeline_start = 100,
        duration = 100,
        source_in = 20,
        source_out = 120,
        track_id = "t1",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "c2",
            edge_type = "in",
            track_id = "t1",
            trim_type = "ripple",
        }},
        playhead_frame = 50,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend in ripple: executor returns true", ok == true)
    check("extend in ripple: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend in ripple: delta_frames = -50", ripple_calls[1].params.delta_frames == -50)
        check("extend in ripple: edge_type = in", ripple_calls[1].params.edge_info.edge_type == "in")
    end
end

-- ═══════════════════════════════════════════════════════════
-- Test: Extend with roll trim_type
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: extend out-point (roll) ---")
do
    ripple_calls = {}
    clip_store["c3"] = {
        id = "c3",
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t1",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "c3",
            edge_type = "out",
            track_id = "t1",
            trim_type = "roll",  -- Roll, not ripple
        }},
        playhead_frame = 130,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend roll: executor returns true", ok == true)
    check("extend roll: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend roll: delta_frames = 30", ripple_calls[1].params.delta_frames == 30)
        check("extend roll: trim_type = roll preserved", ripple_calls[1].params.edge_info.trim_type == "roll")
    end
end

-- ═══════════════════════════════════════════════════════════
-- Test: Edge already at playhead (no-op)
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: edge at playhead (no-op) ---")
do
    ripple_calls = {}
    clip_store["c4"] = {
        id = "c4",
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t1",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "c4",
            edge_type = "out",
            track_id = "t1",
        }},
        playhead_frame = 100,  -- Exactly at out-point
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("no-op: executor returns true", ok == true)
    check("no-op: RippleEdit NOT called", #ripple_calls == 0)
end

-- ═══════════════════════════════════════════════════════════
-- Test: Multiple edges → BatchRippleEdit
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: multiple edges → BatchRippleEdit ---")
do
    ripple_calls = {}
    clip_store["c5"] = {
        id = "c5",
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t1",
    }
    clip_store["c6"] = {
        id = "c6",
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t2",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {
            { clip_id = "c5", edge_type = "out", track_id = "t1" },
            { clip_id = "c6", edge_type = "out", track_id = "t2" },
        },
        playhead_frame = 150,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("multi-edge: executor returns true", ok == true)
    check("multi-edge: BatchRippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("multi-edge: cmd_type = BatchRippleEdit", ripple_calls[1].cmd_type == "BatchRippleEdit")
        check("multi-edge: delta_frames = 50", ripple_calls[1].params.delta_frames == 50)
        check("multi-edge: 2 edge_infos passed", #ripple_calls[1].params.edge_infos == 2)
    end
end

-- ═══════════════════════════════════════════════════════════
-- Test: gap_before edge type
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: gap_before edge ---")
do
    ripple_calls = {}
    clip_store["c7"] = {
        id = "c7",
        timeline_start = 100,
        duration = 50,
        source_in = 0,
        source_out = 50,
        track_id = "t1",
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "c7",
            edge_type = "gap_before",
            track_id = "t1",
        }},
        playhead_frame = 80,  -- gap_before uses timeline_start (100), delta = 80-100 = -20
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("gap_before: executor returns true", ok == true)
    check("gap_before: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("gap_before: delta_frames = -20", ripple_calls[1].params.delta_frames == -20)
    end
end

-- ═══════════════════════════════════════════════════════════
-- Results
-- ═══════════════════════════════════════════════════════════

print(string.format("\n=== ExtendEdit: %d passed, %d failed ===", pass_count, fail_count))

if fail_count > 0 then
    os.exit(1)
end

print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_extend_edit.lua passed")
