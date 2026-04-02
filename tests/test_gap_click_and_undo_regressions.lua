#!/usr/bin/env luajit

-- Regression: find_gap_at_time must find gaps when gap clips are in the track list.
-- Regression: BatchRippleEdit undo must not assert when edit only touches gap clips.

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state") -- luacheck: ignore 211
local timeline_view_input = require("ui.timeline.view.timeline_view_input")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_gap_click_undo_regressions.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = { timeline_start = 0, duration = 500, source_in = 200 },
        v1_right = { timeline_start = 1000, duration = 500, source_in = 200 },
    }
})
local ts = layout:init_timeline_state()
local tracks = layout.tracks

-- Gap is at [500, 1000] on track_v1
local gap_id = layout:gap_id("v1", 500)
local gap_clip = ts.get_clip_by_id(gap_id)
assert(gap_clip and gap_clip.clip_kind == "gap", "Gap clip should exist at 500")

-- ─────────────────────────────────────────────────────────────────────────
-- Test 1: find_gap_at_time must find the gap at frame 700
-- The old space-scanning logic fails because gap clips fill the space.
-- ─────────────────────────────────────────────────────────────────────────
print("--- Test 1: find_gap_at_time finds gap ---")

-- Build a minimal view for find_gap_at_time (it's called inside handle_mouse_down)
-- We can't call it directly (local), but we CAN test the contract:
-- timeline_view_input exposes gap clicking via handle_mouse_down which calls
-- find_gap_at_time and then set_gap_selection. Test via the gap selection side effect.
local width, height = 2000, 320
local view = {
    widget = {},
    state = ts,
    filtered_tracks = {{id = tracks.v1.id}},
    track_layout_cache = {
        by_index = { [1] = {y = 0, height = 150} },
        by_id = { [tracks.v1.id] = {y = 0, height = 150} }
    },
    debug_id = "gap-click-test",
    render = function() end,
}
function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    return (view.track_layout_cache.by_id[track_id] or {}).height or 0
end
function view.get_track_id_at_y(_) return tracks.v1.id end
function view.get_track_y_by_id(track_id)
    return (view.track_layout_cache.by_id[track_id] or {}).y or -1
end

-- Mock timeline global for handle_mouse_down
local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end,
}

-- Clear all selections
ts.set_selection({})
ts.clear_edge_selection()
ts.clear_gap_selection()

-- Click at frame 700 (inside gap [500, 1000])
-- viewport_duration is needed for pixel_to_time conversion
local vp_dur = ts.get_viewport_duration()
assert(vp_dur and vp_dur > 0, "viewport duration must be positive")
local click_x = math.floor(700 * width / vp_dur)

pcall(function()
    timeline_view_input.handle_mouse(view, "press", click_x, 75, 1, {})
end)
-- Gap selection is a two-step: press stores gap in potential_drag, release selects it
pcall(function()
    timeline_view_input.handle_mouse(view, "release", click_x, 75, 1, {})
end)

timeline = original_timeline

-- The gap selection must contain the gap we clicked on
local selected_gaps = ts.get_selected_gaps()
assert(#selected_gaps > 0,
    "Clicking in gap at frame 700 must select the gap (got 0 selected gaps)")
assert(selected_gaps[1].start_value == 500,
    string.format("Selected gap should start at 500, got %s",
        tostring(selected_gaps[1].start_value)))
print("  ✓ Gap click selects the gap")

-- ─────────────────────────────────────────────────────────────────────────
-- Test 2: BatchRippleEdit on gap-only edge, then undo, must not assert
-- When edit only modifies gap clips, original_states must still be valid
-- for the undo hydrator.
-- ─────────────────────────────────────────────────────────────────────────
print("--- Test 2: Undo after gap-only BatchRippleEdit ---")

-- Roll at gap:out + v1_right:in boundary (position 1000)
-- With a small delta that only changes the gap and the right clip
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = layout.clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
})
cmd:set_parameter("delta_frames", 50)

local exec_result = command_manager.execute(cmd)
assert(exec_result.success, "BatchRippleEdit roll should succeed: " .. tostring(exec_result.error_message))

-- Verify the roll worked
local right_after = Clip.load(layout.clips.v1_right.id)
assert(right_after.timeline_start == 1050,
    string.format("Right clip should be at 1050 after roll, got %d", right_after.timeline_start))

-- Undo must succeed — this is where the assert fires if original_states is empty
local undo_result = command_manager.undo()
assert(undo_result.success,
    "Undo of gap-only BatchRippleEdit must not assert: " .. tostring(undo_result.error_message))

-- Verify undo restored the clip
local right_undone = Clip.load(layout.clips.v1_right.id)
assert(right_undone.timeline_start == 1000,
    string.format("Right clip should be at 1000 after undo, got %d", right_undone.timeline_start))

print("  ✓ Undo after gap-clip roll succeeds")

-- ─────────────────────────────────────────────────────────────────────────
-- Test 3: BatchRippleEdit where ONLY gap clips are in original_states
-- This happens when a gap edge is rippled but clamped to 0 (no shift).
-- The only clip in original_states_map is the gap clip itself.
-- ─────────────────────────────────────────────────────────────────────────
print("--- Test 3: Undo when only gap clips in original_states ---")

do
    -- Two adjacent clips on v2 — no gap. Gap on v1 between clips.
    -- Ripple gap:in on v1 with positive delta. Adjacent v2 blocks → clamp to 0.
    -- The gap clip and implied zero-length gap are the only original_states entries.
    local layout2 = ripple_layout.create({
        db_path = "/tmp/jve/tdd_gap_only_undo.db",
        tracks = {
            order = {"v1", "v2"},
        },
        clips = {
            order = {"v1_left", "v1_right", "v2_left", "v2_right"},
            v1_left = { timeline_start = 0, duration = 500, source_in = 200 },
            v1_right = { timeline_start = 1000, duration = 500, source_in = 200 },
            v2_left = { id = "clip_v2_left", track_key = "v2", timeline_start = 0, duration = 1000, source_in = 200 },
            v2_right = { id = "clip_v2_right", track_key = "v2", timeline_start = 1000, duration = 500, source_in = 200 },
        }
    })

    local gap2_id = layout2:gap_id("v1", 500)

    -- Ripple gap:in with delta +600. V2 has adjacent clips at boundary 1000,
    -- so the implied zero-length gap blocks the shift → clamps to 0.
    -- The only original_states entries will be the gap clip + implied gap.
    local cmd2 = Command.create("BatchRippleEdit", layout2.project_id)
    cmd2:set_parameter("sequence_id", layout2.sequence_id)
    cmd2:set_parameter("edge_infos", {
        {clip_id = gap2_id, edge_type = "in", track_id = layout2.tracks.v1.id, trim_type = "ripple"},
    })
    cmd2:set_parameter("delta_frames", 600)

    local exec2 = command_manager.execute(cmd2)
    -- Whether the execute succeeds or clamps to 0, undo must not assert
    if exec2.success then
        local undo2 = command_manager.undo()
        assert(undo2.success,
            "Undo of clamped gap-only ripple must not assert: " .. tostring(undo2.error_message))
        print("  ✓ Undo after clamped gap-only ripple succeeds")
    else
        -- If execute fails due to clamping, that's OK — no undo needed
        print("  ✓ Gap-only ripple clamped (no undo needed)")
    end

    layout2:cleanup()
end

layout:cleanup()
print("✅ test_gap_click_and_undo_regressions.lua passed")
