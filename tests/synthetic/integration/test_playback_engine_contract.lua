-- Integration: PlaybackEngine domain contracts.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_contract_engine.lua
--   test_engine_seek_asserts_below_start_frame.lua
--   test_playback_engine_controller_integration.lua
--   test_zero_source_range_clip.lua          (speed-ratio assert only)
--   test_reverse_clip_playback.lua           (speed-ratio domain rules)
--
-- SCENARIOS KEPT (domain rules):
--   DR-1   PlaybackEngine.new("garbage") asserts with invalid role.
--   DR-2   Fresh engine: role set, loaded_sequence_id nil, state "stopped".
--   DR-3   play() before load asserts.
--   DR-4   load(nil), load(""), load("unknown-id") each assert.
--   DR-5   source-engine loading a "sequence"-kind row asserts (FR-001).
--   DR-6   record-engine loading a "master"-kind row asserts (FR-001).
--   DR-7   load() while state="playing" asserts; caller must stop() first.
--   DR-8   load(B) persists A's playhead before rebinding (FR-007).
--   DR-9   unload() twice asserts; double-unload invariant.
--   DR-10  load() pushes SET_LOG_TAG with "role:" prefix to PlaybackController.
--   DR-11  _audio_owner field absent after 017 refactor.
--   DR-12  seek() below start_frame asserts in Lua, not in C++.
--   DR-13  seek(start_frame) and seek(above start_frame) do NOT trip the gate.
--   DR-14  _on_controller_position: frame/stopped type validation; position
--           update + callback fire during playback; stopped=true halts state.
--   DR-15  _on_clip_transition: clip_id/rotation/par/offline/frame validation;
--           rotation+PAR callbacks fire for new clip; skipped for same clip.
--   DR-16  _provide_clips: from/to/track_type type validation.
--   DR-17  _compute_video_speed_ratio: 1.0× normal, -1.0× reverse, 0.5×
--           slow-motion; nil or zero source/duration each assert.
--   DR-18  set_surface(nil) asserts; set_surface+get_surface round-trip.
--   DR-19  Stale position callback rejected when state="stopped".
--
-- SCENARIOS DROPPED:
--   All scenarios from test_playback_engine.lua that verified mock
--   call-sequences (PLAY/STOP/PARK called N times, audio burst counts,
--   audio ownership via play_frame_audio) — those verify Lua→stub
--   routing, not domain behavior. The real C++ controller tests call
--   order through test_playback_av_sync.lua and test_playback_seek_delivers_frame.lua.
--   WHITE-BOX _configure_and_start_audio / session-init / _try_audio tests
--   from test_playback_engine.lua — internal implementation path, not
--   observable domain output.
--   test_playback_video_display.lua surface-set sequence — tests mock
--   surface routing, not real frame delivery.
--   test_playback_controller_audio_guards.lua — all WHITE-BOX private-method
--   guards; no domain output observable without real media.
--   test_playback_engine_extended.lua transport_mode tracking, latch
--   cycle, seek-dedup — all depend on stored_position_cb mock injection;
--   the real C++ side owns position advancement and can't be triggered
--   without running actual playback (see test_playback_av_sync for that).
--
-- OPEN QUESTIONS:
--   Q1. Should _on_controller_position skip the callback when state="playing"
--       and frame is less than the current _position (backwards scrub during fwd play)?
--       Not pinned here because expected value requires C++ tick-ordering knowledge.
--   Q2. Expected SET_LOG_TAG prefix length is LOG_TAG_ID_PREFIX_LEN=8; confirmed
--       from source, but would ideally be derived from the spec rather than code.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_playback_engine_contract.lua (integration) ===")

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

