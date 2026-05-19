-- 013 smoke: timeline placements as nested-sequence references.
--
-- Acceptance Scenario 1: drag a single-file V+A master onto the edit
-- timeline → exactly two linked clips appear (one video, one audio),
-- both pointing at the master; resolver chains through to the master's
-- media_refs and lands on the file's V/A streams.
--
-- Drives the actual Insert command (the production placement path),
-- inspects the resulting clip rows + their resolver chain end-to-end.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_013_nested_placement_smoke.lua ===")

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")
local Insert   = require("core.commands.insert")

local MEDIA_PATH = ienv.test_media_path("countdown_chirp_30s.mp4")
local FPS_NUM, FPS_DEN, SR = 25, 1, 48000
local DUR_FRAMES = 750
local SPF = SR * FPS_DEN / FPS_NUM

local DB = "/tmp/jve/test_013_nested_smoke.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":%d,"den":%d}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, start_timecode_frame, created_at, modified_at)
      VALUES ('m','p','M','master',%d,%d,NULL,320,240,0,%d,%d),
             ('e','p','E','sequence',%d,%d,%d,320,240,0,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index) VALUES
      ('m-v1','m','V1','VIDEO',1), ('m-a1','m','A1','AUDIO',1),
      ('e-v1','e','V1','VIDEO',1), ('e-a1','e','A1','AUDIO',1);
    UPDATE sequences SET default_video_layer_track_id='m-v1' WHERE id='m';
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator,
        fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('med','p','c.mp4','%s',%d,%d,%d,1,%d,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr-v','p','m','m-v1','med',0,%d,0,%d,1,1.0,0,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr-a','p','m','m-a1','med',0,%d,0,%d,%d,1,1.0,0,%d,%d);
]],
    FPS_NUM, FPS_DEN, now, now,
    FPS_NUM, FPS_DEN, now, now, FPS_NUM, FPS_DEN, SR, now, now,
    MEDIA_PATH, DUR_FRAMES, FPS_NUM, FPS_DEN, SR, now, now,
    DUR_FRAMES, DUR_FRAMES, now, now,
    DUR_FRAMES * SPF, DUR_FRAMES, SR, now, now)))

-- Insert master onto record sequence at frame 0.
local result = Insert.execute({
    sequence_id          = "e",
    source_sequence_id   = "m",
    sequence_start_frame = 0,
})

-- Exactly one V and one A clip on the record sequence.
local s = assert(db:prepare([[
    SELECT t.track_type, c.sequence_id, c.sequence_start_frame, c.duration_frames
    FROM clips c JOIN tracks t ON c.track_id = t.id
    WHERE t.sequence_id = 'e' ORDER BY t.track_type DESC]]))
s:exec()
local clips = {}
while s:next() do
    clips[#clips+1] = { kind=s:value(0), nested=s:value(1), tl=s:value(2), dur=s:value(3) }
end
s:finalize()
assert(#clips == 2, string.format("expected 2 clips (1V + 1A), got %d", #clips))
assert(clips[1].kind == "VIDEO" and clips[2].kind == "AUDIO",
    string.format("ordering: %s + %s", clips[1].kind, clips[2].kind))
assert(clips[1].nested == "m" and clips[2].nested == "m",
    "both clips must reference master 'm' as nested source")
assert(clips[1].tl == 0 and clips[1].dur == DUR_FRAMES and
       clips[2].tl == 0 and clips[2].dur == DUR_FRAMES,
    "both clips span [0, NATIVE_FRAMES) on the record sequence")
print("  PASS: 1 V + 1 A clip emitted, both linked to master 'm'")

-- Resolver chains all the way to the file via the master's media_refs.
local rec = Sequence.load("e")
local v_entries = rec:get_video_in_range(0, DUR_FRAMES)
local a_entries = rec:get_audio_in_range(0, DUR_FRAMES)
assert(#v_entries == 1 and v_entries[1].media_path == MEDIA_PATH,
    "video resolver entry must reach the chirp file")
assert(#a_entries == 1 and a_entries[1].media_path == MEDIA_PATH,
    "audio resolver entry must reach the chirp file")
print("  PASS: resolver reaches file via master.media_refs chain")

print("\n✅ test_013_nested_placement_smoke.lua passed")

-- Suppress unused 'result' var (Insert return shape varies)
assert(type(result) == "table", "Insert returned non-table")
