--- Test audio_playback integration (EMP→SSE→AOP)
-- @file test_audio_playback.lua
--
-- Comprehensive tests following NSF (No Silent Failures) policy:
-- - Happy paths
-- - Error paths (assert validation)
-- - Boundary conditions
-- - State preconditions
-- - Idempotency
--
-- NOTE: Tests requiring qt_constants only run inside JVEEditor

require('test_env')

local audio_playback = require("core.media.audio_playback")

print("=== Test audio_playback module ===")
print()

-- Check if we have Qt bindings (only available in app context)
local has_qt = (qt_constants ~= nil and qt_constants.SSE ~= nil)
if not has_qt then
    print("NOTE: qt_constants not available (running standalone)")
    print("      Qt-dependent tests will be skipped")
    print()
end

-- Helper: expect a function to assert with a specific pattern
local function expect_assert(fn, pattern, desc)
    local ok, err = pcall(fn)
    assert(not ok, desc .. " should assert")
    assert(tostring(err):match(pattern),
        desc .. " error should match '" .. pattern .. "', got: " .. tostring(err))
end

-- Helper: reset module state between tests
local function reset_module_state()
    audio_playback.initialized = false
    audio_playback.playing = false
    audio_playback.has_audio = false
    audio_playback.aop = nil
    audio_playback.sse = nil
    audio_playback.media_cache = nil
    audio_playback.media_time_us = 0
    audio_playback.media_anchor_us = 0
    audio_playback.aop_epoch_playhead_us = 0
    audio_playback.max_media_time_us = 0
    audio_playback.speed = 1.0
    audio_playback.quality_mode = 1
    audio_playback.sample_rate = 48000
    audio_playback.channels = 2
    audio_playback.duration_us = 0
end

--------------------------------------------------------------------------------
-- SECTION 1: Module Interface
--------------------------------------------------------------------------------
print("--- Section 1: Module Interface ---")

print("\nTest 1.1: All expected functions present")
assert(audio_playback.init, "audio_playback.init missing")
assert(audio_playback.shutdown, "audio_playback.shutdown missing")
assert(audio_playback.start, "audio_playback.start missing")
assert(audio_playback.stop, "audio_playback.stop missing")
assert(audio_playback.seek, "audio_playback.seek missing")
assert(audio_playback.set_speed, "audio_playback.set_speed missing")
assert(audio_playback.get_media_time_us, "audio_playback.get_media_time_us missing")
assert(audio_playback.set_max_media_time, "audio_playback.set_max_media_time missing")
assert(audio_playback.get_playhead_us, "audio_playback.get_playhead_us missing")
assert(audio_playback.had_underrun, "audio_playback.had_underrun missing")
assert(audio_playback.clear_underrun, "audio_playback.clear_underrun missing")
print("  ✓ All public functions present")

print("\nTest 1.2: Internal functions present")
assert(audio_playback._start_pump, "_start_pump missing")
assert(audio_playback._ensure_pcm_cache, "_ensure_pcm_cache missing")
assert(audio_playback._pump_tick, "_pump_tick missing")
print("  ✓ Internal functions present")

--------------------------------------------------------------------------------
-- SECTION 2: Initial State
--------------------------------------------------------------------------------
print("\n--- Section 2: Initial State ---")

reset_module_state()

print("\nTest 2.1: Initial state values")
assert(audio_playback.initialized == false, "Should start uninitialized")
assert(audio_playback.playing == false, "Should start not playing")
assert(audio_playback.has_audio == false, "Should start with no audio")
assert(audio_playback.aop == nil, "aop should be nil")
assert(audio_playback.sse == nil, "sse should be nil")
print("  ✓ Initial state correct")

--------------------------------------------------------------------------------
-- SECTION 3: init() Validation
--------------------------------------------------------------------------------
print("\n--- Section 3: init() Validation ---")

reset_module_state()

print("\nTest 3.1: init(nil) asserts")
expect_assert(
    function() audio_playback.init(nil) end,
    "cache.*nil",
    "init(nil)"
)
print("  ✓ init(nil) asserts with context")

