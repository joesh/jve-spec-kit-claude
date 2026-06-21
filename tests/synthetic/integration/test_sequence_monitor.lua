-- Integration test: SequenceMonitor domain behavior.
--
-- REPLACES: tests/synthetic/lua/test_sequence_monitor.lua (1249 lines, wholesale
-- mock — faked qt_constants, EMP, signals, timers, renderer, mixer; tested no
-- real code). That version was inadequate because: (1) its SURFACE_SET_* stubs
-- captured nothing the real binding checks; (2) mock signals let any emit
-- "work" regardless of subscription wiring; (3) fake timers pumped manually,
-- never exercising the real debounce path; (4) renderer.get_sequence_info /
-- mixer.resolve_audio_sources were hand-coded stubs whose outputs couldn't
-- diverge from expectation even if the real callsite broke.
--
-- DOMAIN RULES PINNED:
--   DR-1  Constructor: missing or empty view_id must assert loudly (NSF).
--   DR-2  load_sequence(master): has_clip()=true; sequence is master;
--          title label contains "Source: <name>".
--   DR-3  load_sequence(timeline): has_clip()=true; sequence is not master;
--          title label contains "Timeline: <name>".
--   DR-4  Masterclip playhead persists to sequences.playhead_frame; a new
--          monitor loading the same master reads it back verbatim.
--   DR-5  Timeline sequence playhead IS the model's playhead: moving it in the
--          monitor writes through to sequences.playhead_frame synchronously
--          (single source of truth, shared with the timeline view).
--   DR-6  set_playhead clamps: negative → start_frame floor; fractional →
--          floor(). No upper clamp — NLE convention lets playhead sit beyond
--          content end (park past-last-frame is valid).
--   DR-7  Listeners: notified on playhead change; NOT notified when value
--          unchanged; removed listener not notified; multiple independent
--          listeners fire independently; remove_nonexistent returns false.
--   DR-8  Marks via DB+signal: marks_changed fires → monitor re-reads fresh
--          mark_in / mark_out from sequence row; clear → nil.
--   DR-9  TC display (playhead): at 24fps integer rate, frame N formats as
--          HH:MM:SS:FF by standard NDF timecode math (no drop-frame).
--   DR-10 TC display (duration): both marks set → in→out; only in → in→end;
--          only out → start→out; no marks → total.
--   DR-11 unload clears: has_clip()=false, total_frames=0, playhead=0,
--          sequence_id=nil.
--   DR-12 Switching master→timeline saves masterclip playhead to DB first.
--   DR-13 load_sequence(nil/empty) asserts; load_sequence(nonexistent) asserts.
--   DR-14 seek_to_frame without loaded sequence asserts.
--   DR-15 Operations after unload assert (seek, marks via signal after
--          listener was set).
--   DR-16 Reload same sequence reads DB, does not clobber externally-written
--          playhead (MatchFrame / F-key second-press regression).
--   DR-17 content_changed reads playhead from sequence row, not timeline_state
--          (TSO 2026-05-20 regression: stale global cursor tripped engine assert
--          when a DRP import fired content_changed for a non-displayed sequence).
--   DR-18 destroy() saves masterclip playhead synchronously (no timer pump).
--   DR-19 Out-of-bounds saved playhead loads without crash; further
--          set_playhead still works.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_sequence_monitor.lua (integration) ===")

require("test_env")

local database     = require("core.database")
local Sequence     = require("models.sequence")
local Signals      = require("core.signals")
local qt_constants = require("core.qt_constants")

-- ── DB bootstrap ────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_seqmon_integration.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

-- Project + media fixture.
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p1', 'TestProject', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              0, 0);
]]))

-- Real media file so media.metadata TC can be synthesised correctly.
local media_path = ienv.test_media_path("A005_C052_0925BL_001.mp4")

assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        audio_sample_rate, codec, created_at, modified_at, metadata)
    VALUES ('m1', 'p1', 'TestClip', '%s', 100, 24, 1,
            1920, 1080, 2, 48000, 'h264', 0, 0,
            '{"start_tc_value":0,"start_tc_rate":24,"start_tc_audio_samples":0,"start_tc_audio_rate":48000}')
]], media_path)))

-- master sequence created by the production helper (V13 ensure_master).
local test_env = require("test_env")
local master_id = test_env.create_test_masterclip_sequence("p1", "TestClip", 24, 1, 100, "m1")
assert(master_id and master_id ~= "", "fixture: master_id required")

-- Timeline sequence with one clip so content_end > 0.
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('tl1', 'p1', 'MyTimeline', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 2000, 0, 0, 0)
]]))
assert(db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('tv1', 'tl1', 'V1', 'VIDEO', 1, 1)
]]))
-- clip pointing at the master (sequence_id = master_id). duration=50 frames.
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id, track_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('clip1', 'p1', 'tl1', '%s', 'tv1', 0, 50, 0, 50, 'resample',
            'Clip1', 1, 1.0, 0, 0, 0)
]], master_id)))

-- ── Monitor factory ─────────────────────────────────────────────────────────
-- Real monitors require a bootstrapped transport for engine binding.
-- setup_monitor_panels wraps SequenceMonitor.new + panel registration;
-- transport_project_id triggers transport.init so engines are real.
local function new_monitor(view_id)
    local SequenceMonitor = require("ui.sequence_monitor")
    return SequenceMonitor.new({ view_id = view_id })
end

-- Prime transport once for the whole test (mirrors production startup).
require("core.playback.transport").init("p1")
-- Force reload of sequence_monitor so it picks up the now-bootstrapped transport.
package.loaded["ui.sequence_monitor"] = nil

local function title_text(mon)
    return qt_constants.PROPERTIES.GET_TEXT(mon:get_title_widget())
end

local function tc_playhead_text(mon)
    -- The _tc_playhead_label widget text is updated via PROPERTIES.SET_TEXT;
    -- read it back via the real GET_TEXT binding.
    return qt_constants.PROPERTIES.GET_TEXT(mon._tc_playhead_label)
end

local function tc_duration_text(mon)
    return qt_constants.PROPERTIES.GET_TEXT(mon._tc_duration_label)
end

-- ── Helper: expect an assert / error ────────────────────────────────────────
local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return err
end

-- ── Reset masterclip playhead + marks to known state ────────────────────────
local function reset_master()
    local seq = Sequence.load(master_id)
    seq.playhead_position = 0
    seq.mark_in = nil
    seq.mark_out = nil
    seq:save()
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-1  Constructor validation
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-1) constructor validation --")
do
    expect_assert(function() require("ui.sequence_monitor").new({}) end,
        "missing view_id")
    expect_assert(function() require("ui.sequence_monitor").new({ view_id = "" }) end,
        "empty view_id")
    print("  PASS: bad view_id asserts loudly")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-2  load master: has_clip, is_master, title
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-2) load master sequence --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    assert(mon:has_clip(), "has_clip must be true after load_sequence")
    assert(mon.sequence_id == master_id, "sequence_id set correctly")
    assert(mon.sequence:is_master(), "loaded sequence must be master kind")
    assert(mon.fps_num == 24, "fps_num=24")
    assert(mon.fps_den == 1, "fps_den=1")

    local t = title_text(mon)
    assert(t and t:find("Source"), string.format(
        "master title must contain 'Source'; got '%s'", tostring(t)))
    assert(t:find("TestClip"), string.format(
        "master title must contain media name 'TestClip'; got '%s'", tostring(t)))

    mon:destroy()
    print("  PASS: master load — has_clip, is_master, title 'Source: TestClip'")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-3  load timeline: has_clip, not master, title
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-3) load timeline sequence --")
do
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence("tl1")

    assert(mon:has_clip(), "has_clip after timeline load")
    assert(not mon.sequence:is_master(), "timeline sequence is NOT master")

    local t = title_text(mon)
    assert(t and t:find("Timeline"), string.format(
        "timeline title must contain 'Timeline'; got '%s'", tostring(t)))
    assert(t:find("MyTimeline"), string.format(
        "timeline title must contain 'MyTimeline'; got '%s'", tostring(t)))

    mon:destroy()
    print("  PASS: timeline load — has_clip, not master, title 'Timeline: MyTimeline'")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-4  Masterclip playhead persists to DB; restored on reload
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-4) masterclip playhead persistence --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    -- set_playhead debounces via qt_create_single_shot_timer. The real timer
    -- fires asynchronously; wait_until polls until the DB row is updated.
    mon:set_playhead(42)
    assert(mon.playhead == 42, "in-memory playhead = 42 immediately")

    ienv.wait_until(function()
        return Sequence.load(master_id).playhead_position == 42
    end, 5, "playhead_position == 42 in DB")

    local saved = Sequence.load(master_id).playhead_position
    assert(saved == 42, string.format(
        "playhead must be persisted as 42; DB has %s", tostring(saved)))

    -- Second monitor: reads back the persisted value.
    local mon2 = new_monitor("timeline_monitor")
    mon2:load_sequence(master_id)
    assert(mon2.playhead == 42, string.format(
        "new monitor must restore playhead 42 from DB; got %s",
        tostring(mon2.playhead)))

    mon:destroy()
    mon2:destroy()
    print("  PASS: masterclip playhead persisted and restored")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-5  Timeline sequence playhead IS the model's playhead — moving it in the
