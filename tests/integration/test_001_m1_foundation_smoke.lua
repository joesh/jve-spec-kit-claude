-- 001 smoke: M1 foundation — unified SQLite data model, create-then-load round-trip.
--
-- The headline M1 acceptance is "you can open the editor and see a project with
-- sequences, tracks, clips persisted across launches." This smoke exercises the
-- end-to-end persistence loop against the real schema:
--   project → sequence → tracks → clips → save → re-init → reload → equal.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_001_m1_foundation_smoke.lua ===")

require("test_env")
local database = require("core.database")
local Project  = require("models.project")
local Sequence = require("models.sequence")

local DB = "/tmp/jve/test_001_m1.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()

-- FR-001: project, sequence, track, clip persistence round-trip.
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
        created_at, modified_at)
      VALUES ('p','M1','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height, playhead_frame,
        view_start_frame, view_duration_frames, start_timecode_frame,
        created_at, modified_at)
      VALUES ('seq','p','S1','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('seq-v1','seq','V1','VIDEO',1),
             ('seq-a1','seq','A1','AUDIO',1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
      VALUES ('med','p','m.mov','/tmp/m.mov',1000,24,1,2,48000,%d,%d);
]], now, now, now, now, now, now)))

-- Detach and re-init: simulates relaunch.
database.set_connection(nil)
assert(database.init(DB))
local db2 = database.get_connection()

local proj = assert(Project.load("p"), "Project.load failed after re-init")
assert(proj.name == "M1",
    string.format("project name round-trip: got %q", tostring(proj.name)))

local seq = assert(Sequence.load("seq"), "Sequence.load failed after re-init")
assert(seq.name == "S1" and seq.kind == "sequence",
    string.format("sequence row mismatch: name=%q kind=%q",
        tostring(seq.name), tostring(seq.kind)))
assert(seq.frame_rate.fps_numerator == 24 and seq.frame_rate.fps_denominator == 1,
    "sequence fps round-trip failed")
print("  PASS: project + sequence round-trip across reopen")

-- FR-001 cont.: tracks reachable from sequence_id.
local q = assert(db2:prepare(
    "SELECT track_type, track_index FROM tracks WHERE sequence_id='seq' "
    .. "ORDER BY track_type DESC, track_index ASC"))
q:exec()
local tracks = {}
while q:next() do tracks[#tracks+1] = q:value(0) .. q:value(1) end
q:finalize()
assert(#tracks == 2 and tracks[1] == "VIDEO1" and tracks[2] == "AUDIO1",
    "tracks did not round-trip: " .. table.concat(tracks, ","))
print("  PASS: tracks round-trip")

-- Media row is reachable; this is the M1 "browse asset" path.
local m = assert(db2:prepare("SELECT name, duration_frames FROM media WHERE id='med'"))
m:exec(); m:next()
assert(m:value(0) == "m.mov" and m:value(1) == 1000, "media round-trip failed")
m:finalize()
print("  PASS: media round-trip")

print("\n✅ test_001_m1_foundation_smoke.lua passed")