print("\nTest 3.2: init with cache missing get_asset_info asserts")
expect_assert(
    function() audio_playback.init({ get_audio_reader = function() end }) end,
    "get_asset_info",
    "init without get_asset_info"
)
print("  ✓ init validates cache.get_asset_info")

print("\nTest 3.3: init with cache missing get_audio_reader asserts")
expect_assert(
    function() audio_playback.init({ get_asset_info = function() end }) end,
    "get_audio_reader",
    "init without get_audio_reader"
)
print("  ✓ init validates cache.get_audio_reader")

print("\nTest 3.4: init with cache.get_asset_info returning nil asserts")
expect_assert(
    function()
        audio_playback.init({
            get_asset_info = function() return nil end,
            get_audio_reader = function() end
        })
    end,
    "returned nil",
    "init with nil asset_info"
)
print("  ✓ init validates asset_info not nil")

--------------------------------------------------------------------------------
-- SECTION 4: set_max_media_time() Validation
--------------------------------------------------------------------------------
print("\n--- Section 4: set_max_media_time() Validation ---")

reset_module_state()

print("\nTest 4.1: set_max_media_time with nil asserts")
expect_assert(
    function() audio_playback.set_max_media_time(nil) end,
    "must be.*number",
    "set_max_media_time(nil)"
)
print("  ✓ set_max_media_time(nil) asserts")

print("\nTest 4.2: set_max_media_time with string asserts")
expect_assert(
    function() audio_playback.set_max_media_time("1000") end,
    "must be.*number",
    "set_max_media_time(string)"
)
print("  ✓ set_max_media_time(string) asserts")

print("\nTest 4.3: set_max_media_time with negative asserts")
expect_assert(
    function() audio_playback.set_max_media_time(-100) end,
    "non%-negative",
    "set_max_media_time(-100)"
)
print("  ✓ set_max_media_time(negative) asserts")

print("\nTest 4.4: set_max_media_time(0) is valid")
audio_playback.set_max_media_time(0)
assert(audio_playback.max_media_time_us == 0, "max_media_time_us should be 0")
print("  ✓ set_max_media_time(0) works")

print("\nTest 4.5: set_max_media_time with positive value")
audio_playback.set_max_media_time(1000000)
assert(audio_playback.max_media_time_us == 1000000, "max_media_time_us should be 1000000")
print("  ✓ set_max_media_time(1000000) works")

--------------------------------------------------------------------------------
-- SECTION 5: set_speed() Validation
--------------------------------------------------------------------------------
print("\n--- Section 5: set_speed() Validation ---")

reset_module_state()

print("\nTest 5.1: set_speed with nil asserts")
expect_assert(
    function() audio_playback.set_speed(nil) end,
    "must be number",
    "set_speed(nil)"
)
print("  ✓ set_speed(nil) asserts")

print("\nTest 5.2: set_speed with string asserts")
expect_assert(
    function() audio_playback.set_speed("1.0") end,
    "must be number",
    "set_speed(string)"
)
print("  ✓ set_speed(string) asserts")

print("\nTest 5.3: set_speed quality mode selection - Q1 for >= 0.25")
audio_playback.set_speed(1.0)
assert(audio_playback.speed == 1.0, "Speed should be 1.0")
assert(audio_playback.quality_mode == 1, "Should use Q1 for 1.0x")

audio_playback.set_speed(0.5)
assert(audio_playback.speed == 0.5, "Speed should be 0.5")
assert(audio_playback.quality_mode == 1, "Should use Q1 for 0.5x")

audio_playback.set_speed(0.25)
assert(audio_playback.speed == 0.25, "Speed should be 0.25")
assert(audio_playback.quality_mode == 1, "Should use Q1 for 0.25x (boundary)")
print("  ✓ Q1 selected for speed >= 0.25")

print("\nTest 5.4: set_speed quality mode selection - Q2 for < 0.25")
audio_playback.set_speed(0.24)
assert(audio_playback.speed == 0.24, "Speed should be 0.24")
assert(audio_playback.quality_mode == 2, "Should use Q2 for 0.24x")

audio_playback.set_speed(0.15)
assert(audio_playback.speed == 0.15, "Speed should be 0.15")
assert(audio_playback.quality_mode == 2, "Should use Q2 for 0.15x")

