-- Integration: PlaybackEngine transport state machine — the J/K/L shuttle
-- ramp, slow-play, the boundary latch, transport-mode lifecycle, status
-- string, and the frame-step audio-burst guards — against REAL bindings
-- (real engines bound to REAL DB sequences, a REAL C++ PlaybackController,
-- a REAL GPU surface, and REAL audio ownership).
--
-- REPLACES the RESIDUE of (from tests/synthetic/lua/):
--   test_playback_engine.lua
--   test_playback_engine_extended.lua
-- whose remaining domain scenarios were not pinned by the earlier accepted
-- conversions (test_playback_engine_contract.lua,
-- test_av_handover_ordering.lua, test_audio_handover_contract.lua,
-- test_transport_subscribes_to_signals.lua,
-- test_playback_edit_invalidation.lua). The originals faked qt_constants
-- wholesale and asserted on a recorded PLAY/STOP/PARK call log produced by
-- those fakes — verifying Lua→stub routing, not domain behavior. The
-- boundary-latch scenarios drove the engine through an injected
-- `stored_position_cb` mock; here we drive the engine into shuttle mode
-- against the real controller and then deliver the boundary position
-- through the engine's OWN C++→Lua callback entry point
-- (`_on_controller_position`, the same real method the accepted contract
-- test exercises in DR-14) — no FFI function is faked. The only
-- instrumentation is pass-through wrappers over the real PLAY_BURST
-- bindings that count calls and UNCONDITIONALLY delegate, restored after.
--
-- DOMAIN RULES PINNED (spec 017 transport state machine):
--   TS-1  Shuttle ramp: from stopped, J/L start at 1×; repeating the same
--         direction climbs the 025 FR-003 ladder — 0.25 steps from 1× to
--         2×, then powers of two CAPPED at 32×
--         (1→1.25→1.5→1.75→2→4→8→16→32); holding past 32× stays at 32×.
--   TS-2  Shuttle unwind: the opposite direction RETREATS one rung down
--         that same ladder (4→2→1.75→1.5→1.25→1), and one more opposite
--         step from 1× STOPS (does not flip straight to reverse) — the
--         J/K/L unwinding rule.
--   TS-3  slow_play(dir) plays at exactly 0.5× in `dir`, in shuttle mode.
--   TS-4  get_status projects transport state: "stopped" when parked;
--         "> N.0x" forward, "< N.0x" reverse while shuttling.
--   TS-5  transport_mode lifecycle: "none" parked → "shuttle" under
--         shuttle/slow_play → "play" under play() → "none" after stop().
--   TS-6  Boundary latch (shuttle only): reaching the LAST frame forward
--         (or frame 0 reverse) without a stop event LATCHES — the engine
--         stays in the playing state, pinned at the boundary, marked with
--         the boundary it hit. Play mode does NOT latch.
--   TS-7  Latched + same-direction shuttle is a no-op (stays latched, no
--         position change). Latched + opposite-direction UNLATCHES and
--         resumes at 1× in the new direction (a real PLAYBACK.PLAY kicks).
--   TS-8  Latch/unlatch survives repeated cycles (forward-end then
--         reverse-start) with the boundary marker tracking each side.
--   TS-9  Direction guards: shuttle(0) and slow_play(0) assert (a shuttle
--         must have a sign).
--   TS-10 play() while already playing is an idempotent no-op; stop() while
--         already stopped is a clean no-op.
--   TS-11 Audio conform ratio: media at the sequence's own video rate needs
--         no conform (1.0×); audio-only media (no video rate to conform to)
--         needs no conform (1.0×); missing/zero fps asserts (bad metadata).
--   TS-12 Frame-step audio burst (jog) only fires when this engine is the
--         stopped audio owner: no burst while PLAYING, and no burst when
--         this engine does NOT own the audio device.
--
-- SCENARIOS DROPPED (covered elsewhere or unconvertible):
--   constructor validation, load_sequence, seek/PARK dedup, on_model_changed,
--   calc_frame_from_time_us, seek_to_frame, _compute_video_speed_ratio,
--   _on_controller_position / _on_clip_transition validation — all pinned by
--   test_playback_engine_contract.lua (DR-2/4/12-17) and the filter test.
--   ALL the engine giant's audio-mix-push / session-init / _try_audio /
--   _configure_and_start_audio / _build_audio_mix_params /
--   _push_all_audio_mix_params / B10/B11/B12 / shutdown-ref-preservation
--   scenarios — every one of them drove the engine through
--   PlaybackEngine.init_audio(<fake table>) and asserted on that fake's
--   recorded `_calls` log, i.e. a replaced module with fake behavior. The
--   real device-ownership and edit-invalidation behavior those tried to
--   approximate is pinned honestly by test_audio_handover_contract.lua and
--   test_playback_edit_invalidation.lua. Unconvertible under the
--   no-fakes rule → dropped.
--   play_frame_audio POSITIVE burst-timing assertions (frame→µs, 60ms clamp)
--   from the giants exercised the Lua FALLBACK path that only runs when NO
--   C++ controller exists; a real engine always has one and routes through
--   PLAYBACK.PLAY_BURST (frame, dir, ms — different units). The fallback's
--   exact µs math is therefore unreachable in production. Only the
--   owner/stopped GUARDS (TS-12) are real domain behavior. See OPEN Q1.
--
-- OPEN QUESTIONS:
--   Q1. The positive frame-step burst (a PLAY_BURST actually fires for a
--       stopped owner) is not pinned here: with a real controller it routes
--       to C++ PLAY_BURST only when HAS_AUDIO is true, which requires the
--       real audio pump to have warmed up — timing the editor can't promise
--       deterministically in headless --test mode. The negative guards
--       (TS-12) ARE deterministic and pinned. The positive path is covered
--       by real playback in test_playback_av_sync.lua.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_playback_transport_state_machine.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_playback_transport_state_machine.lua (integration) ===")

