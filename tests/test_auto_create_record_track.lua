#!/usr/bin/env luajit

-- T015 (015) — FR-029b: auto-create record tracks on edit; undo is a single Cmd-Z.
--
-- Domain: when Insert/Overwrite has enabled patches referencing record track indices
-- that don't yet exist, those tracks are created automatically inside the SAME undo
-- group so one Cmd-Z reverts the edit AND removes the auto-created tracks.
--
-- Setup:
--   Record sequence: V1 + A1–A3 (4 tracks).
--   Source master seq: V1 + A1–A8.
--   Patches on rec_seq: A1→1 (exists), A4→4, A5→5, A8→8 (missing).
--
-- Expected FAIL today: patches table does not exist (schema migration T025 not applied).
-- Will also FAIL after schema if T042 (auto-create implementation) not done.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_auto_create_record_track.lua ===")

local DB = "/tmp/jve/test_auto_create_record_track.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))

-- Record sequence (target of the edit)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('rec_seq', 'proj', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

-- Source master sequence (loaded in source monitor)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src_seq', 'proj', 'Src', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

-- Record sequence tracks: V1 + A1-A3
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_v1', 'rec_seq', 'V1', 'VIDEO', 1, 1)]])
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_a1', 'rec_seq', 'A1', 'AUDIO', 1, 1)]])
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_a2', 'rec_seq', 'A2', 'AUDIO', 2, 1)]])
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_a3', 'rec_seq', 'A3', 'AUDIO', 3, 1)]])

-- Source master tracks: V1 + A1-A8
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('src_v1', 'src_seq', 'V1', 'VIDEO', 1, 1)]])
for i = 1, 8 do
    db:exec(string.format(
        [[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('src_a%d', 'src_seq', 'A%d', 'AUDIO', %d, 1)]], i, i, i))
end

-- Patches: A1→1 (rec track exists), A4→4, A5→5, A8→8 (rec tracks missing).
assert(db:exec([[
    INSERT INTO patches
        (id, sequence_id, track_type, source_shape,
         source_track_index, record_track_index, enabled, created_at)
    VALUES ('p_a1', 'rec_seq', 'AUDIO', 1, 1, 1, 1, 0)
]]), "FAIL: patches table missing — schema migration T025 not applied")

assert(db:exec([[
    INSERT INTO patches
        (id, sequence_id, track_type, source_shape,
         source_track_index, record_track_index, enabled, created_at)
    VALUES ('p_a4', 'rec_seq', 'AUDIO', 8, 4, 4, 1, 0)
]]), "patches INSERT A4 failed")

assert(db:exec([[
    INSERT INTO patches
        (id, sequence_id, track_type, source_shape,
         source_track_index, record_track_index, enabled, created_at)
    VALUES ('p_a5', 'rec_seq', 'AUDIO', 8, 5, 5, 1, 0)
]]), "patches INSERT A5 failed")

assert(db:exec([[
    INSERT INTO patches
        (id, sequence_id, track_type, source_shape,
         source_track_index, record_track_index, enabled, created_at)
    VALUES ('p_a8', 'rec_seq', 'AUDIO', 8, 8, 8, 1, 0)
]]), "patches INSERT A8 failed")

print("  patches inserted — schema OK")

-- Source media + clips on src_seq A4/A5/A8. Insert reads source_sequence_id's
-- clips and routes them via patches onto rec_seq's matching record_track_index.
-- Patches A4/A5/A8 → record indices 4/5/8 that don't exist yet on rec_seq, so
-- Insert auto-creates those tracks AND places these routed clips on them. Undo
-- must remove clips first (AddClipsToSequence undoer) and then the now-empty
-- auto-tracks (Insert undoer + strict Track.delete) — the proper user-walkable
-- replacement for the deleted AddClipToTrack backdoor test.
db:exec(string.format([[
    INSERT INTO media
        (id, project_id, name, file_path, duration_frames,
         fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
         metadata, created_at, modified_at)
    VALUES ('src_media', 'proj', 'src_audio', '/tmp/src_audio.wav', 1000, 24, 1,
            1, 48000,
            '{"start_tc_audio_samples":0,"start_tc_audio_rate":48000}',
            %d, %d)
]], now, now))

local Sequence = require('models.sequence')
local Clip     = require('models.clip')
local master_seq_id = Sequence.ensure_master('src_media', 'proj')
local sub_in, sub_out = Clip.subframe_defaults_for(db, 'src_a4')
for _, src_track in ipairs({"src_a4", "src_a5", "src_a8"}) do
    Clip.create({
        id                    = "src_clip_" .. src_track,
        project_id            = 'proj',
        owner_sequence_id     = 'src_seq',
        track_id              = src_track,
        sequence_id           = master_seq_id,
        name                  = "src clip " .. src_track,
        sequence_start_frame  = 0,
        duration_frames       = 100,
        source_in_frame       = 0,
        source_out_frame      = 100,
        source_in_subframe    = sub_in,
        source_out_subframe   = sub_out,
        fps_mismatch_policy   = "resample",
        enabled               = true,
        volume                = 1.0,
        playhead_frame        = 0,
        created_at            = now,
        modified_at           = now,
    })
