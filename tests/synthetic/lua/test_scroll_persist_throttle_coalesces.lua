#!/usr/bin/env luajit
--- N rapid-fire scroll setter calls within the throttle window MUST
--- collapse to exactly ONE scheduled persist — not N. The whole point of
--- the throttle is to prevent a per-pixel DB-write storm during slider
--- drag / wheel spin / trackpad scrolling. Without coalescing, every
--- frame of a drag would write the sequences row.
---
--- Contract: while a persist is pending (scheduled but not yet fired),
--- additional setter calls must NOT schedule another timer.

require("test_env")

-- Capture-don't-fire stub: each call appends the callback to a list
-- and we count schedule events. The cb is held but not invoked, so
-- the pending flag stays true across subsequent setter calls — which
-- is the exact state the throttle guard must respect.
local schedule_count = 0
local captured_cbs = {}
_G.qt_create_single_shot_timer = function(_d, cb)
    schedule_count = schedule_count + 1
    table.insert(captured_cbs, cb)
end

print("=== test_scroll_persist_throttle_coalesces.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_scroll_persist_throttle_coalesces.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))
local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d)
]], now, now))
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset,
        created_at, modified_at)
    VALUES ('A', 'p', 'A', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, 0, 0, %d, %d)
]], now, now))

timeline_state.reset()
timeline_state.init("A", "p")

-- Init itself may schedule a persist (loading sequence offsets through the
-- setters touches the throttle path). Drain that and reset the counter so
-- the test measures only user-initiated scroll bursts.
for _, cb in ipairs(captured_cbs) do cb() end
schedule_count = 0
captured_cbs = {}

-- Simulate a drag: 50 rapid scroll-position updates, mixing axes.
-- Without coalescing this would schedule 50 timers.
for i = 1, 25 do
    timeline_state.set_video_scroll_offset(100 + i)
    timeline_state.set_audio_scroll_offset(50 + i)
end

assert(schedule_count == 1, string.format(
    "50 rapid-fire setter calls within the throttle window must schedule "
    .. "exactly ONE persist (the throttle's whole purpose). Got %d schedules. "
    .. "The pending guard is broken — every setter is scheduling its own "
    .. "timer and the DB would be hammered during a drag.", schedule_count))

-- After the (only) pending callback fires, the next setter call must be
-- free to schedule a new persist for whatever the user does next.
captured_cbs[1]()
timeline_state.set_video_scroll_offset(999)
assert(schedule_count == 2, string.format(
    "After the pending callback fires, the next setter call must schedule "
    .. "a fresh persist (so the user's NEXT scroll burst still gets saved). "
    .. "Got %d total schedules; expected 2.", schedule_count))

print(string.format("  ✓ 50 setter calls → 1 schedule; post-fire → 1 more (total %d)",
    schedule_count))
print("\n✅ test_scroll_persist_throttle_coalesces.lua passed")
