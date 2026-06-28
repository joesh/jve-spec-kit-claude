-- Feature 027 T003: capture ring buffer trims by WALL age, not CPU
-- time, and every per-stream buffer respects its count cap.
--
-- Why this matters: the legacy implementation used os.clock() — process
-- CPU time, not wall time. After 5 wall minutes of idle, the buffer
-- still held everything because CPU time barely moved. The "5-minute
-- window" promise the user reads at F12 was a lie.
--
-- Black-box per Constitution III — describes wall-age trimming + cap
-- enforcement without naming an internal function or pinning a specific
-- buffer-trim algorithm.
--
-- Loader guard mechanism: monkey-patch `_G.qt_monotonic_s` to a
-- controlled value before requiring the manager. Until T009 swaps
-- os.clock() → qt_monotonic_s, the stub has no effect, gestures' wall
-- timestamps stay near 0, and the wall-age trim assertion fails with a
-- specific message naming T009.

require("test_env")

local stub_now_s = 0
local original_monotonic = rawget(_G, "qt_monotonic_s")
_G.qt_monotonic_s = function() return stub_now_s end

-- Reset captures of the module if it was already loaded (tests run in
-- parallel harnesses where module state can leak across files).
package.loaded["bug_reporter.capture_manager"] = nil

local cap = require("bug_reporter.capture_manager")
cap.capture_enabled = true
cap:init()

local function set_wall_s(s) stub_now_s = s end
local function elapsed_ms_for(s) return (s - 0) * 1000 end  -- session_start_time captured at stub=0

-- 1) Wall-age trim: 10 gestures across 10 simulated wall minutes; then
-- trim should drop everything older than 5 minutes (the spec's stated
-- window).
set_wall_s(0)
for minute = 0, 9 do
    set_wall_s(minute * 60)
    cap:log_gesture("g_at_min_" .. minute)
end

-- Advance to wall-time 11 minutes and force a trim by inserting one
-- more gesture (log_gesture calls trim_buffers internally).
set_wall_s(11 * 60)
cap:log_gesture("anchor_at_min_11")

local cutoff_ms = elapsed_ms_for(11 * 60) - (5 * 60 * 1000)
for _, entry in ipairs(cap.gesture_ring_buffer) do
    assert(entry.timestamp_ms >= cutoff_ms,
        string.format(
            "wall-age trim broken — found gesture at ts=%dms after trim with cutoff=%dms; " ..
            "likely cause: capture_manager still calls os.clock() instead of qt_monotonic_s (T009 not landed)",
            entry.timestamp_ms, cutoff_ms))
end

-- Stronger check: the 5 oldest gestures (minutes 0..4) MUST be gone.
local saw_old = false
for _, entry in ipairs(cap.gesture_ring_buffer) do
    if entry.gesture and tostring(entry.gesture):match("g_at_min_[0-4]$") then
        saw_old = true
        break
    end
end
assert(not saw_old, "gestures from minutes 0..4 survived a 5-minute wall trim — wall-age trim not honored")

-- 2) Per-stream count caps: spec 027 T009 sets gestures 200, commands
-- 200, logs 1000, screenshots 300. Insert past the cap and assert the
-- buffer holds at most the cap.
set_wall_s(20 * 60)  -- jump forward so wall trim won't dominate
cap:init()
cap.capture_enabled = true

for i = 1, 250 do cap:log_command("cmd_" .. i, {}, "ok", nil) end
assert(#cap.command_ring_buffer <= 200,
    string.format("command buffer exceeded cap 200 (size=%d) — T009 count cap not in place",
        #cap.command_ring_buffer))

for i = 1, 1200 do cap:log_message("info", "log_" .. i) end
assert(#cap.log_ring_buffer <= 1000,
    string.format("log buffer exceeded cap 1000 (size=%d) — T009 count cap not in place",
        #cap.log_ring_buffer))

for i = 1, 350 do cap:capture_screenshot() end
assert(#cap.screenshot_ring_buffer <= 300,
    string.format("screenshot buffer exceeded cap 300 (size=%d) — T009 count cap not in place",
        #cap.screenshot_ring_buffer))

-- Restore original global (if any) so we don't pollute downstream tests.
_G.qt_monotonic_s = original_monotonic

print("✅ test_bug_reporter_capture_monotonic.lua passed")