require("test_env")
local database       = require("core.database")
local transport      = require("core.playback.transport")
local audio_playback = require("core.media.audio_playback")
local qt_constants   = require("core.qt_constants")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return tostring(err)
end

-- ── DB: project + a record timeline (V1) + a master, both with real
--    decodable media so PLAYBACK.PLAY can kick a real controller. The
--    record timeline carries 200 content frames so the end boundary
--    (frame 199) is unambiguous and distinct from frame 0. ───────────────
local DB = "/tmp/jve/test_transport_state_machine_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)
assert(db:exec(string.format([[
  INSERT INTO projects (id,name,fps_mismatch_policy,settings,created_at,modified_at)
   VALUES ('p','P','resample','{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',%d,%d);
  INSERT INTO media (id,project_id,file_path,name,duration_frames,fps_numerator,fps_denominator,
     width,height,audio_channels,audio_sample_rate,created_at,modified_at)
   VALUES ('m1','p',%q,'A005',108,24000,1001,640,360,2,48000,%d,%d);
  INSERT INTO sequences (id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,
     width,height,playhead_frame,view_start_frame,view_duration_frames,start_timecode_frame,created_at,modified_at)
   VALUES ('rec','p','Rec','sequence',24000,1001,48000,640,360,0,0,300,0,%d,%d);
  INSERT INTO tracks (id,sequence_id,name,track_type,track_index,enabled)
   VALUES ('rec_v1','rec','V1','VIDEO',1,1),('rec_a1','rec','A1','AUDIO',1,1);
]], now, now, media_path, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "p", "A005", 24000, 1001, 108, "m1")
-- A VIDEO clip and a matching AUDIO clip spanning frames 0..199 on the
-- record timeline. The engine needs a real end boundary at frame 199 to
-- latch against; it also needs the AUDIO track to carry real audio content,
-- because PLAYBACK.PLAY prefills the audio pump and an enabled-but-unfed
-- AUDIO track SIGSEGVs the background AudioPump (the bug pinned by
-- test_audio_play_unfed_no_crash.lua). The audio clip uses subframe 0 (the
-- AUDIO sentinel) per the create_test_masterclip_sequence convention.
assert(db:exec(string.format([[
  INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
      sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
      source_in_subframe, source_out_subframe,
      enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
  VALUES
    ('c_v','p','V','rec_v1','rec','rec',0,200,0,200,NULL,NULL,1,'resample',1.0,0,%d,%d),
    ('c_a','p','A','rec_a1','rec','rec',0,200,0,200,0,0,1,'resample',1.0,0,%d,%d)
]], now, now, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("p")
transport.bind_role_to_sequence("record", "rec")
transport.bind_role_to_sequence("source", master_id)
local rec = transport.engine_for_role("record")
local src = transport.engine_for_role("source")

-- Real GPU surfaces: PlaybackController::Play asserts without one, so the
-- shuttle/play scenarios cannot enter the playing state otherwise. --test
-- mode always provides Metal surfaces; failure is an environment defect.
local s1 = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
local s2 = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(s1 and s2, "GPU surface creation failed — environment defect")
rec:set_surface(s1)
src:set_surface(s2)

-- The record engine is bound to a 200-frame timeline; confirm so the latch
-- boundary (last frame) is what the scenarios assume.
assert(rec.total_frames == 200, string.format(
    "fixture: record engine total_frames must be 200, got %s",
    tostring(rec.total_frames)))
local LAST = rec.total_frames - 1  -- 199

-- Keep the audio device idle between scenarios so a play()/shuttle() on a
-- fresh engine performs the full cold acquire (a sibling test in the same
-- process may have left an owner).
local function release_audio()
    if audio_playback.current_owner() ~= nil then audio_playback.halt_current() end
end

-- Pump Qt events briefly so the C++ side settles between transport edges.
-- PLAYBACK.PLAY spawns a background AudioPump thread; a stop()+immediate
-- replay before that thread has joined would reassign a still-joinable
-- std::thread and std::terminate. Real usage always has wall-clock between
-- keypresses; this gives the async engine that same settling window. Used
-- after every play/shuttle/unlatch that kicks the transport, before a stop.
local function settle()
    for _ = 1, 12 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.05")
    end
end

-- Stop the record engine and wait for its audio pump to fully unwind before
-- the next transport edge, then release the device.
local function stop_and_settle()
    rec:stop()
    settle()
    release_audio()
end
release_audio()

-- ════════════════════════════════════════════════════════════════════════════
-- TS-1  Shuttle ramp (025 FR-003): 1 → 1.25 → 1.5 → 1.75 → 2 → 4 → 8 → 16 → 32 (cap)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-1) shuttle ramp climbs the quarter→geometric ladder, caps at 32x --")
do
    stop_and_settle()
    rec:shuttle(1)
    assert(rec.state == "playing", "shuttle from stopped → playing")
    assert(rec.direction == 1, "forward")
    assert(rec.speed == 1, "first J/L is 1x")
    rec:shuttle(1); assert(rec.speed == 1.25, "second forward → 1.25x")
    rec:shuttle(1); assert(rec.speed == 1.5,  "third forward → 1.5x")
    rec:shuttle(1); assert(rec.speed == 1.75, "fourth forward → 1.75x")
    rec:shuttle(1); assert(rec.speed == 2,    "fifth forward → 2x")
    rec:shuttle(1); assert(rec.speed == 4,    "sixth forward → 4x (geometric)")
    rec:shuttle(1); assert(rec.speed == 8,    "seventh forward → 8x")
    rec:shuttle(1); assert(rec.speed == 16,   "eighth forward → 16x")
    rec:shuttle(1); assert(rec.speed == 32,   "ninth forward → 32x (ceiling)")
    rec:shuttle(1); assert(rec.speed == 32,   "tenth forward STAYS 32x — no climb past the cap")
    stop_and_settle()
    print("  PASS: 1→1.25→1.5→1.75→2→4→8→16→32→32 (capped)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-2  Shuttle unwind: opposite direction retreats one rung, stops at 1x
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-2) opposite shuttle unwinds down the ladder before reversing --")
do
    stop_and_settle()
    -- ramp to 4x fwd: 1→1.25→1.5→1.75→2→4 (six presses)
    rec:shuttle(1); rec:shuttle(1); rec:shuttle(1); rec:shuttle(1); rec:shuttle(1); rec:shuttle(1)
    assert(rec.speed == 4 and rec.direction == 1, "fixture: 4x forward")

    rec:shuttle(-1); assert(rec.speed == 2    and rec.direction == 1, "unwind 4→2, still forward")
    rec:shuttle(-1); assert(rec.speed == 1.75 and rec.direction == 1, "unwind 2→1.75, still forward")
    rec:shuttle(-1); assert(rec.speed == 1.5  and rec.direction == 1, "unwind 1.75→1.5, still forward")
    rec:shuttle(-1); assert(rec.speed == 1.25 and rec.direction == 1, "unwind 1.5→1.25, still forward")
    rec:shuttle(-1); assert(rec.speed == 1    and rec.direction == 1, "unwind 1.25→1, still forward")
    rec:shuttle(-1)
    assert(rec.state == "stopped",
        "one more opposite step at 1x STOPS (does not flip to reverse)")
    release_audio()
    print("  PASS: 4→2→1.75→1.5→1.25→1→stop on opposite direction")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-3  slow_play plays at 0.5x in the requested direction
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-3) slow_play is 0.5x in shuttle mode --")
do
    stop_and_settle()
    rec:slow_play(-1)
    assert(rec.state == "playing", "slow_play → playing")
    assert(rec.speed == 0.5, "slow_play is half speed")
    assert(rec.direction == -1, "slow_play honours direction")
    assert(rec.transport_mode == "shuttle", "slow_play uses shuttle mode")
    stop_and_settle()
    print("  PASS: slow_play(-1) → 0.5x reverse, shuttle mode")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-4  get_status string projection
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-4) get_status reflects transport state --")
do
    stop_and_settle()
    assert(rec:get_status() == "stopped", "parked → 'stopped'")

    rec:shuttle(1)
    assert(rec:get_status() == "> 1.0x", "forward 1x → '> 1.0x'")
    rec:shuttle(1)
    assert(rec:get_status() == "> 1.25x", "forward 1.25x → '> 1.25x' (quarter rung shown faithfully)")

    stop_and_settle()
    rec:shuttle(-1)
    assert(rec:get_status() == "< 1.0x", "reverse 1x → '< 1.0x'")
    stop_and_settle()
    print("  PASS: stopped / > 1.0x / > 2.0x / < 1.0x")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-5  transport_mode lifecycle
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-5) transport_mode none→shuttle→none→play→none --")
do
    stop_and_settle()
    assert(rec.transport_mode == "none", "parked → transport_mode 'none'")

    rec:shuttle(1)
    assert(rec.transport_mode == "shuttle", "shuttle → 'shuttle'")
    stop_and_settle()
    assert(rec.transport_mode == "none", "stop → 'none'")

    rec:play()
    assert(rec.transport_mode == "play", "play → 'play'")
    stop_and_settle()
    assert(rec.transport_mode == "none", "stop → 'none'")
    print("  PASS: transport_mode lifecycle tracked")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-6  Boundary latch in shuttle; play mode does NOT latch
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-6) shuttle latches at end boundary; play does not --")
do
    stop_and_settle()
    rec:shuttle(1)  -- forward shuttle
    assert(rec.transport_mode == "shuttle", "shuttle mode")

    -- Deliver the END boundary through the engine's own C++→Lua callback,
    -- NOT stopped (C++ shuttle keeps ticking at the boundary).
    rec:_on_controller_position(LAST, false)
    assert(rec.latched, "shuttle at last frame must latch")
    assert(rec.latched_boundary == "end", "latched at the END boundary")
    assert(rec.state == "playing", "latched engine stays in the playing state")
    assert(rec:get_position() == LAST, "pinned at the last frame")
    stop_and_settle()

    -- Play mode reaching the same boundary does NOT latch — a real stop
    -- arrives instead (stopped=true). C++ boundary auto-stop flips
    -- m_playing false BEFORE reporting (displayLinkTick's exchange);
    -- mirror that order — the engine's stale-report guard correctly
    -- drops a stopped report whose controller still claims to play.
    rec:play()
    assert(rec.transport_mode == "play", "play mode")
    qt_constants.PLAYBACK.STOP(rec._playback_controller)
    rec:_on_controller_position(LAST, true)
    assert(not rec.latched, "play mode must NOT latch")
    assert(rec.state == "stopped", "play mode boundary stops")
    release_audio()
    print("  PASS: shuttle latches at end; play mode stops without latching")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-7  Latched: same-direction no-op; opposite-direction unlatches + resumes
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-7) latched: same-dir no-op, opposite-dir unlatch+resume --")
do
    -- Wrap the REAL PLAYBACK.PLAY to confirm the unlatch resumes the C++
    -- transport (records the call, then unconditionally delegates).
    local play_calls = 0
    local real_play = qt_constants.PLAYBACK.PLAY
    assert(type(real_play) == "function", "PLAYBACK.PLAY must exist")
    qt_constants.PLAYBACK.PLAY = function(...)
        play_calls = play_calls + 1
        return real_play(...)
    end

    stop_and_settle()
    rec:shuttle(1)
    rec:_on_controller_position(LAST, false)
    assert(rec.latched and rec.latched_boundary == "end", "fixture: latched at end")

    local pos_before = rec:get_position()
    rec:shuttle(1)  -- same direction as the boundary → no-op
    assert(rec.latched, "same-direction shuttle while latched stays latched")
    assert(rec:get_position() == pos_before, "same-direction shuttle changes nothing")

    local plays_before = play_calls
    rec:shuttle(-1)  -- opposite direction → unlatch + resume
    assert(not rec.latched, "opposite-direction shuttle unlatches")
    assert(rec.direction == -1, "resumed in the new direction")
    assert(rec.speed == 1, "unlatch resumes at 1x")
    assert(play_calls > plays_before, "unlatch kicks a real PLAYBACK.PLAY")

    qt_constants.PLAYBACK.PLAY = real_play  -- restore
    stop_and_settle()
    print("  PASS: same-dir no-op; opposite-dir unlatched, resumed at 1x reverse")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-8  Start-boundary latch: reverse shuttle pins frame 0 with boundary="start"
