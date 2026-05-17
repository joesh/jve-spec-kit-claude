#!/usr/bin/env luajit

-- Regression: B8 — SplitClip undo must succeed even when second clip
-- is already absent (e.g., from cascading delete or failed save).

require("test_env")

print("\n=== B8: SplitClip undo with missing second clip ===")


-- V13 split_clip undoer uses Clip.delete_one / Clip.update_bounds /
-- Clip.load_v13_row plus database savepoints and Signals.emit. Stub
-- each surface so the test can run without a real DB.
package.loaded["core.command_helper"] = {
    add_delete_mutation = function() end,
    add_update_mutation = function() end,
    clip_update_payload = function() return nil end,
    capture_clip_state = function() return {} end,
}

local clip_store = {}
local deleted_clips = {}

package.loaded["models.clip"] = {
    delete_one = function(id)
        clip_store[id] = nil
        table.insert(deleted_clips, id)
        return true
    end,
    update_bounds = function(id, sequence_start, duration, source_in, source_out)
        local c = clip_store[id]
        if c then
            c.sequence_start_frame = sequence_start
            c.duration_frames = duration
            c.source_in_frame = source_in
            c.source_out_frame = source_out
        end
    end,
    load_v13_row = function(id)
        local c = clip_store[id]
        if not c then return nil end
        return {
            id = id,
            owner_sequence_id = c.owner_sequence_id or "seq1",
            track_id = c.track_id or "trk1",
            source_sequence_id = c.source_sequence_id or "master_x",
            sequence_start_frame = c.sequence_start_frame,
            duration_frames = c.duration_frames,
            source_in_frame = c.source_in_frame,
            source_out_frame = c.source_out_frame,
            fps_mismatch_policy = "resample",
            name = "clip", enabled = 1, volume = 1.0, playhead_frame = 0,
        }
    end,
}

package.loaded["core.database"] = {
    savepoint = function() return true end,
    release_savepoint = function() return true end,
    rollback_to_savepoint = function() return true end,
}

package.loaded["core.signals"] = { emit = function() end }

-- Load split_clip after stubs are in place.
local executors = {}
local undoers = {}
local split_clip = require("core.commands.split_clip")
split_clip.register(executors, undoers, nil, function() end)

-- Set up: original clip exists with post-split state; second clip is missing.
clip_store["clip_orig"] = {
    id = "clip_orig",
    sequence_start_frame = 10,
    duration_frames = 20,
    source_in_frame = 0,
    source_out_frame = 20,
}

local Command = require("command")
local cmd = Command.create("SplitClip", "proj1")
cmd:set_parameters({
    clip_id = "clip_orig",
    second_clip_id = "clip_second",
    sequence_id = "seq1",
    prior_state = {
        sequence_start_frame = 0,
        duration_frames      = 50,
        source_in_frame      = 0,
        source_out_frame     = 50,
    },
})

local result = undoers["SplitClip"](cmd)
assert(result == true,
    string.format("SplitClip undo should succeed with absent second clip, got %s", tostring(result)))

local restored = clip_store["clip_orig"]
assert(restored, "Original clip should still exist")
assert(restored.duration_frames == 50,
    string.format("Original duration should be 50, got %s",
        tostring(restored.duration_frames)))
assert(restored.sequence_start_frame == 0,
    string.format("Original sequence_start should be 0, got %s",
        tostring(restored.sequence_start_frame)))

print("✅ test_split_undo_missing_second_clip.lua passed")
