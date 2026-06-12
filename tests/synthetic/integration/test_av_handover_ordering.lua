-- Integration: FR-012 audio/video ordering invariants on side handover,
-- against REAL bindings (real engines, real AOP/SSE, real CVDisplayLink
-- controller, real decoded audio from fixture media).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_no_audio_dropout_when_switching_between_source_and_record.lua (I1)
--   test_video_does_not_appear_before_audio_when_switching_sides.lua   (I2)
-- Both originals replaced qt_constants functions with pure fakes inside the
-- stub harness, so they pinned the Lua call ordering against a fake FFI.
-- This version records the order of the REAL binding calls via pass-through
-- wrappers that unconditionally delegate, then restores the originals.
--
-- DOMAIN RULES PINNED (spec 017 FR-012):
--   I2  Cold play: the engine acquires its audio output (AOP.START or
--       PLAYBACK.ACTIVATE_AUDIO) BEFORE PLAYBACK.PLAY kicks the
--       CVDisplayLink frame pump — video must never appear before audio
--       is ready.
--   I1  Handover record→source: a halt event for the old side (AOP.STOP or
--       PLAYBACK.DEACTIVATE_AUDIO) precedes the new side's start event
--       (AOP.START or PLAYBACK.PLAY) — at no point do both sides own the
--       audio device (no overlap, hence no dropout/garble).
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_av_handover_ordering.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_av_handover_ordering.lua ===")

require("test_env")
local database     = require("core.database")
local transport    = require("core.playback.transport")
local qt_constants = require("core.qt_constants")

-- ── Fixture: timeline with VIDEO + AUDIO clips (real decodable media with
--    2ch 48k audio) and a master for the source side ──────────────────────
local DB = "/tmp/jve/test_av_handover_integ.db"
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
assert(db:exec(string.format([[
  INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
      sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
      source_in_subframe, source_out_subframe,
      enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
  VALUES
    ('c_v','p','V','rec_v1','%s','rec',0,96,0,96,NULL,NULL,1,'resample',1.0,0,%d,%d),
    ('c_a','p','A','rec_a1','%s','rec',0,96,0,96,0,0,1,'resample',1.0,0,%d,%d)
]], master_id, now, now, master_id, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("p")
transport.bind_role_to_sequence("record", "rec")
transport.bind_role_to_sequence("source", master_id)
local rec = transport.engine_for_role("record")
local src = transport.engine_for_role("source")

local s1 = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
local s2 = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(s1 and s2, "GPU surface creation failed — environment defect")
rec:set_surface(s1)
src:set_surface(s2)

local function pump(sec)
    local until_t = os.time() + sec
    while os.time() <= until_t do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.05")
    end
end

-- ── Pass-through event recorder over the REAL bindings ──────────────────
-- Each wrapper records its event name then unconditionally delegates to
-- the saved real function. install() asserts the real functions exist;
-- restore() puts them back.
local AOP, PLAYBACK = qt_constants.AOP, qt_constants.PLAYBACK
local WRAPPED = {
    { tbl = AOP,      key = "START",            event = "AOP.START" },
    { tbl = AOP,      key = "STOP",             event = "AOP.STOP" },
    { tbl = PLAYBACK, key = "PLAY",             event = "PLAYBACK.PLAY" },
    { tbl = PLAYBACK, key = "ACTIVATE_AUDIO",   event = "PLAYBACK.ACTIVATE_AUDIO" },
    { tbl = PLAYBACK, key = "DEACTIVATE_AUDIO", event = "PLAYBACK.DEACTIVATE_AUDIO" },
}
local event_log = {}
local function install_recorder()
    event_log = {}
    for _, w in ipairs(WRAPPED) do
        local real = w.tbl[w.key]
        assert(type(real) == "function", string.format(
            "recorder: real binding %s must exist", w.event))
        w.real = real
        w.tbl[w.key] = function(...)
            event_log[#event_log + 1] = w.event
            return real(...)
        end
    end
end
local function restore_recorder()
    for _, w in ipairs(WRAPPED) do
        w.tbl[w.key] = assert(w.real, "recorder: restore before install")
        w.real = nil
    end
end
local function first_index(events, names)
    local want = {}
    for _, n in ipairs(names) do want[n] = true end
    for i, e in ipairs(events) do
        if want[e] then return i end
    end
    return nil
end

-- ── I2: cold play — audio acquired before the frame pump starts ─────────
print("\n-- (I2) cold play: audio acquire precedes PLAYBACK.PLAY --")
do
    install_recorder()
    src:play()
    local log = table.concat(event_log, ",")
    restore_recorder()

    local audio_at = first_index(event_log, { "AOP.START", "PLAYBACK.ACTIVATE_AUDIO" })
    local video_at = first_index(event_log, { "PLAYBACK.PLAY" })
    assert(audio_at, "I2: expected an audio-acquire event; saw " .. log)
    assert(video_at, "I2: expected PLAYBACK.PLAY; saw " .. log)
    assert(audio_at < video_at, string.format(
        "FR-012 I2 audio-before-video: audio_at=%d video_at=%d log=%s",
        audio_at, video_at, log))
    pump(1)
    assert(src:is_playing(), "I2: source must be playing with real audio fed")
    print("  PASS order: " .. log)
end

-- ── I1: handover source→record — halt precedes the new side's start ─────
print("\n-- (I1) handover: old side halts before new side starts --")
do
    install_recorder()
    src:stop()
    rec:play()
    local log = table.concat(event_log, ",")
    restore_recorder()

    local halt_at  = first_index(event_log, { "AOP.STOP", "PLAYBACK.DEACTIVATE_AUDIO" })
    local start_at = first_index(event_log, { "AOP.START", "PLAYBACK.PLAY" })
    assert(halt_at, "I1: expected a halt event during handover; saw " .. log)
    assert(start_at, "I1: expected a start event during handover; saw " .. log)
    assert(halt_at < start_at, string.format(
        "FR-012 I1 no-overlap: halt must precede start; halt_at=%d start_at=%d log=%s",
        halt_at, start_at, log))
    pump(1)
    assert(rec:is_playing(), "I1: record must be playing after handover")
    print("  PASS order: " .. log)
end

rec:stop()
transport.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_av_handover_ordering.lua")
