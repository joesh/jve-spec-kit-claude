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
        sequence_start = start,
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
        -- For gap clips, return the clip directly (no source normalization)
        if c.clip_kind == "gap" then
            return c
        end
        return make_clip(c.id, c.sequence_start, c.duration, c.source_in, c.source_out, c.track_id)
    end,
    load_optional = function(id)
        local c = clip_store[id]
        if not c then return nil end
        if c.clip_kind == "gap" then
            return c
        end
        return make_clip(c.id, c.sequence_start, c.duration, c.source_in, c.source_out, c.track_id)
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
        sequence_start = 0,
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
        playhead = 150,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend out ripple: executor returns true", ok == true)
    check("extend out ripple: no error", last_error == nil)
    check("extend out ripple: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend out ripple: delta_frames = 50", ripple_calls[1].params.delta_frames == 50)
        check("extend out ripple: edge_type = out", (ripple_calls[1].params.edge_info or ripple_calls[1].params.edge_infos[1]).edge_type == "out")
        check("extend out ripple: trim_type = ripple", (ripple_calls[1].params.edge_info or ripple_calls[1].params.edge_infos[1]).trim_type == "ripple")
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
        sequence_start = 100,
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
        playhead = 50,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend in ripple: executor returns true", ok == true)
    check("extend in ripple: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend in ripple: delta_frames = -50", ripple_calls[1].params.delta_frames == -50)
        check("extend in ripple: edge_type = in", (ripple_calls[1].params.edge_info or ripple_calls[1].params.edge_infos[1]).edge_type == "in")
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
        sequence_start = 0,
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
        playhead = 130,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("extend roll: executor returns true", ok == true)
    check("extend roll: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("extend roll: delta_frames = 30", ripple_calls[1].params.delta_frames == 30)
        check("extend roll: trim_type = roll preserved", (ripple_calls[1].params.edge_info or ripple_calls[1].params.edge_infos[1]).trim_type == "roll")
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
        sequence_start = 0,
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
        playhead = 100,  -- Exactly at out-point
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
        sequence_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "t1",
    }
    clip_store["c6"] = {
        id = "c6",
        sequence_start = 0,
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
        playhead = 150,
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
-- Test: gap clip out edge (replaces old gap_before test)
-- ═══════════════════════════════════════════════════════════

print("\n--- ExtendEdit: gap clip out edge ---")
do
    ripple_calls = {}
    -- Gap clip at [50, 100), out edge at 100. Playhead at 80.
    -- delta = 80 - 100 = -20 (shrink gap from the right)
    local gap_clip = {
        id = "gap_t1_50",
        sequence_start = 50,
        duration = 50,
        clip_kind = "gap",
        track_id = "t1",
        source_in = nil,
        source_out = nil,
        frame_rate = { fps_numerator = 24, fps_denominator = 1 },
        fps_numerator = 24,
        fps_denominator = 1,
    }
    clip_store["gap_t1_50"] = gap_clip
    -- Gap clips resolve via timeline_state.get_clip_by_id per the 005
    -- gap-as-clip refactor; ExtendEdit reaches there for gap_* ids.
    package.loaded["ui.timeline.timeline_state"] = {
        get_clip_by_id = function(id) return id == "gap_t1_50" and gap_clip or nil end,
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        edge_infos = {{
            clip_id = "gap_t1_50",
            edge_type = "out",
            track_id = "t1",
        }},
        playhead = 80,  -- out edge at 100, delta = 80-100 = -20
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("gap out: executor returns true", ok == true)
    check("gap out: RippleEdit called", #ripple_calls == 1)

    if #ripple_calls > 0 then
        check("gap out: delta_frames = -20", ripple_calls[1].params.delta_frames == -20)
    end
end

-- ═══════════════════════════════════════════════════════════
-- Test: edge_infos absent → gather from active timeline selection
-- ═══════════════════════════════════════════════════════════
--
-- ExtendEdit is bound directly from TOML (`E = ExtendEdit @timeline`),
-- so the keyboard layer no longer assembles edge_infos for it. The
-- command must read selection itself when the caller doesn't pass
-- edge_infos. Behaviour parity with the explicit-edge_infos path:
-- same delta computation, same delegation to BatchRippleEdit.

print("\n--- ExtendEdit: gathers edge_infos from selection ---")
do
    ripple_calls = {}
    clip_store["c_sel"] = {
        id = "c_sel",
        sequence_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        track_id = "trackA",
    }

    package.loaded["ui.timeline.timeline_state"] = {
        get_selected_edges = function()
            return {{ clip_id = "c_sel", edge_type = "out", trim_type = "ripple" }}
        end,
        get_clips = function()
            return {{ id = "c_sel", track_id = "trackA" }}
        end,
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        playhead = 130,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("gather: executor returns true", ok == true)
    check("gather: BatchRippleEdit called", #ripple_calls == 1)
    if #ripple_calls > 0 then
        check("gather: delta_frames = 30", ripple_calls[1].params.delta_frames == 30)
        local ei = ripple_calls[1].params.edge_infos[1]
        check("gather: clip_id from selection", ei.clip_id == "c_sel")
        check("gather: track_id joined from clip", ei.track_id == "trackA")
        check("gather: edge_type preserved", ei.edge_type == "out")
        check("gather: trim_type preserved", ei.trim_type == "ripple")
    end
end

print("\n--- ExtendEdit: stale selection (edge clip missing) asserts ---")
do
    -- See the matching test in test_nudge_selection_dispatch.lua. The
    -- selection model and the timeline clip set must agree; a mismatch
    -- is a bug somewhere upstream and silently dropping it would mask
    -- that bug. Surface it loudly with the offending clip_id.
    package.loaded["ui.timeline.timeline_state"] = {
        get_selected_edges = function()
            return {{ clip_id = "ghost_clip", edge_type = "out", trim_type = "ripple" }}
        end,
        get_clips = function() return {} end,
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        playhead = 100,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok, err = pcall(function() return executors["ExtendEdit"](cmd) end)
    check("stale selection: executor asserts", ok == false)
    check("stale selection: error mentions clip_id",
        type(err) == "string" and err:find("ghost_clip", 1, true) ~= nil)
end

print("\n--- ExtendEdit: empty selection is a no-op ---")
do
    ripple_calls = {}
    package.loaded["ui.timeline.timeline_state"] = {
        get_selected_edges = function() return {} end,
        get_clips = function() return {} end,
    }

    local cmd = Command.create("ExtendEdit", "p1")
    cmd:set_parameters({
        playhead = 100,
        project_id = "p1",
        sequence_id = "s1",
    })

    local ok = executors["ExtendEdit"](cmd)
    check("empty selection: executor returns true", ok == true)
    check("empty selection: nothing dispatched", #ripple_calls == 0)
end

-- ═══════════════════════════════════════════════════════════
-- Results
-- ═══════════════════════════════════════════════════════════

print(string.format("\n=== ExtendEdit: %d passed, %d failed ===", pass_count, fail_count))

if fail_count > 0 then
    os.exit(1)
end

print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_extend_edit.lua passed")