audio_playback.set_speed(0.1)
assert(audio_playback.speed == 0.1, "Speed should be 0.1")
assert(audio_playback.quality_mode == 2, "Should use Q2 for 0.1x")
print("  ✓ Q2 selected for speed < 0.25")

print("\nTest 5.5: set_speed with negative values (reverse)")
audio_playback.set_speed(-1.0)
assert(audio_playback.speed == -1.0, "Speed should be -1.0")
assert(audio_playback.quality_mode == 1, "Should use Q1 for -1.0x")

audio_playback.set_speed(-0.5)
assert(audio_playback.speed == -0.5, "Speed should be -0.5")
assert(audio_playback.quality_mode == 1, "Should use Q1 for -0.5x")

audio_playback.set_speed(-0.1)
assert(audio_playback.speed == -0.1, "Speed should be -0.1")
assert(audio_playback.quality_mode == 2, "Should use Q2 for -0.1x")
print("  ✓ Negative speeds work with correct quality mode")

print("\nTest 5.6: set_speed(0) is valid (will be clamped by SSE)")
audio_playback.set_speed(0)
assert(audio_playback.speed == 0, "Speed should be 0")
assert(audio_playback.quality_mode == 2, "Should use Q2 for 0 (< 0.25)")
print("  ✓ set_speed(0) stores value (SSE will clamp)")

--------------------------------------------------------------------------------
-- SECTION 6: seek() Validation
--------------------------------------------------------------------------------
print("\n--- Section 6: seek() Validation ---")

reset_module_state()
audio_playback.max_media_time_us = 1000000  -- 1 second

print("\nTest 6.1: seek with nil asserts")
expect_assert(
    function() audio_playback.seek(nil) end,
    "must be number",
    "seek(nil)"
)
print("  ✓ seek(nil) asserts")

print("\nTest 6.2: seek with string asserts")
expect_assert(
    function() audio_playback.seek("500000") end,
    "must be number",
    "seek(string)"
)
print("  ✓ seek(string) asserts")

print("\nTest 6.3: seek when not initialized updates media_time_us only")
reset_module_state()
audio_playback.max_media_time_us = 1000000
audio_playback.initialized = false
audio_playback.seek(500000)
assert(audio_playback.media_time_us == 500000, "media_time_us should be 500000")
print("  ✓ seek when not initialized stores time")

print("\nTest 6.4: seek when initialized but not playing updates stopped state")
reset_module_state()
audio_playback.initialized = true
audio_playback.has_audio = true
audio_playback.playing = false
audio_playback.max_media_time_us = 1000000
audio_playback.seek(300000)
assert(audio_playback.media_time_us == 300000, "media_time_us should be 300000")
assert(audio_playback.media_anchor_us == 300000, "media_anchor_us should be 300000")
print("  ✓ seek when stopped updates stopped state")

--------------------------------------------------------------------------------
-- SECTION 7: get_media_time_us() Behavior
--------------------------------------------------------------------------------
print("\n--- Section 7: get_media_time_us() Behavior ---")

reset_module_state()

print("\nTest 7.1: get_media_time_us when not initialized returns media_time_us")
audio_playback.initialized = false
audio_playback.media_time_us = 123456
local t = audio_playback.get_media_time_us()
assert(t == 123456, "Should return media_time_us when not initialized")
print("  ✓ Returns media_time_us when not initialized")

print("\nTest 7.2: get_media_time_us when not playing returns media_time_us")
audio_playback.initialized = true
audio_playback.playing = false
audio_playback.media_time_us = 789000
t = audio_playback.get_media_time_us()
assert(t == 789000, "Should return media_time_us when not playing")
print("  ✓ Returns media_time_us when not playing")

print("\nTest 7.3: get_media_time_us with nil media_time_us asserts")
audio_playback.initialized = false
audio_playback.media_time_us = nil
expect_assert(
    function() audio_playback.get_media_time_us() end,
    "missing media_time_us",
    "get_media_time_us with nil"
)
audio_playback.media_time_us = 0  -- restore
print("  ✓ Asserts if media_time_us is nil")

