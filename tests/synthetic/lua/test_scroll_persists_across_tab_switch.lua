#!/usr/bin/env luajit
--- Scroll offsets must persist to the OUTGOING sequence's row on tab
--- switch — not get written into the incoming row.
---
--- Domain symptom: user scrolls video tab A down 200 px, switches to
--- record tab B, switches back to A — sees A at the top instead of
--- where they left it. Root cause: the displayed_tab_changed listener
--- in timeline_panel ran persist_scroll_offsets() AFTER the strip
--- already pointed at B, so A's outgoing scroll value was written to
--- B's row (corrupting it) and A's row never got the user's value.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_scroll_persists_across_tab_switch.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_scroll_persists_across_tab_switch.db"
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

-- Simulate the user scrolling down 200 px on sequence A.
timeline_state.set_video_scroll_offset(200)

-- Tab swap to B.
timeline_state.switch_to_record_tab("B")

-- Read both rows back. A's outgoing scroll must have been flushed BEFORE
-- the strip swapped, landing in A's row — NOT in B's row.
local function read_offset(seq_id)
    local stmt = conn:prepare("SELECT video_scroll_offset FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    assert(stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

local a_offset = read_offset("A")
local b_offset = read_offset("B")

assert(a_offset == 200, string.format(
    "Outgoing sequence A's video_scroll_offset must reflect the user's "
    .. "200-px scroll; got %s. Likely the persist ran AFTER the strip "
    .. "swap so the value was written to the wrong row.",
    tostring(a_offset)))
assert(b_offset == 0, string.format(
    "Incoming sequence B's row must be untouched by A's scroll value "
    .. "(B's stored offset stays 0); got %s. A's outgoing scroll "
    .. "leaked into B's row.", tostring(b_offset)))

print(string.format("  ✓ A=%d (flushed)  B=%d (intact)", a_offset, b_offset))
print("\n✅ test_scroll_persists_across_tab_switch.lua passed")