end

command_manager.init("rec_seq", "proj")

local function count_audio_tracks()
    local s = db:prepare(
        "SELECT COUNT(*) FROM tracks WHERE sequence_id='rec_seq' AND track_type='AUDIO'")
    assert(s); s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

local function count_rec_clips_on_auto_tracks()
    -- Clips on rec_seq tracks of index >= 4 (the auto-created ones).
    local s = db:prepare([[
        SELECT COUNT(*) FROM clips c
        JOIN tracks t ON t.id = c.track_id
        WHERE t.sequence_id = 'rec_seq' AND t.track_type = 'AUDIO' AND t.track_index >= 4
    ]])
    assert(s); s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

local before = count_audio_tracks()
assert(before == 3, string.format("Setup: expected 3 audio tracks, got %d", before))
print(string.format("  initial audio tracks: %d — OK", before))

-- Insert the source master sequence into the record sequence.
-- T042 will extend Insert to check patches and auto-create missing record tracks.
local r = command_manager.execute("Insert", {
    sequence_id        = "rec_seq",
    project_id         = "proj",
    source_sequence_id = "src_seq",
    sequence_start_frame = 0,
})
assert(r and r.success,
    "Insert failed: " .. tostring(r and r.error_message))

-- After Insert: rec_seq must now have audio tracks 1–8 (A4/A5/A8 auto-created).
local after = count_audio_tracks()
assert(after == 8, string.format(
    "FAIL: expected 8 audio tracks after Insert (got %d) — T042 (auto-create) not implemented",
    after))
print(string.format("  audio tracks after Insert: %d — OK", after))

-- Routed clips: src_seq's clips on src_a4/a5/a8 must have been placed on
-- rec_seq's matching auto-created tracks via patches.
-- Insert places 1 clip per audio destination track for each contained source
-- medium (channel-routed via patches). With 5 auto-tracks (A4..A8), expect 5
-- routed clips landing on them — this is what exercises the
-- clip-then-track undo ordering Track.delete now enforces.
local routed = count_rec_clips_on_auto_tracks()
assert(routed == 5, string.format(
    "FAIL: expected 5 routed clips on auto-created tracks (one per A4..A8), got %d", routed))
print(string.format("  routed clips on auto-tracks: %d — OK", routed))

-- Auto-created tracks must default to sync_mode='ripple', muted=0, soloed=0, locked=0.
local s = db:prepare([[
    SELECT name, sync_mode, muted, soloed, locked
    FROM tracks
    WHERE sequence_id='rec_seq' AND track_type='AUDIO' AND track_index > 3
    ORDER BY track_index
]])
assert(s); s:exec()
local created = {}
while s:next() do
    created[#created+1] = {
        name      = s:value(0),
        sync_mode = s:value(1),
        muted     = s:value(2),
        soloed    = s:value(3),
        locked    = s:value(4),
    }
end
s:finalize()
assert(#created == 5, string.format("expected 5 auto-created audio tracks, got %d", #created))

for _, t in ipairs(created) do
    assert(t.sync_mode == 'ripple', string.format(
        "FAIL: auto-created %s sync_mode='%s', expected 'ripple'", t.name, t.sync_mode))
    assert(t.muted  == 0, "FAIL: auto-created track muted != 0")
    assert(t.soloed == 0, "FAIL: auto-created track soloed != 0")
    assert(t.locked == 0, "FAIL: auto-created track locked != 0")
end
print("  auto-created tracks: sync_mode=ripple, muted/soloed/locked=0 — OK")

-- FR-021d (no audio-track-type enforcement: mono/stereo/5.1 all accepted) was
-- previously verified here via AddClipToTrack — deleted 2026-05-28 because the
-- primitive had no UI path. See todo_fr021d_channel_acceptance_coverage.md.

-- ── Undo: one Cmd-Z reverts edit AND removes auto-created tracks ──────────────
command_manager.undo()
local after_undo_clips = count_rec_clips_on_auto_tracks()
assert(after_undo_clips == 0, string.format(
    "FAIL: after undo expected 0 routed clips, got %d — clips must undo before tracks",
    after_undo_clips))
local after_undo = count_audio_tracks()
assert(after_undo == 3, string.format(
    "FAIL: after undo expected 3 audio tracks, got %d — auto-created tracks must undo with edit",
    after_undo))
print(string.format("  after undo: %d clips, %d audio tracks — all auto-cleanup OK",
    after_undo_clips, after_undo))

print("\n✅ test_auto_create_record_track.lua passed")