--       monitor writes through to the sequence row (single source of truth),
--       synchronously, so the timeline view reflects it. A timeline (record)
--       sequence shares ONE playhead with the timeline; the monitor is a view
--       of that shared playhead, not a private cursor. (Contrast DR-4: a
--       masterclip playhead is private and persists via a debounced surgical
--       update.)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-5) timeline playhead writes through to the model --")
do
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence("tl1")
    mon:set_playhead(25)

    -- Written synchronously through core.playhead.set (same canonical path the
    -- timeline ruler uses) — no debounce timer to wait on.
    local after = Sequence.load("tl1").playhead_position
    assert(after == 25, string.format(
        "timeline sequence.playhead_position must be written through to 25 "
        .. "(single source of truth); DB shows %d", after))

    mon:destroy()
    -- Restore for later tests that assume tl1 starts elsewhere.
    local seq = Sequence.load("tl1"); seq.playhead_position = 0; seq:save()
    print("  PASS: timeline playhead written through to the model (25)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-6  set_playhead clamping
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-6) playhead clamping --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    mon:set_playhead(-5)
    assert(mon.playhead == 0, string.format(
        "negative frame must clamp to 0; got %d", mon.playhead))

    -- No upper clamp: NLE allows parking past content end.
    mon:set_playhead(999)
    assert(mon.playhead == 999, string.format(
        "frame beyond content must NOT be clamped (got %d)", mon.playhead))

    mon:set_playhead(50.7)
    assert(mon.playhead == 50, string.format(
        "fractional frame must floor to 50; got %d", mon.playhead))

    -- Reset to safe value before destroy (save_playhead_to_db clamps internally,
    -- but avoid leaving a stale 999 in DB for later tests).
    mon:set_playhead(0)
    mon:destroy()
    print("  PASS: negative→0, no upper clamp, fractional→floor")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-7  Listener notification
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-7) listener notification --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    local count_a, count_b, count_c = 0, 0, 0
    local fn_a = function() count_a = count_a + 1 end
    local fn_b = function() count_b = count_b + 1 end
    local fn_c = function() count_c = count_c + 1 end
    mon:add_listener(fn_a)
    mon:add_listener(fn_b)
    mon:add_listener(fn_c)

    mon:set_playhead(10)
    assert(count_a >= 1 and count_b >= 1 and count_c >= 1,
        string.format("all three listeners must fire; counts: a=%d b=%d c=%d",
            count_a, count_b, count_c))

    -- Same value → no notification.
    count_a, count_b, count_c = 0, 0, 0
    mon:set_playhead(10)
    assert(count_a == 0 and count_b == 0 and count_c == 0,
        "same value must not trigger listeners")

    -- Remove middle listener.
    mon:remove_listener(fn_b)
    count_a, count_b, count_c = 0, 0, 0
    mon:set_playhead(20)
    assert(count_a >= 1, "fn_a must still fire after fn_b removal")
    assert(count_b == 0, "removed fn_b must not fire")
    assert(count_c >= 1, "fn_c must still fire after fn_b removal")

    -- Remove non-existent returns false.
    assert(mon:remove_listener(function() end) == false,
        "remove non-existent listener must return false")

    -- add_listener type validation.
    expect_assert(function() mon:add_listener(nil) end,      "add_listener nil")
    expect_assert(function() mon:add_listener("notfn") end,  "add_listener string")
    expect_assert(function() mon:add_listener(42) end,       "add_listener number")

    mon:destroy()
    print("  PASS: listener fire/no-op/remove/type-validation")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-8  Marks via DB + marks_changed signal
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-8) marks via DB + signal --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    assert(mon:get_mark_in()  == nil, "mark_in nil initially")
    assert(mon:get_mark_out() == nil, "mark_out nil initially")

    -- Write mark_in to DB, fire signal.
    local seq = Sequence.load(master_id)
    seq.mark_in = 10
    seq:save()
    Signals.emit("marks_changed", master_id)
    assert(mon:get_mark_in() == 10, string.format(
        "mark_in must be 10 after signal; got %s", tostring(mon:get_mark_in())))

    seq = Sequence.load(master_id)
    seq.mark_out = 80
    seq:save()
    Signals.emit("marks_changed", master_id)
    assert(mon:get_mark_out() == 80, string.format(
        "mark_out must be 80 after signal; got %s", tostring(mon:get_mark_out())))

    -- Clear marks.
    seq = Sequence.load(master_id)
    seq.mark_in = nil
    seq.mark_out = nil
    seq:save()
    Signals.emit("marks_changed", master_id)
    assert(mon:get_mark_in()  == nil, "mark_in must be nil after clear")
    assert(mon:get_mark_out() == nil, "mark_out must be nil after clear")

    -- marks_changed for a DIFFERENT sequence does not affect this monitor.
    seq = Sequence.load(master_id)
    seq.mark_in = 5
    seq:save()
    Signals.emit("marks_changed", "tl1")       -- different id
    assert(mon:get_mark_in() == nil, string.format(
        "marks_changed for tl1 must not update master monitor; got %s",
        tostring(mon:get_mark_in())))

    -- Cleanup: emit the correct signal so state is clean.
    Signals.emit("marks_changed", master_id)   -- reads back mark_in=5
    seq = Sequence.load(master_id)
    seq.mark_in = nil
    seq:save()
    Signals.emit("marks_changed", master_id)

    mon:destroy()
    print("  PASS: marks read from DB on marks_changed; foreign-id ignored")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-8b  Marks on timeline sequence (same signal path)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-8b) marks on timeline sequence --")
