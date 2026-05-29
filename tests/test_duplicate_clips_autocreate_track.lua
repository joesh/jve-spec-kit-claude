#!/usr/bin/env luajit

-- Regression: duplicating a linked V+A pair to a track offset where the
-- parallel AUDIO track does not yet exist must CREATE that track (NLE
-- convention — Premiere/Resolve auto-create the destination), place the
-- audio duplicate on it, and keep the pair linked. Undo removes the
-- duplicates AND the created track(s).
--
-- Track stacks stay CONTIGUOUS: anchor moves +2 video tracks, so the audio
-- target is A3 — but only A1 exists. Both A2 (empty) and A3 must be created
-- (you can't have A3 with no A2); the audio duplicate lands on A3.
--
-- Anti-bug: the alternative — silently leaving the audio on its source
-- track, or dropping it — is a Rule 2.13 fallback. The clip must land where
-- the shared track-mapping says it must.
--
-- Black-box: drives DuplicateClips, inspects tracks + clips + clip_links.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local clip_link = require("models.clip_link")

_G.qt_create_single_shot_timer = function(_, cb) cb(); return nil end

print("=== test_duplicate_clips_autocreate_track.lua ===")

local db_path = "/tmp/jve/test_duplicate_clips_autocreate.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local now = os.time()

-- Tracks: V1, V2, V3, A1 — note NO A2/A3 exist yet.
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":30,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'proj', 'Seq', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v3', 'sequence', 'V3', 'VIDEO', 3, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('med', 'proj', 'cam.mov', '/tmp/cam.mov', 1000, 30, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_med', 'proj', 'med_master', 'master', 30, 1, NULL, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('master_v', 'master_med', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'master_v' WHERE id = 'master_med';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'proj', 'master_med', 'master_v', 'med', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now))

local function insert_clip(id, track_id, start_f, dur, source_in, is_audio)
    local sub = is_audio and "0, 0" or "NULL, NULL"
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, sequence_id,
            name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe, enabled, fps_mismatch_policy, volume,
            playhead_frame, created_at, modified_at)
        VALUES ('%s', 'proj', '%s', 'sequence', 'master_med', '%s', %d, %d, %d, %d,
            %s, 1, 'resample', 1.0, 0, %d, %d);
    ]], id, track_id, id, start_f, dur, source_in, source_in + dur, sub, now, now))
end

insert_clip("clip_v", "track_v1", 300, 100, 120, false)
insert_clip("clip_a", "track_a1", 300, 100, 120, true)
assert(clip_link.create_link_group({
    { clip_id = "clip_v", role = "video", time_offset = 0 },
    { clip_id = "clip_a", role = "audio", time_offset = 0 },
}, db), "fixture: pair must be linked")

command_manager.init("sequence", "proj")

local function run(name, params)
    command_manager.begin_command_event("script")
    local r1, r2 = command_manager.execute(name, params)
    command_manager.end_command_event()
    return r1 or r2
end
local function undo()
    command_manager.begin_command_event("script")
    local r = command_manager.undo()
    command_manager.end_command_event()
    return r
end

local function audio_track_count()
    local stmt = db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id='sequence' AND track_type='AUDIO'")
    stmt:exec(); stmt:next()
    local n = stmt:value(0); stmt:finalize()
    return n
end
local function audio_dup_track()
    -- track of the duplicate audio clip (the one not on A1)
    local stmt = db:prepare([[
        SELECT t.track_index FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.track_type='AUDIO' AND c.id NOT IN ('clip_v','clip_a')
    ]])
    stmt:exec()
    local idx = stmt:next() and stmt:value(0) or nil
    stmt:finalize()
    return idx
end

assert(audio_track_count() == 1, "precondition: only A1 exists")

-- Duplicate the pair onto V3 (anchor video +2 tracks). Audio must follow +2
-- => A3; neither A2 nor A3 exists, so BOTH are created (contiguous stack).
local res = run("DuplicateClips", {
    project_id = "proj",
    sequence_id = "sequence",
    clip_ids = { "clip_v", "clip_a" },
    anchor_clip_id = "clip_v",
    target_track_id = "track_v3",
    delta_frames = 100,
})
assert(res.success, "DuplicateClips should succeed: " .. tostring(res.error_message))

assert(audio_track_count() == 3, string.format(
    "A2 + A3 must be auto-created (contiguous), have %d audio tracks", audio_track_count()))
assert(audio_dup_track() == 3, string.format(
    "audio duplicate must land on the new A3 (index 3), got %s", tostring(audio_dup_track())))
print("  ✓ missing A2+A3 auto-created (contiguous); audio duplicate on A3")

-- Undo must remove the duplicates AND both auto-created tracks.
assert(undo().success, "undo should succeed")
assert(audio_track_count() == 1, string.format(
    "undo must remove both auto-created audio tracks, have %d", audio_track_count()))
print("  ✓ undo removes both auto-created tracks")

print("\n✅ test_duplicate_clips_autocreate_track.lua passed")
