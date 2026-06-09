#!/usr/bin/env luajit
--- The throttled-scroll-persist module-level pending flag MUST be cleared
--- on M.reset(). Without this, a project close that fires while a scroll
--- persist is in flight leaves the flag stuck at true; the first scroll
--- in the next project finds pending=true and silently skips scheduling
--- a persist, so that first scroll's value never reaches the DB.
---
--- Repro shape (without fix): scroll A → close project (with timer in
--- flight) → open project B → scroll B → no persist scheduled → kill →
--- B's scroll is gone.
---
--- Contract: after M.reset(), the next setter call in the new session
--- MUST schedule (and, in this synchronous-stub test, complete) a persist.

require("test_env")

-- Capture-don't-fire stub: callback is held, not invoked, so the pending
-- flag would normally stay set across the reset. The reset must clear it
-- explicitly for the post-reset setter to schedule again.
local captured_cb
_G.qt_create_single_shot_timer = function(_d, cb) captured_cb = cb end

print("=== test_scroll_persist_reset_clears_pending.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_scroll_persist_reset_clears_pending.db"
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
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset,
        created_at, modified_at)
    VALUES ('B', 'p', 'B', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, 0, 0, %d, %d)
]], now, now))

timeline_state.reset()
timeline_state.init("A", "p")

-- Session 1: user scrolls A. Pending flag goes true; callback is captured
-- but NOT fired (simulates SIGKILL / project-close before timer fires).
timeline_state.set_video_scroll_offset(120)
assert(captured_cb, "first scroll should have scheduled a callback")
captured_cb = nil  -- discard; we're simulating timer-never-fired

-- Project close → reset → open new project (sequence B).
timeline_state.reset()
timeline_state.init("B", "p")

-- Session 2: user scrolls B. Without the reset-clears-pending fix, this
-- setter finds the leftover pending=true and silently skips scheduling.
-- We assert the callback WAS captured — proving schedule happened.
timeline_state.set_video_scroll_offset(440)
assert(captured_cb, "after M.reset(), the next scroll MUST schedule a persist "
    .. "(the previous session's pending flag must be cleared)")

-- Fire it; verify it lands in B's row.
captured_cb()

local stmt = conn:prepare("SELECT video_scroll_offset FROM sequences WHERE id = 'B'")
assert(stmt:exec())
assert(stmt:next())
local v_off = stmt:value(0)
stmt:finalize()

assert(v_off == 440, string.format(
    "After reset → re-init → scroll, sequence B's video_scroll_offset must "
    .. "hold 440; got %s.", tostring(v_off)))

print(string.format("  ✓ B persisted after reset (v=%d)", v_off))
print("\n✅ test_scroll_persist_reset_clears_pending.lua passed")
