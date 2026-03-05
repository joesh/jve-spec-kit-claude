-- Test: PlaybackEngine + PlaybackController integration (Phase 2)
-- NSF: Tests callback parameter validation and clip window flow
require('test_env')

-- Mock qt_constants before playback_engine require (C++ binding unavailable in test)
package.loaded["core.qt_constants"] = {
    EMP = {},
}

local PlaybackEngine = require("core.playback.playback_engine")

print("Testing PlaybackEngine + PlaybackController integration...")

local passed = 0
local total = 0

local function check(cond, msg)
    total = total + 1
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        print("  FAIL: " .. msg)
        error("Test failed: " .. msg)
    end
end

local function expect_error(fn, pattern, msg)
    total = total + 1
    local ok, err = pcall(fn)
    if not ok and string.find(tostring(err), pattern) then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        print("  FAIL: " .. msg)
        if ok then
            print("    Expected error but succeeded")
        else
            print("    Error: " .. tostring(err))
            print("    Expected pattern: " .. pattern)
        end
        error("Test failed: " .. msg)
    end
end

local function section(name)
    print("\n-- " .. name .. " --")
end

--------------------------------------------------------------------------------
-- Create engine with stub callbacks
--------------------------------------------------------------------------------

local function make_test_engine()
    local events = {}
    return PlaybackEngine.new({
        on_show_frame = function(fh, meta)
            events[#events + 1] = {type = "show_frame", fh = fh, meta = meta}
        end,
        on_show_gap = function()
            events[#events + 1] = {type = "show_gap"}
        end,
        on_set_rotation = function(deg)
            events[#events + 1] = {type = "rotation", deg = deg}
        end,
        on_set_par = function(n, d)
            events[#events + 1] = {type = "par", n = n, d = d}
        end,
        on_position_changed = function(frame)
            events[#events + 1] = {type = "position", frame = frame}
        end,
    }), events
end

--------------------------------------------------------------------------------
-- 1. _provide_clips validation
--------------------------------------------------------------------------------
section("1. _provide_clips parameter validation")

do
    local eng = make_test_engine()
    -- Must fail: from not a number
    expect_error(function()
        eng:_provide_clips("bad", 10, "video")
    end, "from must be number", "_provide_clips rejects non-number from")
end

do
    local eng = make_test_engine()
    -- Must fail: to not a number
    expect_error(function()
        eng:_provide_clips(0, "bad", "video")
    end, "to must be number", "_provide_clips rejects non-number to")
end

do
    local eng = make_test_engine()
    -- Must fail: invalid track_type
    expect_error(function()
        eng:_provide_clips(0, 10, "invalid")
    end, "track_type must be", "_provide_clips rejects invalid track_type")
end

--------------------------------------------------------------------------------
-- 2. _on_controller_position validation
--------------------------------------------------------------------------------
section("2. _on_controller_position parameter validation")

do
    local eng = make_test_engine()
    -- Must fail: frame not a number
    expect_error(function()
        eng:_on_controller_position("bad", false)
    end, "frame must be number", "_on_controller_position rejects non-number frame")
end

do
    local eng = make_test_engine()
    -- Must fail: stopped not a boolean
    expect_error(function()
        eng:_on_controller_position(100, "false")
    end, "stopped must be boolean", "_on_controller_position rejects non-boolean stopped")
end

do
    local eng, events = make_test_engine()
    eng.state = "playing"  -- position callbacks only arrive during playback
    -- Valid call should update position and fire callback
    eng:_on_controller_position(42, false)
    check(eng._position == 42, "_on_controller_position updates _position")
    check(#events == 1, "_on_controller_position fires position callback")
    check(events[1].type == "position" and events[1].frame == 42,
        "_on_controller_position callback has correct frame")
end

do
    local eng = make_test_engine()
    -- stopped=true should update state
    eng.state = "playing"
    eng:_on_controller_position(50, true)
    check(eng.state == "stopped", "_on_controller_position stops on stopped=true")
    check(eng.direction == 0, "_on_controller_position clears direction on stop")
end

--------------------------------------------------------------------------------
-- 3. _on_clip_transition validation
--------------------------------------------------------------------------------
section("3. _on_clip_transition parameter validation")

do
    local eng = make_test_engine()
    -- Must fail: clip_id not a string
    expect_error(function()
        eng:_on_clip_transition(123, 0, 1, 1, false, "/test.mov", 0)
    end, "clip_id must be string", "_on_clip_transition rejects non-string clip_id")
end

do
    local eng = make_test_engine()
    -- Must fail: rotation not a number
    expect_error(function()
        eng:_on_clip_transition("clip1", "bad", 1, 1, false, "/test.mov", 0)
    end, "rotation must be number", "_on_clip_transition rejects non-number rotation")
end

do
    local eng = make_test_engine()
    -- Must fail: par_num < 1
    expect_error(function()
        eng:_on_clip_transition("clip1", 0, 0, 1, false, "/test.mov", 0)
    end, "par_num must be >= 1", "_on_clip_transition rejects par_num < 1")
end

do
    local eng = make_test_engine()
    -- Must fail: par_den < 1
    expect_error(function()
        eng:_on_clip_transition("clip1", 0, 1, 0, false, "/test.mov", 0)
    end, "par_den must be >= 1", "_on_clip_transition rejects par_den < 1")
end

do
    local eng = make_test_engine()
    -- Must fail: is_offline not a boolean
    expect_error(function()
        eng:_on_clip_transition("clip1", 0, 1, 1, "false", "/test.mov", 0)
    end, "is_offline must be boolean", "_on_clip_transition rejects non-boolean is_offline")
end

do
    local eng, events = make_test_engine()
    -- Valid transition should fire rotation/PAR callbacks
    eng:_on_clip_transition("clip1", 90, 4, 3, false, "/test.mov", 0)
    check(eng.current_clip_id == "clip1", "_on_clip_transition sets current_clip_id")
    -- Should have rotation and PAR events
    local has_rotation = false
    local has_par = false
    for _, e in ipairs(events) do
        if e.type == "rotation" and e.deg == 90 then has_rotation = true end
        if e.type == "par" and e.n == 4 and e.d == 3 then has_par = true end
    end
    check(has_rotation, "_on_clip_transition fires rotation callback")
    check(has_par, "_on_clip_transition fires PAR callback")
end

do
    local eng, events = make_test_engine()
    -- Offline transition calls _display_frame_from_renderer → Renderer.get_video_frame.
    -- Stub TMB + Renderer for this validation-focused test.
    eng._tmb = "mock_tmb"
    eng._video_track_indices = { 0 }
    local Renderer = require("core.renderer")
    local orig_gvf = Renderer.get_video_frame
    Renderer.get_video_frame = function() return nil, nil end
    -- Offline transition should use 0/1/1 for rotation/PAR
    eng:_on_clip_transition("clip2", 90, 4, 3, true, "/offline.braw", 50)  -- offline=true
    Renderer.get_video_frame = orig_gvf
    local has_zero_rotation = false
    local has_square_par = false
    for _, e in ipairs(events) do
        if e.type == "rotation" and e.deg == 0 then has_zero_rotation = true end
        if e.type == "par" and e.n == 1 and e.d == 1 then has_square_par = true end
    end
    check(has_zero_rotation, "_on_clip_transition uses rotation=0 for offline")
    check(has_square_par, "_on_clip_transition uses 1:1 PAR for offline")
end

do
    local eng, events = make_test_engine()
    -- Same clip_id should not fire callbacks again
    eng.current_clip_id = "clip1"
    eng:_on_clip_transition("clip1", 180, 2, 1, false, "/test.mov", 0)
    check(#events == 0, "_on_clip_transition skips callbacks for same clip_id")
end

do
    local eng = make_test_engine()
    -- Must fail: frame not a number (nil = missing)
    expect_error(function()
        eng:_on_clip_transition("clip1", 0, 1, 1, false, "/test.mov", nil)
    end, "frame must be number", "_on_clip_transition rejects nil frame")
end

do
    local eng = make_test_engine()
    -- Must fail: frame negative (NSF bounds check)
    expect_error(function()
        eng:_on_clip_transition("clip1", 0, 1, 1, false, "/test.mov", -1)
    end, "frame must be >= 0", "_on_clip_transition rejects negative frame")
end

--------------------------------------------------------------------------------
-- 4. _provide_clips preconditions
--------------------------------------------------------------------------------
section("4. _provide_clips preconditions")

do
    local eng = make_test_engine()
    -- Must fail: no sequence
    expect_error(function()
        eng:_provide_clips(0, 10, "video")
    end, "attempt to index", "_provide_clips asserts without sequence")
end

--------------------------------------------------------------------------------
-- 6. set_surface stores surface reference
--------------------------------------------------------------------------------
section("6. set_surface")

do
    local eng = make_test_engine()
    -- Must fail: nil surface
    expect_error(function()
        eng:set_surface(nil)
    end, "surface is nil", "set_surface asserts on nil")
end

do
    local eng = make_test_engine()
    local fake_surface = {}  -- mock surface
    eng:set_surface(fake_surface)
    check(eng._video_surface == fake_surface, "set_surface stores surface reference")
end

--------------------------------------------------------------------------------
-- 7. Stale position callback rejected after stop
--------------------------------------------------------------------------------
section("7. Stale position callback rejected after stop")

-- Regression: GCD dispatch_async delivers a coalesced position callback from
-- a PREVIOUS play session AFTER engine:stop() has set state="stopped".
-- This stale callback must not overwrite self.playhead.
do
    local eng, events = make_test_engine()
    eng.state = "playing"

    -- Normal playback callback at frame 90125 (coalesced report)
    eng:_on_controller_position(90125, false)
    check(eng._position == 90125,
        "during playback: position updated to 90125")
    check(#events == 1 and events[1].frame == 90125,
        "during playback: position callback fires")

    -- Simulate engine:stop() — state goes to "stopped" synchronously
    eng.state = "stopped"
    eng.direction = 0

    -- Stale callback arrives (dispatched before stop, delivered after)
    events = {}
    eng._on_position_changed = function(frame)
        events[#events + 1] = {type = "position", frame = frame}
    end
    eng:_on_controller_position(90125, false)
    check(eng._position == 90125,  -- unchanged
        "stale callback: position NOT overwritten")
    check(#events == 0,
        "stale callback: position callback NOT fired")

    -- Final stop callback with correct position
    eng:_on_controller_position(90169, true)
    check(eng._position == 90169,
        "final stop callback: position updated to 90169")
    check(#events == 1 and events[1].frame == 90169,
        "final stop callback: position callback fires")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n=== Results: %d/%d passed ===", passed, total))
if passed == total then
    print("✅ test_playback_engine_controller_integration.lua passed")
else
    error("Some tests failed")
end