-- ════════════════════════════════════════════════════════════════════════════
-- The symmetric counterpart to TS-6's end-boundary latch. We enter reverse
-- shuttle and deliver the start-boundary position through the engine's own
-- C++→Lua callback SYNCHRONOUSLY (no CVDisplayLink runs headless, so the
-- boundary position never arrives organically). Sustained real
-- reverse-to-zero playback — including the once-poisonous follow-up Play —
-- is pinned end-to-end by test_reverse_to_zero_playback.lua (the AudioPump
-- reverse-past-zero assert and dead-thread-join bugs were fixed 2026-06-12).
print("\n-- (TS-8) reverse shuttle latches at the start boundary --")
do
    stop_and_settle()
    rec:shuttle(-1)  -- reverse shuttle
    assert(rec.transport_mode == "shuttle", "reverse shuttle is shuttle mode")
    assert(rec.direction == -1, "reversed")

    -- Deliver the START boundary (frame 0) synchronously, NOT stopped.
    rec:_on_controller_position(0, false)
    assert(rec.latched, "reverse shuttle reaching frame 0 must latch")
    assert(rec.latched_boundary == "start", "latched at the START boundary")
    assert(rec.state == "playing", "latched engine stays in the playing state")
    assert(rec:get_position() == 0, "pinned at frame 0")

    rec:stop()  -- clear via stop, not a forward Play (avoids the pump poison)
    assert(not rec.latched, "stop clears the latch")
    settle(); release_audio()
    print("  PASS: reverse shuttle latched at start with boundary='start'")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-9  Direction guards: shuttle(0) / slow_play(0) assert
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-9) shuttle(0) and slow_play(0) assert --")
do
    stop_and_settle()
    expect_assert(function() rec:shuttle(0) end, "shuttle(0)")
    expect_assert(function() rec:slow_play(0) end, "slow_play(0)")
    print("  PASS: a shuttle direction must be ±1")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-10  play() idempotent while playing; stop() idempotent while stopped
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-10) play/stop idempotence --")
do
    stop_and_settle()

    -- play() twice: second call is a clean no-op (still playing, no raise).
    rec:play()
    assert(rec:is_playing(), "first play → playing")
    rec:play()
    assert(rec:is_playing(), "second play is a no-op, still playing")
    stop_and_settle()

    -- stop() twice on an already-stopped engine: clean no-op.
    rec:stop()
    rec:stop()
    assert(not rec:is_playing(), "double stop leaves engine stopped")
    release_audio()
    print("  PASS: play() and stop() are idempotent")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-11  Audio conform speed ratio (fps conform domain math)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-11) audio conform ratio --")
