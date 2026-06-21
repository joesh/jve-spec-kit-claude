-- Integration: a mute/solo toggle DURING live playback must not freeze the
-- transport. Dropping the ~2.6s of already-mixed PCM queued downstream of TMB
-- (the "flush" that lets the change be heard at the playhead) tears down the
-- audio output device; the flush path MUST bring the device back so playback
-- keeps advancing at real time.
--
-- THE BUG THIS PINS (2026-06-20): the flush mirrored a dead, never-exercised
-- C++ code path that called AudioOutput::Flush() (which stops the QAudioSink)
-- WITHOUT re-prefilling the ring and calling Start() again. The device stayed
-- dead: the audio buffer drained to empty, the controller's audio-master mode
-- locked video position to the frozen audio clock → the playhead went
-- slow-motion / froze and audio died until the user pressed stop then play
-- (which re-enters the real Play path and restarts the device).
--
-- DOMAIN RULE: after a mix change while playing, playback CONTINUES — the
-- playhead keeps advancing at roughly real time and the engine stays in the
-- playing state. Observed only through the live frame position over a
-- wall-clock interval; no internals are asserted.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_mix_change_keeps_playing.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_mix_change_keeps_playing.lua ===")

require("test_env")
local database     = require("core.database")
local transport    = require("core.playback.transport")
local qt_constants = require("core.qt_constants")
local Signals      = require("core.signals")

-- ── Fixture: timeline V1/A1 with a real VIDEO + AUDIO clip from decodable
--    media (2ch 48k) so audio ownership is real and the device runs.
local DB = "/tmp/jve/test_mix_change_keeps_playing.db"
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
      ('c_v','p','V','rec_v1','%s','rec',0,108,0,108,NULL,NULL,1,'resample',1.0,0,%d,%d),
      ('c_a','p','A','rec_a1','%s','rec',0,108,0,108,0,0,1,'resample',1.0,0,%d,%d)
]], master_id, now, now, master_id, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("p")
transport.bind_role_to_sequence("record", "rec")
local rec = transport.engine_for_role("record")
local pc = assert(rec._playback_controller,
    "precondition: a loaded engine MUST have a live C++ controller")

local surf = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(surf, "GPU surface creation failed — environment defect")
rec:set_surface(surf)

-- Drive real wall-clock time forward: sleep so the CVDisplayLink tick + audio
-- pump run, then drain the dispatch queue (frame delivery, callbacks).
local CONTROL = qt_constants.CONTROL
local function run_for(seconds)
    local steps = math.max(1, math.floor(seconds / 0.05))
    for _ = 1, steps do
        os.execute("sleep 0.05")
        CONTROL.PROCESS_EVENTS()
    end
end

local function pos()
    return qt_constants.PLAYBACK.CURRENT_FRAME(pc)
end

-- ── Start playing, let the pipeline warm up ─────────────────────────────────
rec:play()
run_for(0.4)
assert(rec:is_playing(), "precondition: engine must be playing after play()")

-- ── Baseline: measure the HEALTHY advance rate over a fixed window, BEFORE the
--    mix change. This self-calibrates the threshold to whatever rate this
--    machine actually achieves headless (no magic frame count baked in).
local MEASURE_S = 0.8
local posA = pos()
run_for(MEASURE_S)
local posB = pos()
local baseline = posB - posA
assert(baseline > 0, string.format(
    "precondition: playback must advance before the mix change (baseline=%d)", baseline))

-- ── Mute A1 mid-playback via the SAME signal production emits ───────────────
-- (toggle_track_preference emits track_preference_changed; the engine connects
--  _on_track_preference_changed_signal to it → _flush_audio_pipeline_for_mix_change.)
db:exec("UPDATE tracks SET muted=1 WHERE id='rec_a1'")
Signals.emit("track_preference_changed", "rec_a1", "muted", true, false)

-- ── Playback must keep running at ~the same rate across the flush ────────────
local posC = pos()
run_for(MEASURE_S)
local posD = pos()
assert(rec:is_playing(), "after a mute toggle, the engine must still be playing")
local after = posD - posC

-- The flush tears down + must rebuild the audio device. WITHOUT the restart the
-- device drains, the PLL drags video toward the frozen audio clock, and the
-- post-flush rate collapses to ~0.41 of baseline (measured). WITH the restart it
-- recovers to ~0.82 (the only loss is the one-time device-rebuild transient).
-- Threshold sits at the midpoint: comfortably above the bug, comfortably below
-- a healthy run with its transient.
local MIN_RATIO = 0.6
assert(after >= baseline * MIN_RATIO, string.format(
    "after a mute toggle the playhead must keep advancing at ~real time; it "
    .. "advanced %d frames in ~%.1fs vs a healthy baseline of %d (ratio %.2f, "
    .. "need >= %.2f). The audio device was torn down by the flush and never "
    .. "restarted → audio-master/PLL dragged video to the frozen audio clock.",
    after, MEASURE_S, baseline, after / baseline, MIN_RATIO))

print(string.format("  baseline=%d frames/%.1fs, post-flush=%d (ratio %.2f) — playback survived the mix change",
    baseline, MEASURE_S, after, after / baseline))

rec:stop()
transport.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_mix_change_keeps_playing.lua")
os.exit(0)