-- ── DB bootstrap ────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_engine_contract_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES ('rec',  'proj', 'Rec',        'sequence', 24, 1, 48000, 1920, 1080,
              0, 0, 300, 0, %d, %d),
             ('src',  'proj', 'SrcMaster',  'master',   24, 1, NULL,  1920, 1080,
              0, 0, 300, 0, %d, %d),
             ('src2', 'proj', 'SrcMaster2', 'master',   24, 1, NULL,  1920, 1080,
              0, 0, 300, 0, %d, %d);
]], now, now, now, now, now, now, now, now)))

local PlaybackEngine = require("core.playback.playback_engine")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return tostring(err)
end

local function noop() end
local function make_engine(role)
    return PlaybackEngine.new(role or "source", {
        on_show_frame     = noop,
        on_show_gap       = noop,
        on_set_rotation   = noop,
        on_set_par        = noop,
        on_position_changed = noop,
    })
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-1  new("garbage") asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-1) new('garbage') asserts --")
do
    expect_assert(function() PlaybackEngine.new("garbage") end,
        "invalid role")
    print("  PASS: new('garbage') asserts with invalid role")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-2  Fresh engine initial state
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-2) fresh engine state --")
do
    local src = make_engine("source")
    assert(src.role == "source", "role=source")
    assert(src.loaded_sequence_id == nil, "loaded_sequence_id nil initially")
    assert(src.state == "stopped", "state=stopped initially")
    assert(not src:has_source(), "has_source() false before load")

    local rec = make_engine("record")
    assert(rec.role == "record", "role=record")
    assert(rec.loaded_sequence_id == nil, "record: loaded_sequence_id nil")
    print("  PASS: fresh engine: role set, loaded_sequence_id nil, state stopped")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-3  play() before load asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-3) play() before load asserts --")
do
    local engine = make_engine("source")
    expect_assert(function() engine:play() end, "play before load")
    print("  PASS: play() before load asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-4  load(nil), load(""), load(unknown) each assert
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-4) load bad args assert --")
do
    local engine = make_engine("source")
    expect_assert(function() engine:load(nil) end,    "load(nil)")
    expect_assert(function() engine:load("") end,     "load('')")
    expect_assert(function() engine:load("no-such-id") end, "load(unknown)")
    print("  PASS: load(nil/empty/unknown) each assert")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-5  source-engine rejects "sequence"-kind row (FR-001)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-5) source-engine kind mismatch asserts --")
do
    local engine = make_engine("source")
    local err = expect_assert(function() engine:load("rec") end,
        "source loads sequence kind")
    assert(err:find("kind") or err:find("mismatch") or err:find("FR-001"),
        "error must mention kind mismatch; got: " .. err)
    print("  PASS: source-engine loading 'sequence' kind asserts (FR-001)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-6  record-engine rejects "master"-kind row
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-6) record-engine kind mismatch asserts --")
do
    local engine = make_engine("record")
    local err = expect_assert(function() engine:load("src") end,
        "record loads master kind")
    assert(err:find("kind") or err:find("mismatch") or err:find("FR-001"),
        "error must mention kind mismatch; got: " .. err)
    print("  PASS: record-engine loading 'master' kind asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-7  load() while state="playing" asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-7) load while playing asserts --")
do
    local engine = make_engine("source")
    engine:load("src")
    engine.state = "playing"  -- simulate playing (no real CVDisplayLink needed)
    expect_assert(function() engine:load("src") end, "load while playing")
    engine.state = "stopped"  -- restore for subsequent tests
    engine:unload()
    print("  PASS: load() while state='playing' asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-8  load(B) writes A's playhead before rebinding (FR-007)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-8) load(B) persists A's playhead first --")
do
    local engine = make_engine("source")
    engine:load("src")
    -- Advance position without a real seek (set internal field directly;
    -- the real seek would call C++ PARK which needs the real controller;
    -- we only need _position set to verify _persist_playhead fires).
    engine._position = 42
    engine:load("src2")

    local prev = Sequence.load("src")
    assert(prev.playhead_position == 42, string.format(
        "FR-007: load must write outgoing seq's playhead before rebinding; "
        .. "expected src.playhead_position==42, got %s",
        tostring(prev.playhead_position)))
    assert(engine.loaded_sequence_id == "src2",
        "loaded_sequence_id must be src2 after rebind")

    engine:unload()
    print("  PASS: load(B) persisted A's playhead=42 to DB before rebind")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-9  Double unload asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-9) double unload asserts --")
