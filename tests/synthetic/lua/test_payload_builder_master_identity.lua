-- Regression test — payload pool items are keyed by SOURCE-CLIP identity
-- (the master's import_uuid), not by the physical media file (spec 023,
-- outbound half of the source-clip identity move).
--
-- Domain: after the inbound dedup, `media` is one row PER FILE. A synced
-- source clip and its plain-camera counterpart over a single .mov are two
-- distinct source clips (two masters) that SHARE one media row. When such
-- a timeline is sent back to Resolve, each source clip must reappear as its
-- own media-pool item (Resolve's bin shows them as distinct items — Joe
-- confirmed). So:
--   • two masters over one file ⇒ TWO pool items, same file_path, distinct
--     identity (the master's import_uuid);
--   • each timeline clip's media link is its master's identity, so the two
--     clips don't collapse onto one pool item.
-- A native (never-imported) master carries no import_uuid; its identity
-- falls back to the master's own id.
--
-- Black-box: build the payload from a persisted DB and assert the pool-item
-- identities and per-clip links — derived from the domain rule above, not
-- from tracing payload_builder.

require("test_env")

local database = require("core.database")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== payload_builder master-identity Tests ===")

local db_path = "/tmp/jve/test_payload_builder_master_identity.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local NUM, DEN = 24000, 1001            -- 23.976
local MOV_TC_ORIGIN = 86400             -- 01:00:00:00 @ 24 nominal (non-trivial)
local MOV_DURATION = 1500
local SYNC_ID  = "POOL-DBID-SYNC"       -- synced master's import_uuid
local PLAIN_ID = "POOL-DBID-PLAIN"      -- plain master's import_uuid
local A_IN  = MOV_TC_ORIGIN + 120
local A_OUT = A_IN + 96
local B_IN  = MOV_TC_ORIGIN + 600
local B_OUT = B_IN + 48

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24000,"den":1001}}',
        %d, %d);

    -- ONE physical file, shared by both source clips (post-dedup model)
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        rotation, audio_channels, codec, is_still, metadata,
        created_at, modified_at)
    VALUES ('m_mov', 'p', 'A008_C011', '/footage/A008_C011.mov', %d,
        %d, %d, 48000, 1920, 1080, 0, 2, 'prores',
        0, '{"start_tc_value":%d,"start_tc_rate":24}', %d, %d);

    -- Synced master (import_uuid = its Resolve pool DbId)
    INSERT INTO sequences (id, project_id, name, kind, import_uuid,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('sm_sync', 'p', 'A008_C011 [synced]', 'master', '%s',
        %d, %d, NULL, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_sync_v1', 'sm_sync', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'trk_sync_v1'
        WHERE id = 'sm_sync';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, audio_sample_rate, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('mr_sync', 'p', 'sm_sync', 'trk_sync_v1',
        'm_mov', 0, %d, 0, %d, NULL, 1, 1.0, 0, %d, %d);

    -- Plain master over the SAME file (distinct import_uuid)
    INSERT INTO sequences (id, project_id, name, kind, import_uuid,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('sm_plain', 'p', 'A008_C011', 'master', '%s',
        %d, %d, NULL, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_plain_v1', 'sm_plain', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'trk_plain_v1'
        WHERE id = 'sm_plain';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, audio_sample_rate, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('mr_plain', 'p', 'sm_plain', 'trk_plain_v1',
        'm_mov', 0, %d, 0, %d, NULL, 1, 1.0, 0, %d, %d);

    -- Editing sequence: one clip from each source clip
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_edit', 'p', 'Edit 1', 'sequence',
        %d, %d, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_edit_v1', 'seq_edit', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'trk_edit_v1'
        WHERE id = 'seq_edit';

    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('clip_a', 'p', 'A008_C011 [synced]', 'trk_edit_v1', 'seq_edit',
        'sm_sync', 0, %d, %d, %d, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('clip_b', 'p', 'A008_C011', 'trk_edit_v1', 'seq_edit',
        'sm_plain', %d, %d, %d, %d, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]],
    now, now,
    MOV_DURATION, NUM, DEN, MOV_TC_ORIGIN, now, now,
    SYNC_ID, NUM, DEN, now, now,
    MOV_DURATION, MOV_DURATION, now, now,
    PLAIN_ID, NUM, DEN, now, now,
    MOV_DURATION, MOV_DURATION, now, now,
    NUM, DEN, now, now,
    (A_OUT - A_IN), A_IN, A_OUT, now, now,
    (A_OUT - A_IN), (B_OUT - B_IN), B_IN, B_OUT, now, now)),
    "fixture SQL failed")

local payload_builder = require("core.resolve_bridge.payload_builder")
local payload = payload_builder.build(db, "p", "seq_edit")

-- Two source clips over one file ⇒ two pool items, distinct identity.
check("two media pool items (one per source clip, not one per file)",
    #payload.media_refs == 2)

local by_uuid = {}
for _, mref in ipairs(payload.media_refs) do
    by_uuid[mref.file_uuid] = mref
end
check("pool item keyed by synced master's import_uuid",
    by_uuid[SYNC_ID] ~= nil)
check("pool item keyed by plain master's import_uuid",
    by_uuid[PLAIN_ID] ~= nil)
check("both pool items resolve to the SAME physical file",
    by_uuid[SYNC_ID] and by_uuid[PLAIN_ID]
    and by_uuid[SYNC_ID].file_path == "/footage/A008_C011.mov"
    and by_uuid[PLAIN_ID].file_path == "/footage/A008_C011.mov")
check("pool items carry the shared file's native rate",
    by_uuid[SYNC_ID] and by_uuid[SYNC_ID].native_rate == NUM / DEN)
check("pool items carry the shared file's TC origin",
    by_uuid[SYNC_ID] and by_uuid[SYNC_ID].start_tc_frame == MOV_TC_ORIGIN)

-- Per-clip media link is the master identity, so the two clips don't
-- collapse onto a single pool item.
local clips = payload.sequence.tracks[1] and payload.sequence.tracks[1].clips
    or {}
check("two clips on the edit track", #clips == 2)
local link = {}
for _, c in ipairs(clips) do link[c.id] = c.media_uuid end
check("synced clip links to synced master identity",
    link.clip_a == SYNC_ID)
check("plain clip links to plain master identity",
    link.clip_b == PLAIN_ID)

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_payload_builder_master_identity.lua had failures")
print("✅ test_payload_builder_master_identity.lua passed")
