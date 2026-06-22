#!/usr/bin/env luajit
-- FR-001 (spec 025): selecting an edit and pressing Delete removes the
-- through-edit by JOINING it — the FCP7/Premiere way to drop an invisible cut.
--
-- DOMAIN RULE: an edit point is selected as a roll (both sides of one cut).
-- When that cut is a through-edit (same source, contiguous frames), Delete
-- joins the pair into the single clip it was before the cut. When the cut is a
-- GENUINE edit (different source / a real frame gap), Delete on the roll does
-- NOT join — there is nothing editorially invisible to remove, so the clips
-- are left untouched. Black-box: drive the real DeleteSelection command with a
-- real roll selection; never reach into the command's internals.

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local focus_manager   = require("ui.focus_manager")
local Clip            = require("models.clip")
local ripple_layout   = require("synthetic.helpers.ripple_layout")

print("=== test_delete_joins_through_edit.lua ===")

local function bounds(id)
    local r = Clip.load_v13_row(id)
    if not r then return nil end
    return { start = r.sequence_start_frame, duration = r.duration_frames,
             src_in = r.source_in_frame, src_out = r.source_out_frame }
end

local function same_bounds(a, b)
    return a and b and a.start == b.start and a.duration == b.duration
        and a.src_in == b.src_in and a.src_out == b.src_out
end

-- The flush right neighbor of `clip_id` (the right half a split produced).
local function flush_right_id(clip_id)
    local left = Clip.load_v13_row(clip_id)
    local left_end = left.sequence_start_frame + left.duration_frames
    for _, row in ipairs(Clip.list_in_sequence(left.owner_sequence_id)) do
        if row.track_id == left.track_id
            and row.sequence_start_frame == left_end and row.id ~= clip_id then
            return row.id
        end
    end
end

local function roll_select(left_id, right_id, track_id)
    timeline_state.set_edge_selection({
        { clip_id = left_id,  edge_type = "out", track_id = track_id, trim_type = "roll" },
        { clip_id = right_id, edge_type = "in",  track_id = track_id, trim_type = "roll" },
    })
end

-- ── Test A: split makes a through-edit; roll-select it + Delete → joined ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_del_join_te.db",
        clips = { order = {"v1_left"}, v1_left = { sequence_start = 0, duration = 1000, source_in = 500 } } })
    layout:init_timeline_state()
    focus_manager.set_focused_panel("timeline")

    local clip_id = layout.clips.v1_left.id
    local track_id = layout.tracks.v1.id
    local original = bounds(clip_id)

    local sr = command_manager.execute("SplitClip", {
        project_id = layout.project_id, sequence_id = layout.sequence_id,
        clip_id = clip_id, split_frame = original.start + 400 })
    assert(sr.success, "SplitClip should succeed: " .. tostring(sr.error_message))
    local right_id = flush_right_id(clip_id)
    assert(right_id, "split must produce a flush right half")

    roll_select(clip_id, right_id, track_id)

    local dr = command_manager.execute("DeleteSelection",
        { project_id = layout.project_id, sequence_id = layout.sequence_id })
    assert(dr.success, "DeleteSelection should succeed: " .. tostring(dr.error_message))

    assert(same_bounds(bounds(clip_id), original),
        "Delete on a selected through-edit must join it back to the original clip")
    assert(bounds(right_id) == nil, "the right half must be gone after the join")
    print("  PASS: roll-select a through-edit + Delete → joined to the original clip")

    -- And it's a normal undoable join: undo restores both halves.
    local ur = command_manager.undo()
    assert(ur.success, "undo: " .. tostring(ur.error_message))
    assert(bounds(right_id) ~= nil, "undo restores the right half")
    print("  PASS: the join is undoable")
end

-- ── Test B: a genuine cut (source gap) — Delete on the roll must NOT join ──
do
    local layout = ripple_layout.create({ db_path = "/tmp/jve/test_del_join_real.db",
        clips = {
            order = {"v1_left", "v1_right"},
            -- Flush on the timeline, but a 4000-frame SOURCE gap at the cut:
            -- left plays 1000..2000, right plays 6000.. → a real edit, not a
            -- through-edit. (Distinct clips also have distinct source sequences.)
            v1_left  = { sequence_start = 0,    duration = 1000, source_in = 1000 },
            v1_right = { sequence_start = 1000, duration = 1000, source_in = 6000 },
        } })
    layout:init_timeline_state()
    focus_manager.set_focused_panel("timeline")

    local left_id  = layout.clips.v1_left.id
    local right_id = layout.clips.v1_right.id
    local track_id = layout.tracks.v1.id
    local left_before, right_before = bounds(left_id), bounds(right_id)

    roll_select(left_id, right_id, track_id)

    local dr = command_manager.execute("DeleteSelection",
        { project_id = layout.project_id, sequence_id = layout.sequence_id })
    assert(dr.success, "DeleteSelection should succeed: " .. tostring(dr.error_message))

    assert(same_bounds(bounds(left_id), left_before)
        and same_bounds(bounds(right_id), right_before),
        "Delete on a roll over a genuine (non-through) cut must leave both clips untouched")
    print("  PASS: roll-select a genuine cut + Delete → no join, clips untouched")
end

print("✅ test_delete_joins_through_edit.lua passed")
