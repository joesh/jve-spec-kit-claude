-- Integration regression: playing a sequence whose AUDIO track has no
-- audio content must play (and stop) without crashing.
--
-- Domain rule: an editor timeline routinely has enabled audio tracks with
-- gaps or no clips at the playhead. Pressing play there is the most
-- ordinary of operations — silence is the correct audible result, and the
-- process must survive it.
--
-- Bug this pins (found 2026-06-11 during the transport/AV stub-test
-- conversion): with an AUDIO track present and no fed audio content,
-- engine:play() deterministically SIGSEGV'd the background AudioPump
-- thread inside sse::ScrubStretchEngine::PushSourcePcm (repro 3/3). The
-- two I1/I2 FFI-ordering stub tests remain unconverted until this passes.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_audio_play_unfed_no_crash.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_audio_play_unfed_no_crash.lua ===")

require("test_env")
local database  = require("core.database")
local transport = require("core.playback.transport")
local qt_constants = require("core.qt_constants")

local DB = "/tmp/jve/test_audio_unfed_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('media_u', 'proj', %q, 'U', 108, 24000, 1001, 640, 360, 2, 48000, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('tl_u', 'proj', 'Timeline', 'sequence', 24000, 1001, 48000, 640, 360,
              0, 300, 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('tl_u_v1', 'tl_u', 'V1', 'VIDEO', 1, 1),
             ('tl_u_a1', 'tl_u', 'A1', 'AUDIO', 1, 1);
]], now, now, media_path, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "proj", "U", 24000, 1001, 108, "media_u")

-- One VIDEO clip so the timeline has real playable extent; the AUDIO
-- track stays empty — that emptiness is the scenario under test.
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
    VALUES ('clip_u_v', 'proj', 'V', 'tl_u_v1', '%s', 'tl_u',
            0, 96, 0, 96, 1, 'resample', 1.0, 0, %d, %d)
]], master_id, now, now)))

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("proj")
transport.bind_role_to_sequence("record", "tl_u")
local rec = transport.engine_for_role("record")

local surf = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(surf, "GPU surface creation failed — environment defect")
rec:set_surface(surf)

print("  playing 1.5s of video-only content over an empty AUDIO track...")
rec:play()
assert(rec:is_playing(), "engine must enter playing state")

-- Let the AudioPump thread run long enough to hit the unfed-audio path
-- several times. The bug crashes the PROCESS (SIGSEGV on the pump
-- thread), so simply surviving this window with a clean stop IS the test.
local play_until = os.time() + 2
while os.time() <= play_until do
    qt_constants.CONTROL.PROCESS_EVENTS()
    os.execute("sleep 0.05")
end

rec:stop()
assert(not rec:is_playing(), "engine must stop cleanly")

transport.shutdown()

print("\nPASS test_audio_play_unfed_no_crash.lua")