do
    -- The record engine's sequence runs at 24000/1001. Media already at that
    -- exact video rate needs no conform → 1.0.
    local r_native = rec:_compute_audio_speed_ratio(
        { fps_numerator = 24000, fps_denominator = 1001 })
    assert(r_native == 1.0, string.format(
        "media at the sequence video rate needs no conform (1.0); got %s",
        tostring(r_native)))

    -- Audio-only media carries its sample rate where a video fps would be;
    -- there is no video cadence to conform to → 1.0.
    local r_audio_only = rec:_compute_audio_speed_ratio(
        { fps_numerator = 48000, fps_denominator = 1 })
    assert(r_audio_only == 1.0, string.format(
        "audio-only media needs no video conform (1.0); got %s",
        tostring(r_audio_only)))

    -- Garbage fps metadata must assert (no silent fallback).
    expect_assert(function()
        rec:_compute_audio_speed_ratio({ fps_numerator = nil, fps_denominator = 1 })
    end, "nil fps_numerator")
    expect_assert(function()
        rec:_compute_audio_speed_ratio({ fps_numerator = 24, fps_denominator = nil })
    end, "nil fps_denominator")
    expect_assert(function()
        rec:_compute_audio_speed_ratio({ fps_numerator = 24, fps_denominator = 0 })
    end, "zero fps_denominator")
    print("  PASS: native/audio-only conform to 1.0; nil/zero fps assert")