--------------------------------------------------------------------------------
-- SECTION 8: start()/stop() State Guards
--------------------------------------------------------------------------------
print("\n--- Section 8: start()/stop() State Guards ---")

reset_module_state()

print("\nTest 8.1: start when not initialized is no-op")
audio_playback.initialized = false
audio_playback.start()  -- Should not throw
assert(audio_playback.playing == false, "Should not start when not initialized")
print("  ✓ start() no-op when not initialized")

print("\nTest 8.2: start when no audio is no-op")
audio_playback.initialized = true
audio_playback.has_audio = false
audio_playback.start()  -- Should not throw
assert(audio_playback.playing == false, "Should not start when no audio")
print("  ✓ start() no-op when no audio")

print("\nTest 8.3: stop when not initialized is no-op")
audio_playback.initialized = false
audio_playback.stop()  -- Should not throw
print("  ✓ stop() no-op when not initialized")

print("\nTest 8.4: stop when not playing is no-op")
audio_playback.initialized = true
audio_playback.playing = false
audio_playback.stop()  -- Should not throw
print("  ✓ stop() no-op when not playing")

print("\nTest 8.5: Multiple stops are idempotent")
audio_playback.initialized = true
audio_playback.playing = false
audio_playback.stop()
audio_playback.stop()
audio_playback.stop()
print("  ✓ Multiple stops don't throw")

--------------------------------------------------------------------------------
-- SECTION 9: get_playhead_us() / had_underrun() / clear_underrun() Guards (NSF)
--------------------------------------------------------------------------------
print("\n--- Section 9: Diagnostic Function Guards (NSF: must be initialized) ---")

reset_module_state()

-- Helper to test that a function asserts
local function expect_assert(fn, msg)
    local ok, err = pcall(fn)
    assert(not ok, msg .. " (expected assert but got success)")
    return err
end

print("\nTest 9.1: get_playhead_us when not initialized ASSERTS (NSF)")
audio_playback.initialized = false
local err = expect_assert(function()
    audio_playback.get_playhead_us()
end, "get_playhead_us should assert when not initialized")
assert(err:match("not initialized"), "Error should mention 'not initialized'")
print("  ✓ get_playhead_us asserts when not initialized (NSF)")

print("\nTest 9.2: get_playhead_us when no aop ASSERTS (NSF)")
audio_playback.initialized = true
audio_playback.aop = nil
err = expect_assert(function()
    audio_playback.get_playhead_us()
end, "get_playhead_us should assert when no aop")
assert(err:match("aop is nil"), "Error should mention 'aop is nil'")
print("  ✓ get_playhead_us asserts when no aop (NSF)")

print("\nTest 9.3: had_underrun when not initialized ASSERTS (NSF)")
audio_playback.initialized = false
err = expect_assert(function()
    audio_playback.had_underrun()
end, "had_underrun should assert when not initialized")
assert(err:match("not initialized"), "Error should mention 'not initialized'")
print("  ✓ had_underrun asserts when not initialized (NSF)")

print("\nTest 9.4: had_underrun when no aop ASSERTS (NSF)")
audio_playback.initialized = true
audio_playback.aop = nil
err = expect_assert(function()
    audio_playback.had_underrun()
end, "had_underrun should assert when no aop")
assert(err:match("aop is nil"), "Error should mention 'aop is nil'")
print("  ✓ had_underrun asserts when no aop (NSF)")

print("\nTest 9.5: clear_underrun when not initialized ASSERTS (NSF)")
audio_playback.initialized = false
err = expect_assert(function()
    audio_playback.clear_underrun()
end, "clear_underrun should assert when not initialized")
assert(err:match("not initialized"), "Error should mention 'not initialized'")
print("  ✓ clear_underrun asserts when not initialized (NSF)")

print("\nTest 9.6: clear_underrun when no aop ASSERTS (NSF)")
audio_playback.initialized = true
audio_playback.aop = nil
err = expect_assert(function()
    audio_playback.clear_underrun()
end, "clear_underrun should assert when no aop")
assert(err:match("aop is nil"), "Error should mention 'aop is nil'")
print("  ✓ clear_underrun asserts when no aop (NSF)")

