-- Regression test — payload_builder consumes the REAL shapes the models
-- return (spec 023, T024 SendToResolve supply chain).
--
-- History: SendToResolve died on every send because payload_builder read
-- fields that don't exist on loaded model objects (flat seq.fps_numerator
-- instead of seq.frame_rate.fps_numerator — fixed in 4450c1c9 without a
-- test; media.start_tc_frame / media.duration_frames, which Media.load
-- never sets). This test is black-box: build the payload for a
-- DB-persisted NTSC sequence and assert the payload carries the values
-- the DRT must carry, derived from domain rules (NTSC rational rate,
-- TC-origin arithmetic) — not from tracing the builder.
--
-- Domain expectations:
--   • A 29.97 NTSC sequence advertises exactly 30000/1001 fps — the
--     rational must survive (FR-020: floats like 29.97 corrupt conform).
--   • A media file whose first frame is TC 01:00:00:00 (NDF) has a TC
--     origin of 108000 frames; the payload must carry that origin so the
--     writer can convert the clip's absolute source TC to file-relative.
--   • Media duration rides along in native frames.

require("test_env")

local database = require("core.database")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== payload_builder Tests ===")

local db_path = "/tmp/jve/test_payload_builder.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

-- NTSC 29.97: exactly 30000/1001 (domain constant, not traced from code)
local NTSC_NUM, NTSC_DEN = 30000, 1001
-- TC 01:00:00:00 non-drop @ 29.97 = 1*60*60*30 frame counts
local MEDIA_TC_ORIGIN = 108000
local MEDIA_DURATION = 2878
-- Clip window: absolute source TC, 431 frames into the file
local CLIP_SOURCE_IN = MEDIA_TC_ORIGIN + 431
local CLIP_DURATION = 96
local CLIP_SOURCE_OUT = CLIP_SOURCE_IN + CLIP_DURATION
local CLIP_SEQ_START = 240

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":30000,"den":1001}}',
        %d, %d);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        rotation, audio_channels, codec, is_still, metadata,
        created_at, modified_at)
    VALUES ('m1', 'p', 'A005_C012', '/footage/A005_C012.mov', %d,
        %d, %d, 0, 1920, 1080, 0, 0, 'prores',
        0, '{"start_tc_value":%d,"start_tc_rate":%d}', %d, %d);

    -- Master sequence (video-only: audio_sample_rate NULL is legal)
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_master', 'p', 'A005_C012', 'master',
        %d, %d, NULL, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_master_v1', 'seq_master', 'V1', 'VIDEO', 1,
        1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'trk_master_v1'
        WHERE id = 'seq_master';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, audio_sample_rate, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('mr1', 'p', 'seq_master', 'trk_master_v1',
        'm1', 0, %d, 0, %d, NULL, 1, 1.0, 0, %d, %d);

    -- Editing sequence whose clip references the master
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_edit', 'p', 'Edit 1', 'sequence',
        %d, %d, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_edit_v1', 'seq_edit', 'V1', 'VIDEO', 1,
        1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'trk_edit_v1'
        WHERE id = 'seq_edit';

    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c1', 'p', 'A005_C012', 'trk_edit_v1', 'seq_edit',
        'seq_master', %d, %d, %d, %d, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]],
    now, now,
    MEDIA_DURATION, NTSC_NUM, NTSC_DEN, MEDIA_TC_ORIGIN, NTSC_NUM, now, now,
    NTSC_NUM, NTSC_DEN, now, now,
    MEDIA_DURATION, MEDIA_DURATION, now, now,
    NTSC_NUM, NTSC_DEN, now, now,
    CLIP_SEQ_START, CLIP_DURATION, CLIP_SOURCE_IN, CLIP_SOURCE_OUT,
    now, now)), "fixture SQL failed")

local payload_builder = require("core.resolve_bridge.payload_builder")

-- ─── happy path: full payload from a persisted NTSC sequence ────────
local payload = payload_builder.build(db, "p", "seq_edit")

local NTSC_FPS = NTSC_NUM / NTSC_DEN
check("project fps is exactly 30000/1001",
    payload.project.fps == NTSC_FPS)
check("sequence fps is exactly 30000/1001",
    payload.sequence.fps == NTSC_FPS)
check("project name carried", payload.project.name == "P")
check("sequence name carried", payload.sequence.name == "Edit 1")

check("exactly one media ref", #payload.media_refs == 1)
local mref = payload.media_refs[1]
check("media ref keyed by media id", mref and mref.file_uuid == "m1")
check("media TC origin is 01:00:00:00 NDF (108000 frames)",
    mref and mref.start_tc_frame == MEDIA_TC_ORIGIN)
check("media duration in native frames",
    mref and mref.duration_frames == MEDIA_DURATION)
check("media native rate is exactly 30000/1001",
    mref and mref.native_rate == NTSC_FPS)
check("media path carried",
    mref and mref.path == "/footage/A005_C012.mov")

check("one video track", #payload.sequence.tracks == 1
    and payload.sequence.tracks[1].type == "video")
local clips = payload.sequence.tracks[1]
    and payload.sequence.tracks[1].clips or {}
check("one clip on the track", #clips == 1)
local c = clips[1]
check("clip id carried", c and c.id == "c1")
check("clip source_in is absolute TC",
    c and c.source_in == CLIP_SOURCE_IN)
check("clip source_out is absolute TC",
    c and c.source_out == CLIP_SOURCE_OUT)
check("clip timeline position carried",
    c and c.sequence_start == CLIP_SEQ_START)
check("clip duration carried", c and c.duration == CLIP_DURATION)
check("clip media link carried", c and c.media_uuid == "m1")

-- ─── error path: empty sequence refuses loudly ──────────────────────
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_empty', 'p', 'Empty', 'sequence',
        %d, %d, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], NTSC_NUM, NTSC_DEN, now, now)), "empty-seq fixture failed")

local ok_empty, err_empty = pcall(payload_builder.build, db, "p", "seq_empty")
check("trackless sequence fails loudly",
    not ok_empty and tostring(err_empty):find("no tracks") ~= nil)

-- ─── error path: unknown sequence asserts with the id ────────────────
local ok_missing, err_missing =
    pcall(payload_builder.build, db, "p", "seq_nope")
check("unknown sequence asserts and names the id",
    not ok_missing and tostring(err_missing):find("seq_nope") ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_payload_builder.lua had failures")
print("✅ test_payload_builder.lua passed")
