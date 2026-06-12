-- Integration regression: sustained REVERSE playback reaching time 0 must
-- clamp at the start boundary and leave the process fully playable.
--
-- Domain rule: holding reverse (J / reverse shuttle) until the playhead
-- hits the start of the sequence is ordinary NLE behavior — playback pins
-- at frame 0, and the very next play gesture (any direction) must work.
--
-- Bugs this pins (found 2026-06-11, memory
-- todo_audiopump_reverse_past_zero_and_dead_thread_poison):
--   1. AudioPump::pumpLoop asserted push_start >= 0 — "unexpected reverse
--      past time 0" — contradicting its own comment AND the negative-floor
--      branch right below it. Real reverse-to-zero killed the pump thread.
--   2. The dead pump thread was left joinable; AudioPump::Stop() early-
--      returns on !m_running without joining, so the NEXT AudioPump::Start
--      reassigned a joinable std::thread → std::terminate → process abort.
--      Net effect: reverse-to-zero poisoned the process; the first
--      subsequent play() aborted it.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_reverse_to_zero_playback.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_reverse_to_zero_playback.lua ===")

require("test_env")
local database     = require("core.database")
local transport    = require("core.playback.transport")
local qt_constants = require("core.qt_constants")

local DB = "/tmp/jve/test_rev_zero_integ.db"
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
local rec = transport.engine_for_role("record")
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

-- ── Phase 1: sustained real reverse playback into the start boundary ────
print("  reverse shuttle from frame 12 down through time 0...")
rec:seek(12)
rec:shuttle(-1)
assert(rec.direction == -1, "fixture: engine must be in reverse")
-- 12 frames at ~24fps reverse = ~0.5s to the boundary; give the real
-- pump generous wall-clock to cross time 0 several times over.
pump(3)

-- ── Phase 2: the very next play gesture must work ────────────────────────
-- Pre-fix, the dead pump thread made this abort the whole process
-- (std::terminate in AudioPump::Start); surviving it IS the regression.
print("  forward play after reverse-to-zero...")
rec:stop()
rec:play()
pump(1)
assert(rec:is_playing(),
    "after reverse-to-zero, a subsequent forward play must work")
rec:stop()

transport.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_reverse_to_zero_playback.lua")