end

-- ════════════════════════════════════════════════════════════════════════════
-- TS-12  Frame-step audio burst guards (jog) — owner & stopped required
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (TS-12) frame-step burst only for a stopped audio owner --")
do
    -- Count bursts across BOTH burst entrypoints (real C++ PLAY_BURST and
    -- the Lua-fallback play_burst) via pass-through wrappers, so neither
    -- routing slips past the guard unobserved.
    local burst_calls = 0
    local real_play_burst = qt_constants.PLAYBACK.PLAY_BURST
    assert(type(real_play_burst) == "function", "PLAYBACK.PLAY_BURST must exist")
    local real_ap_burst = audio_playback.play_burst
    assert(type(real_ap_burst) == "function", "audio_playback.play_burst must exist")
    qt_constants.PLAYBACK.PLAY_BURST = function(...)
        burst_calls = burst_calls + 1
        return real_play_burst(...)
    end
    audio_playback.play_burst = function(...)
        burst_calls = burst_calls + 1
        return real_ap_burst(...)
    end

    -- Guard A: NOT the audio owner → no burst.
    stop_and_settle()
    assert(audio_playback.is_owner(rec) == false, "fixture: record not the owner")
    burst_calls = 0
    rec:play_frame_audio(30)
    assert(burst_calls == 0, "no burst when this engine does not own audio")

    -- Guard B: owner but PLAYING → no burst (jog is a stopped-only gesture).
    rec:play()
    assert(rec:is_playing() and audio_playback.is_owner(rec),
        "fixture: record is the playing owner")
    burst_calls = 0
    rec:play_frame_audio(30)
    assert(burst_calls == 0, "no burst while the owning engine is playing")

    qt_constants.PLAYBACK.PLAY_BURST = real_play_burst  -- restore
    audio_playback.play_burst = real_ap_burst
    stop_and_settle()
    print("  PASS: no burst when not owner; no burst while playing")
end

-- Leave the device idle + tear down for sibling tests in the same process.
rec:stop(); src:stop()
release_audio()
if transport.is_bootstrapped() then transport.shutdown() end
database.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_playback_transport_state_machine.lua")
os.exit(0)
