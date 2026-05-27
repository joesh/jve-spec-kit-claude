require('test_env')

-- Domain rule: after the user surfaces the playhead (e.g. arrow-key while
-- parked, viewport-policy post-command), switching to another sequence
-- and back must not lose the surfaced scroll position. Operationally:
-- any user-initiated viewport motion must survive round-tripping through
-- sequence persistence — identical to scrolling via the scrollbar.

local viewport_state = require("ui.timeline.state.viewport_state")
local data           = require("ui.timeline.state.timeline_state_data")
-- Pre-require timeline_state so its module-load `strip_holder.set(fresh)`
-- happens BEFORE we install the stub; otherwise scenario 5's lazy
-- require would clobber it.
require("ui.timeline.timeline_state")
local strip_holder   = require("ui.timeline.state.strip_holder")

-- Stub strip: persist machinery needs displayed_sequence_id(); viewport_state
-- (1.3f) also reads displayed_tab.cache.content_length. Minimal stub
-- carries both. Avoids pulling in Sequence.load for this unit test.
local function install_stub_strip(seq_id, content_length)
    strip_holder.set({
        get_displayed = function()
            return {
                sequence_id = seq_id,
                cache = { content_length = content_length or 100000 },
            }
        end,
    })
end

local function reset(viewport_start, viewport_duration, playhead)
    data.state.playhead_position = playhead
    data.state.viewport_start_time = viewport_start
    data.state.viewport_duration = viewport_duration
    data.state.sequence_timecode_start_frame = 0
    data.state.is_playing = false
    data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }
    data.state.sequence_id = "test_seq"
    data.state.project_id = "test_proj"
    install_stub_strip("test_seq")
end

print("=== surface_* invokes persist_callback on viewport change ===")

-- 1. surface_playhead moves the viewport AND invokes persist_callback.
do
    reset(0, 1000, 8000)
    local persist_calls = 0
    viewport_state.surface_playhead(function() persist_calls = persist_calls + 1 end)
    assert(data.state.viewport_start_time == 7500,
        "surface_playhead must center on off-screen playhead")
    assert(persist_calls == 1,
        "surface_playhead must invoke persist_callback exactly once when viewport moves, got " .. persist_calls)
    print("  1. surface_playhead moved viewport → persist invoked ✓")
end

-- 2. surface_playhead no-op (playhead already visible) → no persist call.
do
    reset(0, 1000, 500)
    local persist_calls = 0
    viewport_state.surface_playhead(function() persist_calls = persist_calls + 1 end)
    assert(data.state.viewport_start_time == 0,
        "surface_playhead must not move viewport when playhead already visible")
    assert(persist_calls == 0,
        "surface_playhead must skip persist when viewport unchanged, got " .. persist_calls)
    print("  2. surface_playhead no-op → persist skipped ✓")
end

-- 3. surface_range moves the viewport AND invokes persist_callback.
do
    reset(0, 1000, 100)
    local persist_calls = 0
    viewport_state.surface_range(5000, 5400, function() persist_calls = persist_calls + 1 end)
    assert(data.state.viewport_start_time ~= 0,
        "surface_range must move viewport when region is off-screen")
    assert(persist_calls == 1,
        "surface_range must invoke persist_callback exactly once when viewport moves, got " .. persist_calls)
    print("  3. surface_range moved viewport → persist invoked ✓")
end

-- 4. surface_range no-op (region already visible) → no persist call.
do
    reset(0, 1000, 500)
    local persist_calls = 0
    viewport_state.surface_range(200, 400, function() persist_calls = persist_calls + 1 end)
    assert(data.state.viewport_start_time == 0,
        "surface_range must not move viewport when region + playhead already visible")
    assert(persist_calls == 0,
        "surface_range must skip persist when viewport unchanged, got " .. persist_calls)
    print("  4. surface_range no-op → persist skipped ✓")
end

-- 5. Façade wiring: timeline_state.surface_playhead threads the module's
-- persist callback through. Exercised by loading the façade and confirming
-- a surface call produces the same viewport motion as the raw viewport_state
-- call (façade adds persistence; motion semantics must be identical).
do
    reset(0, 1000, 8000)
    local timeline_state = require("ui.timeline.timeline_state")
    timeline_state.surface_playhead()
    assert(data.state.viewport_start_time == 7500,
        "timeline_state.surface_playhead must match viewport_state semantics")
    print("  5. façade surface_playhead delegates correctly ✓")
end

print("\n✅ test_surface_playhead_persists.lua passed")
