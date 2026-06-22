#!/usr/bin/env luajit
-- Unit/integration: FR-001 JoinThroughEdit + JoinAllThroughEdits (spec 025).
--
-- DOMAIN RULE: a through-edit is an editorially-invisible cut — two adjacent
-- clips from the same source with contiguous source frames. Splitting a clip
-- PRODUCES one (two contiguous same-source halves), so split-then-join is an
-- identity on the surviving clip: the merged clip must be byte-for-byte the
-- original clip's range, and the right half must be gone. Undo must restore
-- both halves exactly (bounds AND markers). This is the NLE meaning of
-- "rejoin a through-edit", derived from the domain, not from the code.

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("synthetic.helpers.ripple_layout")
local Clip            = require("models.clip")
local ClipMarker      = require("models.clip_marker")

print("=== test_join_through_edit.lua ===")

local function bounds(id)
    local r = Clip.load_row(id)
    if not r then return nil end
    return {
        start    = r.sequence_start_frame,
        duration = r.duration_frames,
        src_in   = r.source_in_frame,
        src_out  = r.source_out_frame,
    }
end

local function same_bounds(a, b)
    return a and b and a.start == b.start and a.duration == b.duration
        and a.src_in == b.src_in and a.src_out == b.src_out
end

-- The flush right neighbor of `clip_id` on its track (the right half a split
-- just produced). Found by timeline adjacency, not by the command's internals.
local function flush_right_id(clip_id)
    local left = Clip.load_row(clip_id)
    local left_end = left.sequence_start_frame + left.duration_frames
    for _, row in ipairs(Clip.list_in_sequence(left.owner_sequence_id)) do
        if row.track_id == left.track_id
            and row.sequence_start_frame == left_end and row.id ~= clip_id then
            return row.id
        end
    end
    return nil
end

local function split(project_id, sequence_id, clip_id, frame)
    local r = command_manager.execute("SplitClip", {
        project_id = project_id, sequence_id = sequence_id,
        clip_id = clip_id, split_frame = frame,
    })
    assert(r.success, "SplitClip should succeed: " .. tostring(r.error_message))
end

-- ── Test A: split → JoinThroughEdit restores the original clip; undo/redo ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_join_te_a.db",
        clips = { v1_left = { master_layer_track_id = "track_v1" } } })
    local clip_id = layout.clips.v1_left.id
    local original = bounds(clip_id)
    assert(original.duration > 10, "fixture clip must be splittable")

    split(layout.project_id, layout.sequence_id, clip_id,
        original.start + math.floor(original.duration / 2))
    local right_id = flush_right_id(clip_id)
    assert(right_id, "split must produce a flush right half")
    local after_split = bounds(clip_id)
    assert(after_split.duration < original.duration, "left half is shorter after split")

    local jr = command_manager.execute("JoinThroughEdit", {
        project_id = layout.project_id, sequence_id = layout.sequence_id, clip_id = clip_id,
    })
    assert(jr.success, "JoinThroughEdit should succeed: " .. tostring(jr.error_message))
    assert(same_bounds(bounds(clip_id), original),
        "joined clip must reproduce the original (pre-split) range exactly")
    assert(bounds(right_id) == nil, "right half must be gone after join")
    print("  PASS: split → join reproduces the original clip; right half removed")

    local ur = command_manager.undo()
    assert(ur.success, "undo join: " .. tostring(ur.error_message))
    assert(same_bounds(bounds(clip_id), after_split), "undo restores the left half's split bounds")
    assert(bounds(right_id) ~= nil, "undo restores the right half")
    print("  PASS: undo restores both halves")

    local rr = command_manager.redo()
    assert(rr.success, "redo join: " .. tostring(rr.error_message))
    assert(same_bounds(bounds(clip_id), original), "redo re-joins to the original range")
    assert(bounds(right_id) == nil, "redo removes the right half again")
    print("  PASS: redo re-joins")

    layout:cleanup()
end

