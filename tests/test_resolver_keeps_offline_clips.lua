#!/usr/bin/env luajit
--- Regression: the resolver MUST surface offline clips to playback queries.
---
--- Domain rule: when a clip's media is offline, playback should produce
--- the audible "beep" placeholder and the visual "OFFLINE" frame — not
--- silence and a black screen. The C++ TimelineMediaBuffer beeps when it
--- sees a clip with offline=true, and the offline-frame cache is keyed on
--- media_path. Both depend on the resolver passing the offline clip
--- through to playback queries with media_path populated.
---
--- Pre-fix bug (Apr 26 2026 V13 regression): resolve_master_leaf set
---   media_path = online and r.file_path or nil
--- and filter_and_finalize then dropped any entry with empty/nil
--- media_path. Result: offline clips were silently filtered out of
--- get_audio_in_range / get_video_in_range, so _provide_clips never
--- handed them to TMB → no beep, no offline frame.
---
--- Black-box: builds a real V13 sequence (master + nested + clip)
--- pointing at a file path that doesn't exist on disk, then asserts
--- the resolver returns the entry with the file path intact and the
--- enabled flag preserved.
require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolver_keeps_offline_clips.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()

-- Use a path GUARANTEED not to exist so media_status.is_online() returns
-- false for it (the bug-revealing condition).
local OFFLINE_PATH = "/tmp/jve/__offline_does_not_exist_" .. os.time() .. ".wav"
os.remove(OFFLINE_PATH)
local f = io.open(OFFLINE_PATH, "r")
assert(f == nil,
    "test setup: OFFLINE_PATH must not exist on disk (got it back from io.open)")

assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p', 'p', 'passthrough', 0, 0)"))
-- Master (V13: holds media_refs)
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, "
    .. "fps_denominator, audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p', 'm', 'master', 25, 1, 48000, 1920, 1080, 0, 0)"))
-- Nested (edit timeline)
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, "
    .. "fps_denominator, audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p', 'e', 'sequence', 25, 1, 48000, 1920, 1080, 0, 0)"))
-- Audio track on master and one on nested
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
-- Audio media — file does NOT exist on disk
assert(db:exec(string.format(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_sample_rate, audio_channels, "
    .. "is_still, created_at, modified_at) "
    .. "VALUES ('med', 'p', 'tone', %q, 250, 25, 1, 48000, 2, 0, 0, 0)",
    OFFLINE_PATH)))
-- Master media_ref spans the whole file
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, "
    .. "media_id, source_in_frame, source_out_frame, sequence_start_frame, "
    .. "duration_frames, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p', 'm', 'm-a1', 'med', 0, 250, 0, 250, 1, 1.0, 0, 0, 0)"))
-- Edit clip references master, picking the full master window
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, "
    .. "sequence_id, name, sequence_start_frame, duration_frames, "
    .. "source_in_frame, source_out_frame, fps_mismatch_policy, enabled, "
    .. "volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p', 'e', 'e-a1', 'm', 'c', 0, 250, 0, 250, "
    .. "'passthrough', 1, 1.0, 0, 0, 0)"))

local Sequence = require("models.sequence")
local edit = Sequence.load("e")
assert(edit, "Sequence.load('e') returned nil")

-- Sanity: confirm media_status agrees the file is offline.
local media_status = require("core.media.media_status")
assert(media_status.is_online(OFFLINE_PATH) == false, string.format(
    "test setup: media_status must report %s as offline; got online", OFFLINE_PATH))

-- Domain assertion: the offline audio clip MUST surface from the resolver
-- so playback can route it to the beep placeholder. Pre-fix this returned
-- an empty list (bug); post-fix it returns one entry.
local entries = edit:get_audio_in_range(0, 250)
-- Stereo media yields one entry per channel (2 entries for stereo).
-- The bug pre-fix returns 0 entries; post-fix returns 2.
assert(#entries >= 1, string.format(
    "offline audio clip must NOT be filtered out of get_audio_in_range; "
    .. "got %d entries (expected ≥1)", #entries))

local e = entries[1]
assert(e.media_path == OFFLINE_PATH, string.format(
    "offline clip's media_path must be the original file path so the "
    .. "offline-frame cache and TMB clip-build can key on it; got %s "
    .. "(expected %s)", tostring(e.media_path), OFFLINE_PATH))
-- enabled comes through unchanged from the user-set value (1 in our DB row).
-- Pre-fix this was forced to false for offline clips, muting the beep.
assert(e.enabled == true or e.enabled == 1, string.format(
    "offline clip's enabled flag must be preserved (the user set it true); "
    .. "got %s — forcing it false silences the beep", tostring(e.enabled)))
assert(e.media_kind == "audio",
    "media_kind must still classify as audio")
assert(type(e.sequence_start) == "number" and type(e.duration) == "number",
    "sequence_start/duration must be numbers (resolver shape contract)")

-- Same for video: build a parallel video media_ref and check.
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
local OFFLINE_VIDEO = "/tmp/jve/__offline_video_" .. os.time() .. ".mov"
os.remove(OFFLINE_VIDEO)
assert(db:exec(string.format(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, width, height, is_still, created_at, modified_at) "
    .. "VALUES ('vmed', 'p', 'pic', %q, 250, 25, 1, 1920, 1080, 0, 0, 0)",
    OFFLINE_VIDEO)))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, "
    .. "media_id, source_in_frame, source_out_frame, sequence_start_frame, "
    .. "duration_frames, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('vmr', 'p', 'm', 'm-v1', 'vmed', 0, 250, 0, 250, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, "
    .. "sequence_id, name, sequence_start_frame, duration_frames, "
    .. "source_in_frame, source_out_frame, fps_mismatch_policy, enabled, "
    .. "volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('vc', 'p', 'e', 'e-v1', 'm', 'vc', 0, 250, 0, 250, "
    .. "'passthrough', 1, 1.0, 0, 0, 0)"))

local v_entries = edit:get_video_in_range(0, 250)
assert(#v_entries == 1, string.format(
    "offline video clip must NOT be filtered out of get_video_in_range; "
    .. "got %d entries", #v_entries))
assert(v_entries[1].media_path == OFFLINE_VIDEO, string.format(
    "offline video clip's media_path must be preserved; got %s",
    tostring(v_entries[1].media_path)))

print("✅ test_resolver_keeps_offline_clips.lua passed")
