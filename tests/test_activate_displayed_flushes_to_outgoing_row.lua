#!/usr/bin/env luajit
--- Regression: switching displayed tabs while the outgoing tab has
--- pending (debounced) per-sequence view-state must write that state to
--- the OUTGOING tab's DB row, not the incoming row.
---
--- Pre-fix architecture (broken):
---   wrapper.M.activate_displayed:
---     1. capture prev_seq_id
---     2. tab_strip:switch_displayed(new)   ← strip points at new now
---     3. core.activate_displayed(new, prev) → inside, if persist_dirty,
---        calls M.persist_state_to_db(true) → flush_state_to_db reads
---        strip_holder = NEW → SetPlayhead/SetViewport(seq_id=NEW, …) with
---        OUTGOING data.state values → OVERWRITES NEW's row with A's state.
---
--- Domain contract: per-sequence view-state writes go to the sequence
--- whose row they describe. Switching tabs must not leak A's playhead /
--- viewport into B's persisted record.

require("test_env")

local invoked_timers = {}
_G.qt_create_single_shot_timer = function(_d, cb)
    table.insert(invoked_timers, cb)
end
local function flush_timers()
    while #invoked_timers > 0 do
        local cb = table.remove(invoked_timers, 1)
        if cb then cb() end
    end
end

print("=== test_activate_displayed_flushes_to_outgoing_row.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_activate_displayed_flushes_to_outgoing_row.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))

local now = os.time()
local B_INITIAL_PLAYHEAD = 7777
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES
        ('A', 'p', 'A', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
        ('B', 'p', 'B', 'sequence', 24, 1, 48000, 1920, 1080, %d, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES
        ('tr_a', 'A', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('tr_b', 'B', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now, B_INITIAL_PLAYHEAD, now, now))

timeline_state.reset()
timeline_state.init("A", "p")
command_manager.init("A", "p")
flush_timers()  -- drain any persist scheduled by init

local A_DIRTY_PLAYHEAD = 1234
timeline_state.set_playhead_position(A_DIRTY_PLAYHEAD)
-- set_playhead_position itself doesn't enqueue a persist; pair it with a
-- viewport mutation (which does) so persist_dirty=true at swap time.
-- Anything that dirties persist would do — viewport is the closest to the
-- user gesture (scroll/zoom) that triggers this bug in production.
timeline_state.set_viewport_start_time(50)
-- Do NOT flush_timers — leave the debounce pending. This is exactly the
-- scenario where activate_displayed must flush to OUTGOING (A), not to
-- INCOMING (B).

timeline_state.activate_displayed("B")
flush_timers()  -- let any scheduled persist finalize

-- Read B's stored playhead. If the bug exists, A's pending playhead
-- (1234) leaked into B's row. If correct, B keeps its own (7777).
local q = conn:prepare("SELECT playhead_frame FROM sequences WHERE id = 'B'")
assert(q:exec()); q:next()
local b_playhead = q:value(0); q:finalize()

assert(b_playhead == B_INITIAL_PLAYHEAD, string.format(
    "B's stored playhead must remain %d after switching A→B with A's "
    .. "playhead dirty. Got %d. (If %d, the wrapper flushed AFTER the "
    .. "strip swap, writing A's view-state values into B's row.)",
    B_INITIAL_PLAYHEAD, b_playhead, A_DIRTY_PLAYHEAD))

-- And A's row must hold A's dirty value (was flushed BEFORE the swap).
local qa = conn:prepare("SELECT playhead_frame FROM sequences WHERE id = 'A'")
assert(qa:exec()); qa:next()
local a_playhead = qa:value(0); qa:finalize()
assert(a_playhead == A_DIRTY_PLAYHEAD, string.format(
    "A's stored playhead must hold A's dirty value (%d) after the "
    .. "switch flushed outgoing state to A's row. Got %d.",
    A_DIRTY_PLAYHEAD, a_playhead))

print("  ✓ outgoing state flushes to OUTGOING row, not incoming")
print("\n✅ test_activate_displayed_flushes_to_outgoing_row.lua passed")
