#!/usr/bin/env luajit

-- Regression: B9 — TrimHead and TrimTail commands trim clip at playhead.
-- TrimHead: removes content before playhead (advances start + source_in).
-- TrimTail: removes content after playhead (shrinks duration + source_out).

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

local Rational = require("core.rational")
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

-- Clip store
local clip_store = {}

local function make_clip(id, start, dur, src_in, src_out, fps_num, fps_den)
    fps_num = fps_num or 24
    fps_den = fps_den or 1
    return {
        id = id,
        timeline_start = Rational.new(start, fps_num, fps_den),
        duration = Rational.new(dur, fps_num, fps_den),
        source_in = Rational.new(src_in, fps_num, fps_den),
        source_out = Rational.new(src_out, fps_num, fps_den),
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        save = function(self)
            clip_store[self.id] = {
                id = self.id,
                timeline_start = self.timeline_start,
                duration = self.duration,
                source_in = self.source_in,
                source_out = self.source_out,
                fps_numerator = self.fps_numerator,
                fps_denominator = self.fps_denominator,
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
            c.timeline_start.frames, c.duration.frames,
            c.source_in.frames, c.source_out.frames,
            c.fps_numerator, c.fps_denominator)
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

print("\n--- TrimHead: basic trim ---")
do
    -- Clip: start=10, dur=40, source_in=0, source_out=40
    -- Trim at frame 20 → removes 10 frames from head
    clip_store["c1"] = {
        id = "c1",
        timeline_start = Rational.new(10, 24, 1),
        duration = Rational.new(40, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(40, 24, 1),
        fps_numerator = 24, fps_denominator = 1,
    }

    local cmd = Command.create("TrimHead", "proj1")
    cmd:set_parameters({
        clip_id = "c1", project_id = "proj1", sequence_id = "seq1", trim_frame = 20,
    })

    local ok = executors["TrimHead"](cmd)
    check("TrimHead executes", ok == true)

    local c = clip_store["c1"]
    check("timeline_start = 20", c.timeline_start.frames == 20)
    check("duration = 30", c.duration.frames == 30)
    check("source_in = 10", c.source_in.frames == 10)
    check("source_out unchanged = 40", c.source_out.frames == 40)
end

print("\n--- TrimHead: undo restores original ---")
do
    local undo_cmd = Command.create("TrimHead", "proj1")
    undo_cmd:set_parameters({
        clip_id = "c1", project_id = "proj1", sequence_id = "seq1", trim_frame = 20,
        original_timeline_start = Rational.new(10, 24, 1),
        original_duration = Rational.new(40, 24, 1),
        original_source_in = Rational.new(0, 24, 1),
        original_source_out = Rational.new(40, 24, 1),
    })
    local ok = undoers["TrimHead"](undo_cmd)
    check("TrimHead undo executes", ok == true)

    local c = clip_store["c1"]
    check("undo: start = 10", c.timeline_start.frames == 10)
    check("undo: duration = 40", c.duration.frames == 40)
    check("undo: source_in = 0", c.source_in.frames == 0)
end

print("\n--- TrimHead: playhead outside clip → fails ---")
do
    clip_store["c2"] = {
        id = "c2",
        timeline_start = Rational.new(10, 24, 1),
        duration = Rational.new(40, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(40, 24, 1),
        fps_numerator = 24, fps_denominator = 1,
    }

    local cmd = Command.create("TrimHead", "proj1")
    cmd:set_parameters({
        clip_id = "c2", project_id = "proj1", sequence_id = "seq1", trim_frame = 5,
    })

    local ok = executors["TrimHead"](cmd)
    check("TrimHead outside clip → false", ok == false)
end

-- ═══════════════════════════════════════════════════════════
-- TrimTail tests
-- ═══════════════════════════════════════════════════════════

print("\n--- TrimTail: basic trim ---")
do
    -- Clip: start=10, dur=40, source_in=0, source_out=40
    -- Trim at frame 30 → removes 20 frames from tail
    clip_store["c3"] = {
        id = "c3",
        timeline_start = Rational.new(10, 24, 1),
        duration = Rational.new(40, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(40, 24, 1),
        fps_numerator = 24, fps_denominator = 1,
    }

    local cmd = Command.create("TrimTail", "proj1")
    cmd:set_parameters({
        clip_id = "c3", project_id = "proj1", sequence_id = "seq1", trim_frame = 30,
    })

    local ok = executors["TrimTail"](cmd)
    check("TrimTail executes", ok == true)

    local c = clip_store["c3"]
    check("timeline_start unchanged = 10", c.timeline_start.frames == 10)
    check("duration = 20", c.duration.frames == 20)
    check("source_in unchanged = 0", c.source_in.frames == 0)
    check("source_out = 20", c.source_out.frames == 20)
end

print("\n--- TrimTail: undo restores original ---")
do
    local undo_cmd = Command.create("TrimTail", "proj1")
    undo_cmd:set_parameters({
        clip_id = "c3", project_id = "proj1", sequence_id = "seq1", trim_frame = 30,
        original_timeline_start = Rational.new(10, 24, 1),
        original_duration = Rational.new(40, 24, 1),
        original_source_in = Rational.new(0, 24, 1),
        original_source_out = Rational.new(40, 24, 1),
    })
    local ok = undoers["TrimTail"](undo_cmd)
    check("TrimTail undo executes", ok == true)

    local c = clip_store["c3"]
    check("undo: duration = 40", c.duration.frames == 40)
    check("undo: source_out = 40", c.source_out.frames == 40)
end

print("\n--- TrimTail: playhead outside clip → fails ---")
do
    clip_store["c4"] = {
        id = "c4",
        timeline_start = Rational.new(10, 24, 1),
        duration = Rational.new(40, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(40, 24, 1),
        fps_numerator = 24, fps_denominator = 1,
    }

    local cmd = Command.create("TrimTail", "proj1")
    cmd:set_parameters({
        clip_id = "c4", project_id = "proj1", sequence_id = "seq1", trim_frame = 60,
    })

    local ok = executors["TrimTail"](cmd)
    check("TrimTail outside clip → false", ok == false)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_trim_head_tail.lua passed")
