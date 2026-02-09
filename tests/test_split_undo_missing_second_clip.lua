#!/usr/bin/env luajit

-- Regression: B8 — SplitClip undo must succeed even when second clip
-- is already absent (e.g., from cascading delete or failed save).

require("test_env")

print("\n=== B8: SplitClip undo with missing second clip ===")

local Rational = require("core.rational")

-- Stub command_helper
package.loaded["core.command_helper"] = {
    add_delete_mutation = function() end,
    add_update_mutation = function() end,
    clip_update_payload = function() return nil end,
    capture_clip_state = function() return {} end,
}

-- Track which clips exist and their state
local clip_store = {}
local deleted_clips = {}

package.loaded["models.clip"] = {
    load = function(id)
        local c = clip_store[id]
        if not c then return nil end
        return {
            id = c.id,
            timeline_start = c.timeline_start,
            duration = c.duration,
            source_in = c.source_in,
            source_out = c.source_out,
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
            delete = function(self)
                clip_store[self.id] = nil
                table.insert(deleted_clips, self.id)
                return true
            end,
        }
    end,
}

-- Load split_clip
local executors = {}
local undoers = {}
local split_clip = require("core.commands.split_clip")
split_clip.register(executors, undoers, nil, function() end)

-- Set up: original clip exists, second clip does NOT
clip_store["clip_orig"] = {
    id = "clip_orig",
    timeline_start = 10,
    duration = 20,  -- post-split: shortened
    source_in = 0,
    source_out = 20,
}
-- second clip is MISSING (already deleted)

local Command = require("command")
local cmd = Command.create("SplitClip", "proj1")
cmd:set_parameters({
    clip_id = "clip_orig",
    second_clip_id = "clip_second",
    sequence_id = "seq1",
    original_timeline_start = 0,
    original_duration = 50,
    original_source_in = 0,
    original_source_out = 50,
})

-- Undo split: should succeed even though second clip is absent
local result = undoers["SplitClip"](cmd)
assert(result == true,
    string.format("SplitClip undo should succeed with absent second clip, got %s", tostring(result)))

-- Verify original clip restored to pre-split dimensions
local restored = clip_store["clip_orig"]
assert(restored, "Original clip should still exist")
assert(restored.duration == 50,
    string.format("Original duration should be 50, got %s",
        tostring(restored.duration)))
assert(restored.timeline_start == 0,
    string.format("Original timeline_start should be 0, got %s",
        tostring(restored.timeline_start)))

print("✅ test_split_undo_missing_second_clip.lua passed")
