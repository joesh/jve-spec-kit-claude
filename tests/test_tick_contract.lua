--- Test: tick_in contract enforcement
-- Verifies that source_playback.tick() and timeline_playback.tick()
-- assert on missing or wrong-type fields in tick_in.

require('test_env')

-- Mock qt_constants
local mock_qt_constants = {
    EMP = {
        ASSET_OPEN = function() return nil end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        SET_DECODE_MODE = function() end,
    },
}
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return false end,
    set_playhead = function() end,
    activate = function() end,
    get_asset_info = function() return { fps_num = 30, fps_den = 1 } end,
}

local source_playback = require("core.playback.source_playback")

local mock_viewer = { show_frame = function() end }

local function expect_assert(fn, msg)
    local ok, err = pcall(fn)
    assert(not ok, msg .. " (expected assert, got success)")
    return err
end

-- Valid tick_in for source_playback
local function valid_source_tick_in()
    return {
        pos = 50, direction = 1, speed = 1,
        fps_num = 30, fps_den = 1, total_frames = 100,
        transport_mode = "shuttle", latched = false,
        latched_boundary = nil,
        context_id = "test",
    }
end

print("=== test_tick_contract.lua ===")

print("\nTest 1: source tick_in with nil pos asserts")
local t = valid_source_tick_in()
t.pos = nil
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "nil pos should assert")
print("  ok")

print("\nTest 2: source tick_in with wrong direction asserts")
t = valid_source_tick_in()
t.direction = 2
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "direction=2 should assert")
print("  ok")

print("\nTest 3: source tick_in with zero speed asserts")
t = valid_source_tick_in()
t.speed = 0
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "speed=0 should assert")
print("  ok")

print("\nTest 4: source tick_in with missing fps_num asserts")
t = valid_source_tick_in()
t.fps_num = nil
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "nil fps_num should assert")
print("  ok")

print("\nTest 5: source tick_in with invalid transport_mode asserts")
t = valid_source_tick_in()
t.transport_mode = "invalid"
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "invalid transport_mode should assert")
print("  ok")

print("\nTest 6: source tick_in with non-boolean latched asserts")
t = valid_source_tick_in()
t.latched = "yes"
expect_assert(function() source_playback.tick(t, nil, mock_viewer) end,
    "non-boolean latched should assert")
print("  ok")

print("\nTest 7: source tick with valid tick_in succeeds")
t = valid_source_tick_in()
local result = source_playback.tick(t, nil, mock_viewer)
assert(result.continue ~= nil, "result must have continue field")
assert(result.new_pos ~= nil, "result must have new_pos field")
assert(type(result.latched) == "boolean", "result.latched must be boolean")
print("  ok result = { continue=" .. tostring(result.continue) ..
    ", new_pos=" .. tostring(result.new_pos) ..
    ", latched=" .. tostring(result.latched) .. " }")

print("\nTest 8: source tick with nil viewer asserts")
t = valid_source_tick_in()
expect_assert(function() source_playback.tick(t, nil, nil) end,
    "nil viewer should assert")
print("  ok")

print("\n✅ test_tick_contract.lua passed")
