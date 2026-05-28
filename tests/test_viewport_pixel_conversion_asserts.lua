#!/usr/bin/env luajit

-- NSF: time_to_pixel and pixel_to_time must fail loudly on invalid state
-- instead of silently returning 0. The pre-existing nil/zero-duration
-- guards masked startup-ordering bugs as "everything renders at pixel 0".

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")
local viewport_state = require("ui.timeline.state.viewport_state")

local function expect_assert(label, fn)
    local ok, err = pcall(fn)
    assert(not ok, "expected assert to fire for: " .. label)
    assert(type(err) == "string" and err:find("viewport_state"),
        "assert message for '" .. label .. "' must mention viewport_state, got: " .. tostring(err))
end

-- Per-sequence view-state lives on the displayed tab's cache (H1). Reset
-- via re-install — gives each case a fresh known-good cache to perturb.
local cache
local function reset_state()
    cache = test_env.install_displayed_tab_stub({
        sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
        viewport_start_time = 0,
        viewport_duration = 240,
    })
end

-- ----- time_to_pixel -----

reset_state()
expect_assert("time_to_pixel: zero viewport_width", function()
    viewport_state.time_to_pixel(0, 0)
end)

reset_state()
expect_assert("time_to_pixel: negative viewport_width", function()
    viewport_state.time_to_pixel(0, -100)
end)

reset_state()
expect_assert("time_to_pixel: nil viewport_width", function()
    viewport_state.time_to_pixel(0, nil)
end)

reset_state()
cache.viewport_duration = 0
expect_assert("time_to_pixel: zero duration", function()
    viewport_state.time_to_pixel(0, 1920)
end)

reset_state()
cache.viewport_duration = nil
expect_assert("time_to_pixel: nil duration", function()
    viewport_state.time_to_pixel(0, 1920)
end)

reset_state()
cache.viewport_start_time = nil
expect_assert("time_to_pixel: nil start", function()
    viewport_state.time_to_pixel(0, 1920)
end)

-- ----- pixel_to_time -----

reset_state()
expect_assert("pixel_to_time: zero viewport_width", function()
    viewport_state.pixel_to_time(0, 0)
end)

reset_state()
expect_assert("pixel_to_time: nil viewport_width", function()
    viewport_state.pixel_to_time(0, nil)
end)

reset_state()
expect_assert("pixel_to_time: nil pixel", function()
    viewport_state.pixel_to_time(nil, 1920)
end)

reset_state()
cache.viewport_duration = 0
expect_assert("pixel_to_time: zero duration", function()
    viewport_state.pixel_to_time(0, 1920)
end)

reset_state()
cache.viewport_start_time = nil
expect_assert("pixel_to_time: nil start", function()
    viewport_state.pixel_to_time(0, 1920)
end)

-- ----- Sanity: valid input still works -----

reset_state()
local x = viewport_state.time_to_pixel(60, 1200)
assert(x == 300, "valid time_to_pixel sanity: 60 frames @ 5px/frame = 300, got " .. tostring(x))

local t = viewport_state.pixel_to_time(300, 1200)
assert(t == 60, "valid pixel_to_time sanity: 300px @ 5px/frame = 60, got " .. tostring(t))

print("✅ test_viewport_pixel_conversion_asserts.lua passed")