do
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence("tl1")

    local seq = Sequence.load("tl1")
    seq.mark_in  = 5
    seq.mark_out = 45
    seq:save()
    Signals.emit("marks_changed", "tl1")
    assert(mon:get_mark_in()  == 5,  "timeline mark_in=5")
    assert(mon:get_mark_out() == 45, "timeline mark_out=45")

    seq = Sequence.load("tl1")
    seq.mark_in  = nil
    seq.mark_out = nil
    seq:save()
    Signals.emit("marks_changed", "tl1")

    mon:destroy()
    print("  PASS: marks work on timeline sequence")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-9 + DR-10  TC display: playhead + duration labels
--
-- Domain math (24fps NDF, start_timecode_frame=0):
--   frame 50 = 00:00:02:02  (50 = 2*24 + 2)
--   100 frames total = 00:00:04:04  (100 = 4*24 + 4)
--   mark_in=24, mark_out=72 → 48 frames = 00:00:02:00
--   mark_in=24, no out     → 100−24=76 frames = 00:00:03:04  (76 = 3*24 + 4)
--   no in, mark_out=72     → 72 frames = 00:00:03:00  (72 = 3*24 + 0)
--   frame 73 = 00:00:03:01  (73 = 3*24 + 1)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-9/10) TC display --")
do
    reset_master()
    -- Pre-set saved playhead so load_sequence starts at a known frame.
    local seq = Sequence.load(master_id)
    seq.playhead_position = 50
    seq:save()

    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)

    -- DR-9: playhead at frame 50 @ 24fps.
    local ph_tc = tc_playhead_text(mon)
    assert(ph_tc == "00:00:02:02", string.format(
        "playhead TC at frame 50 (24fps) must be 00:00:02:02; got '%s'", tostring(ph_tc)))

    -- DR-10: no marks → total duration = 100 frames.
    local dur_tc = tc_duration_text(mon)
    assert(dur_tc == "00:00:04:04", string.format(
        "no-marks duration = 100 frames @ 24fps = 00:00:04:04; got '%s'",
        tostring(dur_tc)))

    -- Both marks: 48 frames.
    seq = Sequence.load(master_id)
    seq.mark_in = 24; seq.mark_out = 72; seq:save()
    Signals.emit("marks_changed", master_id)
    dur_tc = tc_duration_text(mon)
    assert(dur_tc == "00:00:02:00", string.format(
        "mark[24,72]=48 frames @ 24fps = 00:00:02:00; got '%s'", tostring(dur_tc)))

    -- Only mark_in=24: in→end = 76 frames.
    seq = Sequence.load(master_id); seq.mark_in = 24; seq.mark_out = nil; seq:save()
    Signals.emit("marks_changed", master_id)
    dur_tc = tc_duration_text(mon)
    assert(dur_tc == "00:00:03:04", string.format(
        "in-only [24, total]: 76 frames @ 24fps = 00:00:03:04; got '%s'",
        tostring(dur_tc)))

    -- Only mark_out=72: start→out = 72 frames.
    seq = Sequence.load(master_id); seq.mark_in = nil; seq.mark_out = 72; seq:save()
    Signals.emit("marks_changed", master_id)
    dur_tc = tc_duration_text(mon)
    assert(dur_tc == "00:00:03:00", string.format(
        "out-only [0, 72]: 72 frames @ 24fps = 00:00:03:00; got '%s'",
        tostring(dur_tc)))

    -- Seek to frame 73 → playhead TC 00:00:03:01.
    seq = Sequence.load(master_id); seq.mark_in = nil; seq.mark_out = nil; seq:save()
    Signals.emit("marks_changed", master_id)
    mon:seek_to_frame(73)
    ph_tc = tc_playhead_text(mon)
    assert(ph_tc == "00:00:03:01", string.format(
        "seek to 73 @ 24fps = 00:00:03:01; got '%s'", tostring(ph_tc)))

    -- Cleared marks → total duration again.
    dur_tc = tc_duration_text(mon)
    assert(dur_tc == "00:00:04:04", string.format(
        "cleared marks → 100 frames @ 24fps = 00:00:04:04; got '%s'",
        tostring(dur_tc)))

    mon:set_playhead(0)
    mon:destroy()
    reset_master()
    print("  PASS: TC display: playhead 00:00:02:02; duration varies with marks")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-11  unload clears state
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-11) unload clears state --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    mon:set_playhead(50)

    mon:unload()
    assert(not mon:has_clip(), "has_clip must be false after unload")
    assert(mon.total_frames == 0, "total_frames=0 after unload")
    assert(mon.playhead == 0, "playhead=0 after unload")
    assert(mon.sequence_id == nil, "sequence_id=nil after unload")

    mon:destroy()
    print("  PASS: unload clears has_clip, total_frames, playhead, sequence_id")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-12  Switching sequences saves previous masterclip playhead
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-12) switching saves masterclip playhead --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    mon:set_playhead(33)

    ienv.wait_until(function()
        return Sequence.load(master_id).playhead_position == 33
    end, 5, "playhead debounce for 33")

    -- Switch to timeline — must flush masterclip playhead first.
    mon:load_sequence("tl1")

    local saved = Sequence.load(master_id).playhead_position
    assert(saved == 33, string.format(
        "masterclip playhead must be 33 in DB after switch; got %s",
        tostring(saved)))

    mon:destroy()
    print("  PASS: switch to timeline flushes masterclip playhead=33 to DB")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-13  load_sequence with bad args asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-13) load_sequence bad args --")
