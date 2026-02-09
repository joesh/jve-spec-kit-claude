#!/usr/bin/env luajit

-- Regression: B9 — TrimHead and TrimTail commands trim clips at playhead with ripple.
-- TrimHead: removes content before playhead (advances start + source_in), ripples downstream.
-- TrimTail: removes content after playhead (shrinks duration + source_out), ripples downstream.

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

print("\n=== B9: TrimHead / TrimTail commands ===")

local Command = require("command")

-- Stub command_helper
local mutations = {}
package.loaded["core.command_helper"] = {
    add_update_mutation = function(_, seq, payload)
        table.insert(mutations, {seq = seq, payload = payload})
    end,
    clip_update_payload = function(clip, seq)
        return {clip_id = clip.id, sequence_id = seq}
    end,
}

-- Stub command_manager.execute for RippleDelete
local ripple_calls = {}
package.loaded["core.command_manager"] = {
    execute = function(cmd_type, params)
        if cmd_type == "RippleDelete" then
            table.insert(ripple_calls, params)
            return { success = true }
        end
        error("Unexpected command: " .. tostring(cmd_type))
    end,
}

-- Clip store
local clip_store = {}

-- All coordinates are integer frames
local function make_clip(id, start, dur, src_in, src_out)
    return {
        id = id,
        timeline_start = start,  -- integer frames
        duration = dur,          -- integer frames
        source_in = src_in,      -- integer frames
        source_out = src_out,    -- integer frames
        save = function(self)
            clip_store[self.id] = {
                id = self.id,
                timeline_start = self.timeline_start,
                duration = self.duration,
                source_in = self.source_in,
                source_out = self.source_out,
            }
            return true
        end,
    }
end

package.loaded["models.clip"] = {
    load = function(id)
        local c = clip_store[id]
        if not c then return nil end
        return make_clip(c.id,
            c.timeline_start, c.duration,
            c.source_in, c.source_out)
    end,
}

-- Register commands
local executors = {}
local undoers = {}
require("core.commands.trim_head").register(executors, undoers, nil, function() end)
require("core.commands.trim_tail").register(executors, undoers, nil, function() end)

