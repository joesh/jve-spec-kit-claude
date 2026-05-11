require('test_env')

-- apply_post_command: the chokepoint function that the command_manager
-- calls after a user action completes. For "undo"/"redo" events it
-- should surface the change region; for "execute" it should surface the
-- playhead. Here we exercise the policy against the real viewport_state
-- (no command_manager plumbing), verifying that derive+surface wire
-- together correctly.

local viewport_policy = require("ui.timeline.viewport_policy")
local data = require("ui.timeline.state.timeline_state_data")

local function reset_viewport(viewport_start, viewport_duration, playhead, content_end)
    data.state.clips = { { timeline_start = 0, duration = content_end or 10000 } }
    data.state.playhead_position = playhead
    data.state.viewport_start_time = viewport_start
    data.state.viewport_duration = viewport_duration
    data.state.sequence_timecode_start_frame = 0
    data.state.is_playing = false
    data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }
    data.state.sequence_id = "test_seq"
    data.state.displayed_tab_id = "test_seq"
    data.state.project_id = "test_proj"
end

local function make_cmd(mutations)
    return {
        type = "FakeCommand",
        get_parameter = function(self, key)
            if key == "__timeline_mutations" then return mutations end
            return nil
        end,
    }
end

local function vp_start() return data.state.viewport_start_time end

print("=== viewport_policy.apply_post_command ===")

-- -----------------------------------------------------------------------
-- 1. execute event, no mutations, playhead off-screen → surface playhead.
-- Viewport [0, 1000], playhead at 8000 (off-screen). Event "execute".
-- Expected: viewport centers on playhead → start = 8000 - 500 = 7500.
-- -----------------------------------------------------------------------
do
    reset_viewport(0, 1000, 8000)
    local cmd = make_cmd(nil)
    viewport_policy.apply_post_command("execute", cmd)
    assert(vp_start() == 7500,
        string.format("execute-event fallback to surface_playhead: expected 7500, got %d", vp_start()))
    print("  1. execute event, off-screen playhead → centered on playhead ✓")
end

-- -----------------------------------------------------------------------
-- 2. undo event, clip moved off-screen → surface change region.
-- Viewport [0, 1000] at frame 0. Playhead at frame 100 (in view).
-- Undone command: update that moved a clip from [5000, 5300] on track v1
-- to [5100, 5400] on track v1. Region = [5000, 5400], playhead at 100.
-- Union [100, 5400] too wide → upstream-left + 5% padding of 1000 = 50.
-- viewport_start = 5000 - 50 = 4950.
-- -----------------------------------------------------------------------
do
    reset_viewport(0, 1000, 100)
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {},
        updates = {
            {
                track_id = "v1",
                timeline_start_frame = 5100,
                duration_frames = 300,
                previous = { track_id = "v1", timeline_start = 5000, duration = 300 },
            },
        },
        deletes = {},
    })
    viewport_policy.apply_post_command("undo", cmd)
    assert(vp_start() == 4950,
        string.format("undo surfaces region upstream-left: expected 4950, got %d", vp_start()))
    print("  2. undo event, off-screen clip → region surfaced (upstream-left) ✓")
end

-- -----------------------------------------------------------------------
-- 3. undo event, region + playhead both near → union centered.
-- Viewport duration 2000. Playhead at 5100. Region [5000, 5400].
-- Union [5000, 5400] width 400 << 2000 → fits. Midpoint = 5200.
-- viewport_start = 5200 - 1000 = 4200.
-- -----------------------------------------------------------------------
do
    reset_viewport(0, 2000, 5100)
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", timeline_start_frame = 5000, duration_frames = 400 },
        },
        updates = {},
        deletes = {},
    })
    viewport_policy.apply_post_command("undo", cmd)
    assert(vp_start() == 4200,
        string.format("undo centers union when it fits: expected 4200, got %d", vp_start()))
    print("  3. undo event, region + playhead fit → centered on union ✓")
end

-- -----------------------------------------------------------------------
-- 4. undo event on a non-clip command (no mutations) → falls back to
-- surface_playhead. E.g. SetMarkIn's undo carries no __timeline_mutations.
-- -----------------------------------------------------------------------
do
    reset_viewport(0, 1000, 8000)
    local cmd = make_cmd(nil)
    viewport_policy.apply_post_command("undo", cmd)
    assert(vp_start() == 7500,
        string.format("undo fallback to playhead when no mutations: expected 7500, got %d", vp_start()))
    print("  4. undo event, no mutations → falls back to surface_playhead ✓")
end

-- -----------------------------------------------------------------------
-- 5. redo event with mutations behaves identically to undo.
-- -----------------------------------------------------------------------
do
    reset_viewport(0, 1000, 100)
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {
            { previous = { track_id = "v1", timeline_start = 5000, duration = 400 } },
        },
    })
    viewport_policy.apply_post_command("redo", cmd)
    assert(vp_start() == 4950,
        string.format("redo surfaces region same as undo: expected 4950, got %d", vp_start()))
    print("  5. redo event → same region-surfacing rules ✓")
end

print("\n✅ test_viewport_policy_apply.lua passed")