do
    local mon = new_monitor("timeline_monitor")

    expect_assert(function() mon:load_sequence("") end,
        "load_sequence empty string")
    expect_assert(function() mon:load_sequence(nil) end,
        "load_sequence nil")
    expect_assert(function() mon:load_sequence("does_not_exist_xyz") end,
        "load_sequence nonexistent id")

    mon:destroy()
    print("  PASS: empty/nil/nonexistent id all assert")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-14  seek_to_frame without sequence asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-14) seek without sequence --")
do
    local mon = new_monitor("timeline_monitor")
    expect_assert(function() mon:seek_to_frame(10) end,
        "seek_to_frame with no sequence loaded")
    mon:destroy()
    print("  PASS: seek_to_frame before load asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-15  Operations after unload assert
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-15) ops after unload assert --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    mon:unload()

    expect_assert(function() mon:seek_to_frame(10) end, "seek after unload")

    -- set_playhead on nil sequence: the guard is in the persist path and mark
    -- path. The raw set_playhead itself only clamps and notifies; it doesn't
    -- assert on unloaded state. That is intentional — the engine layer owns
    -- the "no sequence" assertion for seek. We only pin seek_to_frame here.

    mon:destroy()
    print("  PASS: seek_to_frame after unload asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-16  Reload same sequence reads DB (external write preserved)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-16) reload same seq reads fresh DB state --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    mon:set_playhead(20)

    ienv.wait_until(function()
        return Sequence.load(master_id).playhead_position == 20
    end, 5, "initial persist of 20")

    -- External writer (MatchFrame / F-key executor) writes marks + playhead.
    local fresh = Sequence.load(master_id)
    fresh.playhead_position = 55
    fresh.mark_in  = 10
    fresh.mark_out = 80
    fresh:save()

    -- Reload the same sequence — must read DB, not clobber with stale in-memory.
    mon:load_sequence(master_id)

    assert(mon.playhead == 55, string.format(
        "playhead must come from DB (55), not stale in-memory (20); got %s",
        tostring(mon.playhead)))
    assert(mon:get_mark_in() == 10, string.format(
        "mark_in must be 10 from DB; got %s", tostring(mon:get_mark_in())))
    assert(mon:get_mark_out() == 80, string.format(
        "mark_out must be 80 from DB; got %s", tostring(mon:get_mark_out())))

    mon:set_playhead(0)
    mon:destroy()
    reset_master()
    print("  PASS: reload reads DB state (55/10/80), does not clobber with stale 20")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-17  content_changed reads playhead from sequence row, not timeline_state
--
-- Regression: TSO 2026-05-20. DRP import fired content_changed for a
-- non-displayed sequence. The monitor's handler read timeline_state (global
-- cursor = 116), but the sequence's start_timecode_frame was 80000. Engine
-- seek(116) tripped the start-boundary assert. Fix: handler reads
-- models.sequence.load(id).playhead_position, not timeline_state.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-17) content_changed reads per-sequence playhead from DB --")
do
    -- Give the master a non-zero TC origin so a stale-low value is
    -- visibly out-of-range for the engine's start-boundary assert.
    reset_master()
    local seq = Sequence.load(master_id)
    -- Use a modest offset so arithmetic stays manageable; production
    -- used 80000 frames. The regression fires regardless of magnitude.
    local START_TC = 1000
    seq.start_timecode_frame = START_TC
    seq.playhead_position    = START_TC + 50
    seq:save()

    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    assert(mon.playhead == START_TC + 50, "pre-condition: playhead at START_TC+50")

    -- Pre-poison timeline_state: install a tab stub whose playhead is
    -- below the sequence's TC origin (simulates a stale global cursor from
    -- a different sequence tab).
    test_env.install_displayed_tab_stub({ sequence_id = master_id })
    require("ui.timeline.timeline_state").set_playhead_position(5)

    -- External writer bumps the sequence's playhead further.
    local fresh = Sequence.load(master_id)
    fresh.playhead_position = START_TC + 120
    fresh:save()

    -- Sanity: timeline_state still has the stale low value.
    local ts_ph = require("ui.timeline.timeline_state").get_playhead_position()
    assert(ts_ph == 5, string.format(
        "fixture: timeline_state.playhead must be 5 (stale); got %s", tostring(ts_ph)))

    -- Fire content_changed. The handler must seek the engine to
    -- START_TC+120 (from DB), not 5 (from timeline_state). Seeking to 5
    -- when start_frame=START_TC would trip PlaybackEngine:seek's
    -- start-boundary assert and crash.
    local ok, err = pcall(function()
        Signals.emit("content_changed", master_id)
    end)
    assert(ok, string.format(
        "content_changed must not assert (seek out-of-bounds regression); got: %s",
        tostring(err)))
    assert(mon.playhead == START_TC + 120, string.format(
        "monitor playhead must come from DB (%d), not timeline_state (5); got %s",
        START_TC + 120, tostring(mon.playhead)))

    -- Restore TC origin for subsequent tests.
    local cleanup = Sequence.load(master_id)
    cleanup.start_timecode_frame = 0
    cleanup.playhead_position    = 0
    cleanup:save()

    mon:set_playhead(0)
    mon:destroy()
    reset_master()
    print(string.format(
        "  PASS: content_changed read DB playhead (%d), ignored timeline_state (5)",
        START_TC + 120))
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-18  destroy() saves masterclip playhead synchronously
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-18) destroy saves playhead synchronously --")
do
    reset_master()
    local mon = new_monitor("timeline_monitor")
    mon:load_sequence(master_id)
    mon:set_playhead(77)

    -- Destroy without waiting for the debounce timer.
    -- destroy() calls save_playhead_to_db() directly (synchronous).
    mon:destroy()

    local saved = Sequence.load(master_id).playhead_position
    assert(saved == 77, string.format(
        "destroy must flush playhead 77 synchronously; DB has %s",
        tostring(saved)))

    reset_master()
    print("  PASS: destroy flushed playhead=77 without timer pump")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-19  Out-of-bounds saved playhead loads without crash
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-19) out-of-bounds saved playhead --")
do
    -- Bypass set_playhead to write a value past content end.
    local seq = Sequence.load(master_id)
    seq.playhead_position = 999
    seq:save()

    local mon = new_monitor("timeline_monitor")

    -- Must not crash; playhead preserved verbatim (no upper clamp on load).
    mon:load_sequence(master_id)
    assert(mon.playhead == 999, string.format(
        "load must preserve saved playhead 999 verbatim; got %s",
        tostring(mon.playhead)))

    -- Further set_playhead still works.
    mon:set_playhead(42)
    assert(mon.playhead == 42, "set_playhead still works after out-of-bounds load")

    mon:destroy()
    reset_master()
    print("  PASS: out-of-bounds saved playhead (999) loads without crash")
end

-- ════════════════════════════════════════════════════════════════════════════
print("\nPASS test_sequence_monitor.lua (integration)")
os.exit(0)