do
    local engine = make_engine("source")
    engine:load("src")
    engine:unload()
    expect_assert(function() engine:unload() end, "double unload")
    print("  PASS: second unload() asserts (double-unload invariant)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-10  load() pushes SET_LOG_TAG with "role:" prefix
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-10) load() pushes SET_LOG_TAG --")
do
    -- Wrap the real SET_LOG_TAG binding to observe calls.
    local qt = require("core.qt_constants")
    local log_tags_seen = {}
    local orig_set_log_tag = qt.PLAYBACK.SET_LOG_TAG
    qt.PLAYBACK.SET_LOG_TAG = function(pc, tag)
        log_tags_seen[#log_tags_seen + 1] = tag
        if orig_set_log_tag then orig_set_log_tag(pc, tag) end
    end

    local engine = make_engine("source")
    engine:load("src")

    qt.PLAYBACK.SET_LOG_TAG = orig_set_log_tag  -- restore

    local found = false
    for _, tag in ipairs(log_tags_seen) do
        if tostring(tag):match("^source:") then found = true; break end
    end
    assert(found, string.format(
        "load() must call SET_LOG_TAG with 'source:' prefix; "
        .. "saw %d calls, none matched: %s",
        #log_tags_seen, table.concat(log_tags_seen, ", ")))

    engine:unload()
    print("  PASS: load() pushed SET_LOG_TAG with 'source:' prefix")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-11  _audio_owner field absent (017 removed it)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-11) _audio_owner field absent --")
do
    local engine = make_engine("source")
    assert(engine._audio_owner == nil, string.format(
        "_audio_owner must be absent in 017 refactor; got: %s",
        tostring(engine._audio_owner)))
    print("  PASS: _audio_owner field absent after 017 refactor")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-12  seek() below start_frame asserts in Lua with named context
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-12) seek below start_frame asserts in Lua --")
do
    local engine = make_engine("record")
    engine:load("rec")
    -- Patch start_frame to a high value (simulates TC origin sequence).
    engine.start_frame = 89750

    local err = expect_assert(function() engine:seek(0) end,
        "seek(0) when start_frame=89750")
    -- Must name start_frame or its value — actionable context for developers.
    assert(err:find("start_frame") or err:find("89750"), string.format(
        "assert message must name start_frame or value 89750; got: %s", err))
    print("  PASS: seek(0) with start_frame=89750 asserts in Lua with named context")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-13  seek(start_frame) and seek(above) pass the gate
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-13) seek at/above start_frame passes --")
do
    local engine = make_engine("record")
    engine:load("rec")
    engine.start_frame = 89750

    -- At boundary.
    local ok1, err1 = pcall(function() engine:seek(89750) end)
    assert(ok1 or not tostring(err1):find("start_frame"), string.format(
        "seek(start_frame) must NOT trip the start_frame gate; got: %s",
        tostring(err1)))

    -- Above boundary.
    local ok2, err2 = pcall(function() engine:seek(100000) end)
    assert(ok2 or not tostring(err2):find("start_frame"), string.format(
        "seek(above) must NOT trip the start_frame gate; got: %s",
        tostring(err2)))

    engine:unload()
    print("  PASS: seek(start_frame) and seek(above) do not trip the start_frame gate")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-14  _on_controller_position: type validation; state update
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-14) _on_controller_position validation --")
do
    local pos_log = {}
    local engine = PlaybackEngine.new("source", {
        on_show_frame   = noop, on_show_gap = noop,
        on_set_rotation = noop, on_set_par  = noop,
        on_position_changed = function(f) pos_log[#pos_log + 1] = f end,
    })

    -- Type guards.
    expect_assert(function() engine:_on_controller_position("bad", false) end,
        "non-number frame")
    expect_assert(function() engine:_on_controller_position(100, "false") end,
        "non-boolean stopped")

    -- During playback: position updated + callback fires.
    engine.state = "playing"
    engine:_on_controller_position(42, false)
    assert(engine:get_position() == 42, "position updated to 42 during play")
    assert(#pos_log >= 1, "on_position_changed callback fired")

    -- stopped=true: state transitions to stopped.
    engine.state = "playing"
    engine:_on_controller_position(50, true)
    assert(engine.state == "stopped", "state=stopped after stopped=true callback")
    assert(engine.direction == 0, "direction cleared on stop")

    print("  PASS: _on_controller_position type guards and state updates")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-15  _on_clip_transition: type guards + rotation/PAR callbacks
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-15) _on_clip_transition validation --")
do
    local rot_log, par_log = {}, {}
    local engine = PlaybackEngine.new("source", {
        on_show_frame   = noop, on_show_gap = noop,
        on_set_rotation = function(d) rot_log[#rot_log + 1] = d end,
        on_set_par      = function(n, d) par_log[#par_log + 1] = {n, d} end,
        on_position_changed = noop,
    })

    expect_assert(function()
        engine:_on_clip_transition(123, 0, 1, 1, false, "/f.mov", 0)
    end, "non-string clip_id")
    expect_assert(function()
        engine:_on_clip_transition("c1", "bad", 1, 1, false, "/f.mov", 0)
    end, "non-number rotation")
    expect_assert(function()
        engine:_on_clip_transition("c1", 0, 0, 1, false, "/f.mov", 0)
    end, "par_num < 1")
    expect_assert(function()
        engine:_on_clip_transition("c1", 0, 1, 0, false, "/f.mov", 0)
    end, "par_den < 1")
    expect_assert(function()
        engine:_on_clip_transition("c1", 0, 1, 1, "false", "/f.mov", 0)
    end, "non-boolean offline")
    expect_assert(function()
        engine:_on_clip_transition("c1", 0, 1, 1, false, "/f.mov", nil)
    end, "nil frame")
    expect_assert(function()
        engine:_on_clip_transition("c1", 0, 1, 1, false, "/f.mov", -1)
    end, "negative frame")

    -- Valid: rotation + PAR callbacks fire.
    engine:_on_clip_transition("clip1", 90, 4, 3, false, "/f.mov", 0)
    assert(engine.current_clip_id == "clip1", "current_clip_id set")
    assert(#rot_log >= 1 and rot_log[#rot_log] == 90,
        "rotation callback fired with 90")
    assert(#par_log >= 1 and par_log[#par_log][1] == 4 and par_log[#par_log][2] == 3,
        "PAR callback fired with 4:3")

    -- Same clip: callbacks NOT fired again.
    local rot_before = #rot_log
    engine:_on_clip_transition("clip1", 90, 4, 3, false, "/f.mov", 0)
    assert(#rot_log == rot_before, "same clip must not fire rotation callback again")

    print("  PASS: _on_clip_transition type guards, callbacks fire on new clip, skip on same")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-16  _provide_clips: from/to/track_type type validation
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-16) _provide_clips type validation --")
do
    local engine = make_engine("source")
    expect_assert(function() engine:_provide_clips("bad", 10, "video") end,
        "non-number from")
    expect_assert(function() engine:_provide_clips(0, "bad", "video") end,
        "non-number to")
    expect_assert(function() engine:_provide_clips(0, 10, "invalid") end,
        "invalid track_type")
    print("  PASS: _provide_clips from/to/track_type type guards")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-17  _compute_video_speed_ratio: domain values + nil/zero asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-17) _compute_video_speed_ratio domain rules --")
do
    local engine = make_engine("source")

    -- Normal: 100 source frames over 100 timeline frames = 1.0×
    local r1 = engine:_compute_video_speed_ratio(
        { clip_id = "c1", source_in = 0, source_out = 100, duration = 100 })
    assert(r1 == 1.0, string.format(
        "100 source / 100 timeline = 1.0; got %s", tostring(r1)))

    -- Reverse: source_in > source_out encodes reverse direction.
    -- Domain: speed = (source_out - source_in) / duration = (0-100)/100 = -1.0
    local r2 = engine:_compute_video_speed_ratio(
        { clip_id = "c2", source_in = 100, source_out = 0, duration = 100 })
    assert(r2 == -1.0, string.format(
        "reverse (100→0 over 100) = -1.0; got %s", tostring(r2)))

    -- Slow-motion: 50 source frames stretched over 100 = 0.5×
    local r3 = engine:_compute_video_speed_ratio(
        { clip_id = "c3", source_in = 0, source_out = 50, duration = 100 })
    assert(r3 == 0.5, string.format(
        "50 source / 100 timeline = 0.5; got %s", tostring(r3)))

    -- Zero source range must assert.
    expect_assert(function()
        engine:_compute_video_speed_ratio(
            { clip_id = "c4", source_in = 0, source_out = 0, duration = 100 })
    end, "zero source range")

    -- Zero duration must assert.
    expect_assert(function()
        engine:_compute_video_speed_ratio(
            { clip_id = "c5", source_in = 0, source_out = 100, duration = 0 })
    end, "zero duration")

    -- Nil fields must assert.
    expect_assert(function()
        engine:_compute_video_speed_ratio(
            { clip_id = "c6", source_in = nil, source_out = 100, duration = 100 })
    end, "nil source_in")
    expect_assert(function()
        engine:_compute_video_speed_ratio(
            { clip_id = "c7", source_in = 0, source_out = nil, duration = 100 })
    end, "nil source_out")
    expect_assert(function()
        engine:_compute_video_speed_ratio(
            { clip_id = "c8", source_in = 0, source_out = 100, duration = nil })
    end, "nil duration")

    print("  PASS: _compute_video_speed_ratio: 1.0/−1.0/0.5 correct; nil/zero asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-18  set_surface(nil) asserts; get_surface() round-trip
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-18) set_surface validation --")
do
    local engine = make_engine("source")
    expect_assert(function() engine:set_surface(nil) end, "set_surface(nil)")

    local fake_surface = {}
    engine:set_surface(fake_surface)
    assert(engine:get_surface() == fake_surface,
        "get_surface() must return the surface set via set_surface()")
    print("  PASS: set_surface(nil) asserts; set/get round-trip")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-19  Stale position callback rejected when state="stopped"
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-19) stale position callback rejected after stop --")
do
    local pos_log = {}
    local engine = PlaybackEngine.new("source", {
        on_show_frame   = noop, on_show_gap = noop,
        on_set_rotation = noop, on_set_par  = noop,
        on_position_changed = function(f) pos_log[#pos_log + 1] = f end,
    })

    -- Playback: position updates.
    engine.state = "playing"
    engine:_on_controller_position(90125, false)
    assert(engine:get_position() == 90125, "during play: position 90125")

    -- Stop.
    engine.state = "stopped"
    engine.direction = 0

    -- Stale callback must not overwrite position or fire callback.
    local pos_before = engine:get_position()
    local calls_before = #pos_log
    engine:_on_controller_position(90125, false)
    assert(engine:get_position() == pos_before,
        "stale callback: position NOT overwritten")
    assert(#pos_log == calls_before,
        "stale callback: on_position_changed NOT fired")

    engine:_on_controller_position(90200, true)
    assert(engine:get_position() == pos_before,
        "post-stop stopped=true: position NOT overwritten by late stop callback")
    print("  PASS: stale position callback rejected when already stopped")
end

print("\nPASS test_playback_engine_contract.lua")
os.exit(0)
