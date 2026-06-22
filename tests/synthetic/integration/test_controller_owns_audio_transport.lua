-- Integration: with the C++ PlaybackController active, transport gestures
-- drive the C++ binding and NEVER drive the Lua audio device's transport
-- directly. Verified against REAL bindings (real engine, real controller,
-- real audio_playback device, real decoded media).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_playback_controller_audio_guards.lua
--
-- The original was WHITE-BOX, fully-mocked: it stubbed qt_constants
-- (PLAYBACK + EMP), models.sequence, models.track, signals, and the audio
-- module, then called PRIVATE methods (_start_audio / _stop_audio /
-- _sync_audio) and asserted they were no-ops "when a controller is active",
-- plus a branch where it manually nilled _playback_controller to assert the
-- opposite. It pinned the Lua→stub routing, not domain behavior.
--
-- DOMAIN RULE PINNED (017 FR-013 / audio-ownership architecture):
--   While the C++ PlaybackController owns audio transport, a transport
--   gesture moves the C++ side (PLAYBACK.PLAY / PARK / STOP) and the Lua
--   layer must NOT reach down to the audio DEVICE's transport (the
--   audio_playback seek/start/stop/set_speed calls). Those device calls are
--   the legacy Lua-drives-audio path; with a controller present, driving
--   them too would fight C++ for the device → the dropout/garble the 017
--   single-owner handover exists to prevent.
--
-- OBSERVATION METHOD (no fakes — pass-through recorders only):
--   Two recorder sets, each wrapping the REAL function, recording the call,
--   then UNCONDITIONALLY delegating, and restored afterward:
--     • qt_constants.PLAYBACK.{PLAY,PARK,STOP} — to prove the gesture
--       reached the C++ controller (positive evidence).
--     • audio_playback.{seek,start,stop,set_speed} — to prove the Lua
--       transport path did NOT touch the device (negative evidence).
--
-- SCENARIO MAP (original → disposition):
--   §1 _start_audio no-op w/ controller    → folded into CA-2 (play): the
--        observable is "play() doesn't call device.start/seek"; the private
--        guard is the implementation of that.
--   §2 _stop_audio no-op w/ controller     → folded into CA-4 (stop): "stop()
--        doesn't call device.stop directly".
--   §3 _sync_audio no-op w/ controller     → folded into CA-3 (shuttle):
--        "shuttle doesn't call device.set_speed".
--   §4 shuttle unlatch → PLAY, no device   → CA-3.
--   §5 seek stopped → PARK, no device.seek  → CA-1.
--   §6 notify_content_changed → RELOAD_ALL  → CA-5.
--   §9 play → PLAY, no device.start         → CA-2.
--   §10 load_sequence → SET_CLIP_PROVIDER   → CA-6.
--   §14 "_start_audio DOES call device when NO controller" → DROPPED. The
--        original forced engine._playback_controller=nil after a real load.
--        Under 017 that's an impossible state: loaded_sequence_id ~= nil
--        ⟺ _playback_controller ~= nil (pinned by DR-11 in
--        test_playback_engine_contract.lua). The no-controller transport
--        branch is dead under the real architecture; reproducing it requires
--        faking the engine into a corrupt half-state. Unconvertible.
--
-- OPEN QUESTIONS:
--   None.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_controller_owns_audio_transport.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_controller_owns_audio_transport.lua ===")

require("test_env")
local database      = require("core.database")
local transport     = require("core.playback.transport")
local qt_constants  = require("core.qt_constants")
local audio_playback = require("core.media.audio_playback")

-- ── Fixture: timeline V1/A1 with a real VIDEO + AUDIO clip from decodable
--    media (2ch 48k) so audio ownership is real and the controller is live.
local DB = "/tmp/jve/test_ctrl_owns_audio.db"
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
-- A VIDEO clip and an AUDIO clip, both non-trivial: source span offset from
-- zero, full-resolution audio sub-frames so the audio device has real content.
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('c_v','p','V','rec_v1','%s','rec',0,96,4,100,NULL,NULL,1,'resample',1.0,0,%d,%d),
      ('c_a','p','A','rec_a1','%s','rec',0,96,4,100,0,0,1,'resample',1.0,0,%d,%d)
]], master_id, now, now, master_id, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("p")
transport.bind_role_to_sequence("record", "rec")
local rec = transport.engine_for_role("record")
assert(rec._playback_controller,
    "precondition: a loaded engine MUST have a live C++ controller (DR-11 invariant)")

