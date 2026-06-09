#!/usr/bin/env luajit
--- Vertical scroll offsets MUST persist to the DB shortly after the user
--- releases — NOT only when the app exits.
---
--- Domain symptom: if the user scrolls and then the process is killed
--- (crash, SIGKILL, power loss) before clean shutdown runs, their scroll
--- state is lost. The architectural rule is "persist promptly after a
--- user-driven state change," with shutdown as defense-in-depth, not the
--- only save point.
---
--- Contract under test: a call to set_video_scroll_offset /
--- set_audio_scroll_offset schedules a near-term persist that writes the
--- current displayed sequence's row in the DB — no shutdown call, no
--- tab-switch, no explicit persist_scroll_offsets() invocation by the
--- test.

require("test_env")

-- Synchronous timer stub: any scheduled persist fires immediately, which
-- makes the throttle observable as "DB updated by the time the setter
-- returns" without standing up a Qt event loop.
_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_scroll_persists_on_release.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_scroll_persists_on_release.db"
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

local function read_offsets(seq_id)
    local stmt = conn:prepare(
        "SELECT video_scroll_offset, audio_scroll_offset FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    assert(stmt:next())
    local v, a = stmt:value(0), stmt:value(1)
    stmt:finalize()
    return v, a
end

-- User scrolls video by 220 px. No tab switch, no shutdown, no explicit
-- persist call follows. The scheduled near-term persist must run and
-- write the row.
timeline_state.set_video_scroll_offset(220)

local v_off = (read_offsets("A"))
local a_off
assert(v_off == 220, string.format(
    "After set_video_scroll_offset(220) and the scheduled persist firing, "
    .. "sequence A's video_scroll_offset must hold 220 (the user's scroll "
    .. "value); got %s. The setter did not schedule a near-term persist, "
    .. "so the only save points remain shutdown / tab-switch — and the "
    .. "user loses state on every crash.", tostring(v_off)))

-- Audio side: same contract, separate setter.
timeline_state.set_audio_scroll_offset(91)

v_off, a_off = read_offsets("A")
assert(v_off == 220, string.format(
    "Video offset must remain 220 after audio scroll; got %s. "
    .. "Audio-side persist clobbered video.", tostring(v_off)))
assert(a_off == 91, string.format(
    "After set_audio_scroll_offset(91), audio_scroll_offset must be 91; "
    .. "got %s.", tostring(a_off)))

-- Subsequent scroll updates the row too — not just the first one.
timeline_state.set_video_scroll_offset(305)
v_off, a_off = read_offsets("A")
assert(v_off == 305, string.format(
    "Subsequent scroll must also persist; got video=%s (expected 305).",
    tostring(v_off)))

print(string.format(
    "  ✓ scroll value reached DB without shutdown/switch (v=%d a=%d)",
    v_off, a_off))
print("\n✅ test_scroll_persists_on_release.lua passed")
