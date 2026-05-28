require('test_env')

-- Vertical-axis surfacing for multi-track undo/redo. Because
-- timeline_view owns its vertical scroll offset as instance state (not
-- module state), the policy can't mutate it directly. Instead it emits
-- a Signals "viewport_surface_tracks" signal that the timeline_view
-- subscribes to at creation. This test verifies the policy-side half:
-- the signal fires with the correct track set when undo/redo has a
-- change region, and stays silent otherwise.

local viewport_policy = require("ui.timeline.viewport_policy")
local Signals = require("core.signals")
local data = require("ui.timeline.state.timeline_state_data")
local test_env = require("test_env")

local function reset_viewport()
    -- Per-sequence view-state lives on the displayed tab's cache (H1);
    -- is_playing is transport-global and remains on data.state.
    test_env.install_displayed_tab_stub({
        content_length = 10000,
        playhead_position = 100,
        viewport_start_time = 0,
        viewport_duration = 1000,
        sequence_timecode_start_frame = 0,
        sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 },
    })
    data.state.is_playing = false
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

-- Capture emissions of viewport_surface_tracks.
local captured = {}
local conn = Signals.connect("viewport_surface_tracks", function(track_ids_list)
    table.insert(captured, track_ids_list)
end)

local function reset_capture() captured = {} end

print("=== viewport_policy vertical-axis surfacing ===")

-- -----------------------------------------------------------------------
-- 1. Undo with mutations across two tracks emits the signal with
-- those track ids.
-- -----------------------------------------------------------------------
do
    reset_viewport()
    reset_capture()
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", sequence_start_frame = 100, duration_frames = 200 },
            { track_id = "a2", sequence_start_frame = 150, duration_frames = 200 },
        },
        updates = {},
        deletes = {},
    })
    viewport_policy.apply_post_command("undo", cmd)
    assert(#captured == 1,
        string.format("expected 1 signal emission, got %d", #captured))
    local ids = captured[1]
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    assert(set["v1"] and set["a2"],
        "emitted track set must include v1 and a2")
    assert(#ids == 2,
        string.format("emitted track set must have exactly 2 entries, got %d", #ids))
    print("  1. undo with two tracks → signal emitted with {v1, a2} ✓")
end

-- -----------------------------------------------------------------------
-- 2. Execute event does not emit the vertical signal (default policy is
-- surface-playhead, no track-set concept).
-- -----------------------------------------------------------------------
do
    reset_viewport()
    reset_capture()
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", sequence_start_frame = 100, duration_frames = 200 },
        },
        updates = {},
        deletes = {},
    })
    viewport_policy.apply_post_command("execute", cmd)
    assert(#captured == 0,
        "execute event must not emit viewport_surface_tracks")
    print("  2. execute event → signal not emitted ✓")
end

-- -----------------------------------------------------------------------
-- 3. Undo with no mutations (mark commands, playhead moves) does not
-- emit the signal — no tracks affected.
-- -----------------------------------------------------------------------
do
    reset_viewport()
    reset_capture()
    local cmd = make_cmd(nil)
    viewport_policy.apply_post_command("undo", cmd)
    assert(#captured == 0,
        "undo with no mutations must not emit viewport_surface_tracks")
    print("  3. undo with no mutations → signal not emitted ✓")
end

-- -----------------------------------------------------------------------
-- 4. Redo behaves the same as undo for the vertical signal.
-- -----------------------------------------------------------------------
do
    reset_viewport()
    reset_capture()
    local cmd = make_cmd({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {
            { previous = { track_id = "v3", sequence_start = 100, duration = 200 } },
        },
    })
    viewport_policy.apply_post_command("redo", cmd)
    assert(#captured == 1, "redo emits once")
    local ids = captured[1]
    assert(#ids == 1 and ids[1] == "v3", "redo delete emits affected track")
    print("  4. redo delete → signal emitted with affected track ✓")
end

Signals.disconnect(conn)
print("\n✅ test_viewport_policy_vertical.lua passed")