-- ═══════════════════════════════════════════════════════════
-- TrimHead tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimHead: basic trim with ripple ---")
do
    ripple_calls = {}
    -- Clip: start=10, dur=40, source_in=0, source_out=40 → frames [10..50)
    -- Trim at frame 20 → removes 10 frames from head, clip becomes [20..50)
    -- Then RippleDelete shifts it back to [10..40)
    clip_store["c1"] = {
        id = "c1",
        timeline_start = 10,
        duration = 40,
        source_in = 0,
        source_out = 40,
    }

    local cmd = Command.create("TrimHead", "proj1")
    cmd:set_parameters({
        clip_ids = {"c1"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 20,
    })

    local ok = executors["TrimHead"](cmd)
    check("TrimHead executes", ok == true)

    -- After trim (before ripple moves it back): clip at [20..50)
    local c = clip_store["c1"]
    check("timeline_start = 20", c.timeline_start == 20)
    check("duration = 30", c.duration == 30)
    check("source_in = 10", c.source_in == 10)
    check("source_out unchanged = 40", c.source_out == 40)

    -- Verify RippleDelete was called with correct gap (integer frames)
    check("RippleDelete called", #ripple_calls == 1)
    if #ripple_calls > 0 then
        check("gap_start = 10", ripple_calls[1].gap_start == 10)
        check("gap_duration = 10", ripple_calls[1].gap_duration == 10)
    end
end

print("\n--- TrimHead: undo restores original ---")
do
    local undo_cmd = Command.create("TrimHead", "proj1")
    undo_cmd:set_parameters({
        clip_ids = {"c1"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 20,
        original_states = {
            {
                clip_id = "c1",
                timeline_start = 10,
                duration = 40,
                source_in = 0,
                source_out = 40,
            }
        },
    })
    local ok = undoers["TrimHead"](undo_cmd)
    check("TrimHead undo executes", ok == true)

    local c = clip_store["c1"]
    check("undo: start = 10", c.timeline_start == 10)
    check("undo: duration = 40", c.duration == 40)
    check("undo: source_in = 0", c.source_in == 0)
end

print("\n--- TrimHead: playhead outside clip → fails ---")
do
    clip_store["c2"] = {
        id = "c2",
        timeline_start = 10,
        duration = 40,
        source_in = 0,
        source_out = 40,
    }

    local cmd = Command.create("TrimHead", "proj1")
    cmd:set_parameters({
        clip_ids = {"c2"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 5,
    })

    local ok = executors["TrimHead"](cmd)
    check("TrimHead outside clip → false", ok == false)
end

-- ═══════════════════════════════════════════════════════════
-- TrimTail tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimTail: basic trim with ripple ---")
do
    ripple_calls = {}
    -- Clip: start=10, dur=40, source_in=0, source_out=40 → frames [10..50)
    -- Trim at frame 30 → removes 20 frames from tail, clip becomes [10..30)
    -- Gap is [30..50), 20 frames
    clip_store["c3"] = {
        id = "c3",
        timeline_start = 10,
        duration = 40,
        source_in = 0,
        source_out = 40,
    }

    local cmd = Command.create("TrimTail", "proj1")
    cmd:set_parameters({
        clip_ids = {"c3"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 30,
    })

    local ok = executors["TrimTail"](cmd)
    check("TrimTail executes", ok == true)

    local c = clip_store["c3"]
    check("timeline_start unchanged = 10", c.timeline_start == 10)
    check("duration = 20", c.duration == 20)
    check("source_in unchanged = 0", c.source_in == 0)
    check("source_out = 20", c.source_out == 20)

    -- Verify RippleDelete was called with correct gap (integer frames)
    check("RippleDelete called", #ripple_calls == 1)
    if #ripple_calls > 0 then
        check("gap_start = 30", ripple_calls[1].gap_start == 30)
        check("gap_duration = 20", ripple_calls[1].gap_duration == 20)
    end
end

print("\n--- TrimTail: undo restores original ---")
do
    local undo_cmd = Command.create("TrimTail", "proj1")
    undo_cmd:set_parameters({
        clip_ids = {"c3"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 30,
        original_states = {
            {
                clip_id = "c3",
                timeline_start = 10,
                duration = 40,
                source_in = 0,
                source_out = 40,
            }
        },
    })
    local ok = undoers["TrimTail"](undo_cmd)
    check("TrimTail undo executes", ok == true)

    local c = clip_store["c3"]
    check("undo: duration = 40", c.duration == 40)
    check("undo: source_out = 40", c.source_out == 40)
end

print("\n--- TrimTail: playhead outside clip → fails ---")
do
    clip_store["c4"] = {
        id = "c4",
        timeline_start = 10,
        duration = 40,
        source_in = 0,
        source_out = 40,
    }

    local cmd = Command.create("TrimTail", "proj1")
    cmd:set_parameters({
        clip_ids = {"c4"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 60,
    })

    local ok = executors["TrimTail"](cmd)
    check("TrimTail outside clip → false", ok == false)
end

-- ═══════════════════════════════════════════════════════════
-- Multi-clip tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimHead: multiple clips at same position ---")
do
    ripple_calls = {}
    -- Two clips at same position on different tracks
    clip_store["m1"] = {
        id = "m1",
        timeline_start = 10,
        duration = 40,
        source_in = 0,
        source_out = 40,
    }
    clip_store["m2"] = {
        id = "m2",
        timeline_start = 10,
        duration = 40,
        source_in = 5,
        source_out = 45,
    }

    local cmd = Command.create("TrimHead", "proj1")
    cmd:set_parameters({
        clip_ids = {"m1", "m2"}, project_id = "proj1", sequence_id = "seq1", trim_frame = 20,
    })

    local ok = executors["TrimHead"](cmd)
    check("TrimHead multi executes", ok == true)

    -- Both clips trimmed
    check("m1 start = 20", clip_store["m1"].timeline_start == 20)
    check("m2 start = 20", clip_store["m2"].timeline_start == 20)

    -- Only ONE RippleDelete call for both clips
    check("RippleDelete called once", #ripple_calls == 1)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_trim_head_tail.lua passed")