-- ── Test B: JoinAllThroughEdits collapses a 3-way chain in one undo step ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_join_te_b.db",
        clips = { v1_left = { master_layer_track_id = "track_v1" } } })
    local clip_id = layout.clips.v1_left.id
    local original = bounds(clip_id)

    -- Two splits → three contiguous same-source halves (A1|A2|B): a chain.
    split(layout.project_id, layout.sequence_id, clip_id,
        original.start + math.floor(original.duration / 2))
    split(layout.project_id, layout.sequence_id, clip_id,
        original.start + math.floor(original.duration / 4))
    local b_id = flush_right_id(clip_id)  -- A2 (or B) — some right neighbor exists
    assert(b_id, "chain fixture must have a right neighbor")

    local jr = command_manager.execute("JoinAllThroughEdits", {
        project_id = layout.project_id, sequence_id = layout.sequence_id,
    })
    assert(jr.success, "JoinAllThroughEdits should succeed: " .. tostring(jr.error_message))
    assert(same_bounds(bounds(clip_id), original),
        "join-all collapses the whole chain back to the original clip")
    assert(flush_right_id(clip_id) == nil, "no through-edit neighbor remains after join-all")
    print("  PASS: JoinAll collapses a 3-way chain to the original clip")

    local ur = command_manager.undo()
    assert(ur.success, "undo join-all: " .. tostring(ur.error_message))
    assert(not same_bounds(bounds(clip_id), original), "one undo step restores the whole chain")
    print("  PASS: JoinAll is a single undo step")

    layout:cleanup()
end

-- ── Test C: right-clip markers move to the left clip (offset adjusted),
--            and return on undo ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_join_te_c.db",
        clips = { v1_left = { master_layer_track_id = "track_v1" } } })
    local clip_id = layout.clips.v1_left.id
    local original = bounds(clip_id)
    split(layout.project_id, layout.sequence_id, clip_id,
        original.start + math.floor(original.duration / 2))
    local right_id = flush_right_id(clip_id)
    local left_dur_before = bounds(clip_id).duration  -- the marker offset shift

    -- A point marker 5 frames into the RIGHT clip.
    ClipMarker.new({
        clip_id = right_id, frame = 5, duration = 1, color = "Red",
        name = "m", note = "", custom_data = "",
    }):save()

    command_manager.execute("JoinThroughEdit", {
        project_id = layout.project_id, sequence_id = layout.sequence_id, clip_id = clip_id,
    })
    local on_left = ClipMarker.find_by_clip(clip_id)
    assert(#on_left == 1, "the right clip's marker must move to the surviving left clip")
    assert(on_left[1].frame == 5 + left_dur_before, string.format(
        "marker offset must shift by the left clip's pre-join duration (%d): expected %d, got %d",
        left_dur_before, 5 + left_dur_before, on_left[1].frame))
    print("  PASS: marker reassigned to left clip with offset adjusted")

    command_manager.undo()
    local back = ClipMarker.find_by_clip(right_id)
    assert(#back == 1 and back[1].frame == 5,
        "undo returns the marker to the right clip at its original offset")
    assert(#ClipMarker.find_by_clip(clip_id) == 0, "left clip keeps none of the right's markers after undo")
    print("  PASS: undo returns the marker to the right clip")

    layout:cleanup()
end

-- ── Test D: a clip with no flush right neighbor is not an edit point → refuse ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_join_te_d.db" })
    local rightmost = layout.clips.v1_right.id  -- last clip on the track
    assert(flush_right_id(rightmost) == nil, "fixture: rightmost clip has no right neighbor")
    local jr = command_manager.execute("JoinThroughEdit", {
        project_id = layout.project_id, sequence_id = layout.sequence_id, clip_id = rightmost,
    })
    assert(not jr.success, "JoinThroughEdit on a clip with no flush right neighbor must refuse")
    print("  PASS: refuses a non-edit-point (no flush right neighbor)")
    layout:cleanup()
end

print("✅ test_join_through_edit.lua passed")