--------------------------------------------------------------------------------
-- SECTION 10: Qt-Dependent Tests (only run with qt_constants)
--------------------------------------------------------------------------------
if has_qt then

print("\n--- Section 10: Qt-Dependent Tests ---")

print("\nTest 10.1: SSE bindings available")
assert(qt_constants.SSE, "qt_constants.SSE missing")
assert(qt_constants.SSE.CREATE, "SSE.CREATE missing")
assert(qt_constants.SSE.CLOSE, "SSE.CLOSE missing")
assert(qt_constants.SSE.RESET, "SSE.RESET missing")
assert(qt_constants.SSE.SET_TARGET, "SSE.SET_TARGET missing")
assert(qt_constants.SSE.PUSH_PCM, "SSE.PUSH_PCM missing")
assert(qt_constants.SSE.RENDER_ALLOC, "SSE.RENDER_ALLOC missing")
assert(qt_constants.SSE.STARVED, "SSE.STARVED missing")
assert(qt_constants.SSE.CURRENT_TIME_US, "SSE.CURRENT_TIME_US missing")
assert(qt_constants.SSE.Q1 == 1, "SSE.Q1 should be 1")
assert(qt_constants.SSE.Q2 == 2, "SSE.Q2 should be 2")
print("  ✓ SSE bindings present")

print("\nTest 10.2: AOP bindings available")
assert(qt_constants.AOP, "qt_constants.AOP missing")
assert(qt_constants.AOP.OPEN, "AOP.OPEN missing")
assert(qt_constants.AOP.CLOSE, "AOP.CLOSE missing")
assert(qt_constants.AOP.START, "AOP.START missing")
assert(qt_constants.AOP.STOP, "AOP.STOP missing")
assert(qt_constants.AOP.FLUSH, "AOP.FLUSH missing")
assert(qt_constants.AOP.WRITE_F32, "AOP.WRITE_F32 missing")
assert(qt_constants.AOP.BUFFERED_FRAMES, "AOP.BUFFERED_FRAMES missing")
assert(qt_constants.AOP.PLAYHEAD_US, "AOP.PLAYHEAD_US missing")
assert(qt_constants.AOP.HAD_UNDERRUN, "AOP.HAD_UNDERRUN missing")
print("  ✓ AOP bindings present")

print("\nTest 10.3: SSE create and basic operations")
local sse = qt_constants.SSE.CREATE({
    sample_rate = 48000,
    channels = 2,
    block_frames = 512,
})
assert(sse, "SSE.CREATE should return handle")

qt_constants.SSE.SET_TARGET(sse, 0, 1.0, qt_constants.SSE.Q1)
assert(qt_constants.SSE.CURRENT_TIME_US(sse) == 0, "Time should be 0")

qt_constants.SSE.RESET(sse)
assert(qt_constants.SSE.CURRENT_TIME_US(sse) == 0, "Time should be 0 after reset")

qt_constants.SSE.CLOSE(sse)
print("  ✓ SSE basic operations work")

print("\nTest 10.4: SSE RENDER_ALLOC produces frames")
local sse2 = qt_constants.SSE.CREATE({
    sample_rate = 48000,
    channels = 2,
})
assert(sse2, "SSE.CREATE should return handle")

qt_constants.SSE.SET_TARGET(sse2, 0, 1.0, qt_constants.SSE.Q1)

local ptr, produced = qt_constants.SSE.RENDER_ALLOC(sse2, 512)
assert(ptr, "RENDER_ALLOC should return pointer")
assert(produced == 512, "Should produce requested frames (silence when starved)")
assert(qt_constants.SSE.STARVED(sse2), "Should be starved without source PCM")

qt_constants.SSE.CLOSE(sse2)
print("  ✓ SSE RENDER_ALLOC works")

else
    print("\n--- Section 10: Qt-Dependent Tests ---")
    print("  SKIPPED (requires qt_constants)")
end  -- has_qt

--------------------------------------------------------------------------------
-- Clean up
--------------------------------------------------------------------------------
reset_module_state()

print()
print("✅ test_audio_playback.lua passed")
