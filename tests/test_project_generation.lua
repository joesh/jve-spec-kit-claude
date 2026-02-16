--- Test project_generation stale-data detection.
-- @file test_project_generation.lua

require("test_env")

print("=== test_project_generation.lua ===")

--------------------------------------------------------------------------------
-- Test 1: generation starts at 0, increments on project_changed
--------------------------------------------------------------------------------
print("\n--- generation counter basics ---")
do
    local Signals = require("core.signals")
    local pg = require("core.project_generation")

    local gen0 = pg.current()
    assert(type(gen0) == "number", "current() must return a number")

    -- Simulate project change
    Signals.emit("project_changed", "project_abc")
    local gen1 = pg.current()
    assert(gen1 == gen0 + 1, string.format(
        "generation must increment: expected %d, got %d", gen0 + 1, gen1))

    -- Second project change
    Signals.emit("project_changed", "project_def")
    local gen2 = pg.current()
    assert(gen2 == gen1 + 1, string.format(
        "generation must increment again: expected %d, got %d", gen1 + 1, gen2))

    print("  generation counter increments passed")
end

--------------------------------------------------------------------------------
-- Test 2: check() passes when generation matches, fails when stale
--------------------------------------------------------------------------------
print("\n--- check() stale detection ---")
do
    local Signals = require("core.signals")
    local pg = require("core.project_generation")

    local captured = pg.current()

    -- Should pass: same generation
    pg.check(captured, "test_same_gen")
    print("  check() passes for current generation")

    -- Simulate project change
    Signals.emit("project_changed", "new_project")

    -- Should fail: stale generation
    local ok, err = pcall(pg.check, captured, "test_stale")
    assert(not ok, "check() must fail for stale generation")
    assert(err:find("stale data from previous project"),
        "error message must mention stale data, got: " .. err)

    print("  check() catches stale generation passed")
end

--------------------------------------------------------------------------------
-- Test 3: audio_playback.start() catches stale sources after project change
--------------------------------------------------------------------------------
print("\n--- audio_playback stale source detection ---")
do
    local Signals = require("core.signals")

    -- We need a fresh audio_playback with mocked Qt bindings
    -- Re-use the real module (already loaded by test suite setup)
    local audio_playback = require("core.media.audio_playback")

    -- Skip if no Qt bindings (can't test start() without AOP/SSE)
    if not (qt_constants and qt_constants.SSE and qt_constants.AOP) then
        print("  skipped (no Qt bindings)")
    else
        -- Init session
        audio_playback.init_session(48000, 2)
        audio_playback.set_max_time(10000000)

        -- Set sources (captures current generation)
        local sources = {{
            path = "/test/media.mp4", seek_us = 0,
            clip_start_us = 0, clip_end_us = 4000000,
            speed_ratio = 1.0, volume = 1.0,
        }}
        local mock_cache = {
            get_audio_pcm_for_path = function() return nil, 0, 0 end,
        }
        audio_playback.set_audio_sources(sources, mock_cache)

        -- Simulate project change (generation increments)
        Signals.emit("project_changed", "different_project")

        -- start() should catch the stale generation
        local ok, err = pcall(audio_playback.start)
        assert(not ok, "start() must fail with stale sources after project change")
        assert(err:find("stale data from previous project"),
            "error must mention stale data, got: " .. err)

        -- Clean up
        audio_playback.shutdown_session()

        print("  audio_playback.start() catches stale sources passed")
    end
end

print("\n✅ test_project_generation.lua passed")