local surf = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(surf, "GPU surface creation failed — environment defect")
rec:set_surface(surf)

local function pump(sec)
    local until_t = os.time() + sec
    while os.time() <= until_t do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.05")
    end
end

-- ── Pass-through recorders over the REAL bindings ───────────────────────────
-- Each wrapper records the call, then UNCONDITIONALLY delegates to the saved
-- real function. install() asserts the reals exist; restore() puts them back.
local PLAYBACK = qt_constants.PLAYBACK

-- Controller transport bindings (positive evidence the gesture hit C++).
local PB_WATCH = { "PLAY", "PARK", "STOP", "SET_SPEED" }
-- Audio DEVICE transport methods (negative evidence: must stay untouched).
local DEV_WATCH = { "seek", "start", "stop", "set_speed" }

local pb_log, dev_log = {}, {}
local pb_saved, dev_saved = {}, {}

local function install_recorders()
    pb_log, dev_log = {}, {}
    for _, key in ipairs(PB_WATCH) do
        local real = PLAYBACK[key]
        assert(type(real) == "function",
            "recorder: real PLAYBACK." .. key .. " must exist")
        pb_saved[key] = real
        PLAYBACK[key] = function(...)
            pb_log[#pb_log + 1] = key
            return real(...)
        end
    end
    for _, key in ipairs(DEV_WATCH) do
        local real = audio_playback[key]
        assert(type(real) == "function",
            "recorder: real audio_playback." .. key .. " must exist")
        dev_saved[key] = real
        audio_playback[key] = function(...)
            dev_log[#dev_log + 1] = key
            return real(...)
        end
    end
end

local function restore_recorders()
    for _, key in ipairs(PB_WATCH) do
        PLAYBACK[key] = assert(pb_saved[key], "restore before install: PLAYBACK." .. key)
        pb_saved[key] = nil
    end
    for _, key in ipairs(DEV_WATCH) do
        audio_playback[key] = assert(dev_saved[key], "restore before install: audio_playback." .. key)
        dev_saved[key] = nil
    end
end

local function pb_called(key)
    for _, k in ipairs(pb_log) do if k == key then return true end end
    return false
end
local function dev_called(key)
    for _, k in ipairs(dev_log) do if k == key then return true end end
    return false
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-1  seek while parked → C++ PARK; never the device's seek.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-1) parked seek → PARK, no device.seek --")
do
    rec:stop()  -- ensure parked
    install_recorders()
    rec:seek(40)
    restore_recorders()

    assert(pb_called("PARK"), "CA-1: seek() must delegate to PLAYBACK.PARK")
    assert(not dev_called("seek"),
        "CA-1: parked seek must NOT call the audio device's seek (C++ owns transport)")
    print("  PASS: seek → PARK; device.seek untouched")
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-2  play → C++ PLAY; never the device's start/seek.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-2) play → PLAY, no device.start/seek --")
do
    rec:stop()
    install_recorders()
    rec:play()
    restore_recorders()

    assert(pb_called("PLAY"), "CA-2: play() must delegate to PLAYBACK.PLAY")
    assert(not dev_called("start"),
        "CA-2: play() must NOT call the audio device's start (C++ owns transport)")
    assert(not dev_called("seek"),
        "CA-2: play() must NOT call the audio device's seek")

    pump(1)
    assert(rec:is_playing(), "CA-2: engine must actually be playing")
    print("  PASS: play → PLAY; device start/seek untouched")
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-3  shuttle while already playing → C++ SET_SPEED (lightweight);
-- never the device's set_speed. The old behavior was PLAY-per-keypress, which
-- re-ran the ~200ms CoreAudio device restart on each L press and froze video;
-- spec 025 FR-003 + playback_engine_transport.lua:96 document the change.
-- Cold-start shuttle (was_stopped) still routes through PLAY to anchor the
-- device + SSE + clock fresh; that path is covered by CA-1.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-3) mid-play shuttle → SET_SPEED, no device.set_speed --")
do
    -- rec is playing from CA-2.
    assert(rec:is_playing(), "CA-3 precondition: engine playing")
    install_recorders()
    rec:shuttle(1)  -- bump shuttle speed (same direction → faster)
    restore_recorders()

    assert(pb_called("SET_SPEED"),
        "CA-3: mid-play shuttle must delegate to PLAYBACK.SET_SPEED (lightweight, no device restart)")
    assert(not pb_called("PLAY"),
        "CA-3: mid-play shuttle must NOT re-enter PLAYBACK.PLAY (would 200ms-freeze video)")
    assert(not dev_called("set_speed"),
        "CA-3: shuttle must NOT call the audio device's set_speed (C++ owns transport)")
    print("  PASS: shuttle → SET_SPEED; PLAY untouched; device.set_speed untouched")
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-4  stop → C++ STOP; never the device's stop directly.
--
-- Domain: on stop the engine releases audio ownership through the controller
-- (DEACTIVATE_AUDIO inside the controller path), NOT by calling the device's
-- own stop — that is the legacy Lua-drives-audio call the guard suppresses
-- while a controller is present.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-4) stop → STOP, no device.stop --")
do
    assert(rec:is_playing(), "CA-4 precondition: engine playing")
    install_recorders()
    rec:stop()
    restore_recorders()

    assert(pb_called("STOP"), "CA-4: stop() must delegate to PLAYBACK.STOP")
    assert(not dev_called("stop"),
        "CA-4: stop() must NOT call the audio device's stop directly (C++ owns transport)")
    assert(not rec:is_playing(), "CA-4: engine must be stopped")
    print("  PASS: stop → STOP; device.stop untouched")
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-5  notify_content_changed → C++ RELOAD_ALL_CLIPS.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-5) notify_content_changed → RELOAD_ALL_CLIPS --")
do
    local reload_seen = false
    local real_reload = PLAYBACK.RELOAD_ALL_CLIPS
    assert(type(real_reload) == "function",
        "precondition: real PLAYBACK.RELOAD_ALL_CLIPS must exist")
    PLAYBACK.RELOAD_ALL_CLIPS = function(...)
        reload_seen = true
        return real_reload(...)
    end

    rec:notify_content_changed()

    PLAYBACK.RELOAD_ALL_CLIPS = real_reload
    assert(reload_seen,
        "CA-5: notify_content_changed must delegate to PLAYBACK.RELOAD_ALL_CLIPS")
    print("  PASS: notify_content_changed → RELOAD_ALL_CLIPS")
end

-- ════════════════════════════════════════════════════════════════════════════
-- CA-6  loading a sequence wires the C++ clip provider (SET_CLIP_PROVIDER).
--
-- The provider callback is how the C++ prefetch pulls clips back into the
-- TMB; without it the controller has no clips to decode. Observe a fresh
-- bind of the source role to a sequence with the recorder installed.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (CA-6) load wires SET_CLIP_PROVIDER --")
do
    local provider_seen = false
    local real_set_provider = PLAYBACK.SET_CLIP_PROVIDER
    assert(type(real_set_provider) == "function",
        "precondition: real PLAYBACK.SET_CLIP_PROVIDER must exist")
    PLAYBACK.SET_CLIP_PROVIDER = function(...)
        provider_seen = true
        return real_set_provider(...)
    end

    transport.bind_role_to_sequence("source", master_id)

    PLAYBACK.SET_CLIP_PROVIDER = real_set_provider
    assert(provider_seen,
        "CA-6: loading a sequence must wire the C++ clip provider via SET_CLIP_PROVIDER")
    print("  PASS: load → SET_CLIP_PROVIDER")
end

transport.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_controller_owns_audio_transport.lua")
os.exit(0)
