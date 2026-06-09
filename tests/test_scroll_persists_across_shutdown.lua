#!/usr/bin/env luajit
--- Vertical scroll offsets MUST persist to the DB on app shutdown.
---
--- Domain symptom (reported 2026-06-07): user opens project, scrolls the
--- timeline down, quits the app, relaunches — and the timeline is back
--- where it was BEFORE the scroll. The user's scroll work is lost on
--- every quit.
---
--- Root cause: persist_scroll_offsets() runs only on tab-switch and
--- sequence-load. The aboutToQuit shutdown hook (ui/layout.lua's
--- __jve_shutdown) does not flush the displayed-tab's scroll cache to
--- the sequences row. On quit, the in-memory cache value evaporates and
--- the next launch reads the stale row.
---
--- Contract under test: core.app_lifecycle.shutdown() must persist the
--- current scroll offsets to the displayed sequence's row before
--- returning. (layout.lua's __jve_shutdown delegates to this module so
--- the production shutdown path and this test share one code path.)

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_scroll_persists_across_shutdown.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local app_lifecycle  = require("core.app_lifecycle")

local DB = "/tmp/jve/test_scroll_persists_across_shutdown.db"
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

-- User scrolls — video by 180 px, audio by 47 px.
timeline_state.set_video_scroll_offset(180)
timeline_state.set_audio_scroll_offset(47)

-- User quits. aboutToQuit fires; layout.lua's __jve_shutdown delegates
-- to this:
app_lifecycle.shutdown()

-- Read row back. On next launch the sequence row IS what's loaded into
-- the cache, so anything missing here is what the user sees post-quit.
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

local v_off, a_off = read_offsets("A")

assert(v_off == 180, string.format(
    "After scroll → shutdown, sequence A's video_scroll_offset must hold "
    .. "the user's 180-px scroll; got %s. The shutdown path is not "
    .. "flushing the displayed-tab cache before the process exits.",
    tostring(v_off)))
assert(a_off == 47, string.format(
    "After scroll → shutdown, sequence A's audio_scroll_offset must hold "
    .. "the user's 47-px scroll; got %s.", tostring(a_off)))

print(string.format("  ✓ video=%d  audio=%d (both persisted on shutdown)", v_off, a_off))
print("\n✅ test_scroll_persists_across_shutdown.lua passed")
