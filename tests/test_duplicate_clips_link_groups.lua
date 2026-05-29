#!/usr/bin/env luajit

-- Regression: duplicating a LINKED video+audio pair must duplicate BOTH
-- halves and keep the duplicates linked.
--
-- Domain behavior (NLE convention — Premiere/Resolve/FCP):
--   Alt-dragging a linked V+A pair to copy it produces two new clips: the
--   video duplicate on the destination video track, the audio duplicate
--   shifted by the SAME track delta in the audio stack (anchor video moves
--   +N video tracks -> audio moves +N audio tracks). The two duplicates are
--   linked to each other as a NEW pair, independent of the source pair, so
--   moving one duplicate moves the other.
--
-- Pre-fix bug: plan_duplicate_inserts gated duplication on
-- "source track type == anchor track type", so with anchor = the video
-- clip, the selected AUDIO clip mapped to no target and was silently
-- dropped. Result: only the video duplicate, no audio, no link group.
--
-- Black-box: drives the DuplicateClips command and inspects rows
-- (clips + clip_links). Expected track/frame/role values are derived from
-- the NLE domain above, not by tracing the implementation.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local clip_link = require("models.clip_link")

_G.qt_create_single_shot_timer = function(_, cb) cb(); return nil end

print("=== test_duplicate_clips_link_groups.lua ===")

local db_path = "/tmp/jve/test_duplicate_clips_link_groups.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

-- Overlap triggers off — destination tracks are empty here anyway.
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local now = os.time()

-- Project + edited sequence (30fps). Per-type track indexing (V1/V2 = 1/2,
-- A1/A2 = 1/2), matching the app's Track.create_* convention.
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
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_a2', 'sequence', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Master sequence (kind='master') the clips reference via sequence_id, plus
-- one media_ref so the planner's LEFT JOIN resolves a media_id.
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

-- Linked V+A pair, NON-TRIVIAL: starts at frame 300, source_in 120 (4s@30),
-- audio carries non-NULL subframes (V11 FR-005), video NULL.
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

local source_group = clip_link.create_link_group({
    { clip_id = "clip_v", role = "video", time_offset = 0 },
    { clip_id = "clip_a", role = "audio", time_offset = 0 },
}, db)
assert(source_group and source_group ~= "", "fixture: source pair must be linked")

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
local function redo()
    command_manager.begin_command_event("script")
    local r = command_manager.redo()
    command_manager.end_command_event()
    return r
end

-- Returns {id -> {track_id, start, link_group}} for every clip NOT in the
-- source pair (i.e. the duplicates).
local function duplicates()
    local out = {}
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.sequence_start_frame, l.link_group_id
        FROM clips c LEFT JOIN clip_links l ON l.clip_id = c.id
        WHERE c.id NOT IN ('clip_v', 'clip_a')
    ]])
    stmt:exec()
    while stmt:next() do
        out[stmt:value(0)] = {
            track_id = stmt:value(1),
            start = stmt:value(2),
            link_group = stmt:value(3),
        }
    end
    stmt:finalize()
    return out
end

local function count(sql)
    local stmt = db:prepare(sql)
    stmt:exec(); stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

-- ── Execute: duplicate the linked pair onto V2, +100 frames ──────────────
-- anchor = video clip on V1; target = V2 (delta +1 video track). The audio
-- clip must therefore land on A2 (+1 audio track), both at frame 400.
local res = run("DuplicateClips", {
    project_id = "proj",
    sequence_id = "sequence",
    clip_ids = { "clip_v", "clip_a" },
    anchor_clip_id = "clip_v",
    target_track_id = "track_v2",
    delta_frames = 100,
})
assert(res.success, "DuplicateClips should succeed: " .. tostring(res.error_message))

local dups = duplicates()
local n_dups = 0
for _ in pairs(dups) do n_dups = n_dups + 1 end
assert(n_dups == 2, string.format(
    "BOTH halves must duplicate; got %d duplicate clip(s) (audio dropped?)", n_dups))

-- Locate video vs audio duplicate by destination track.
local vdup, adup
for _, d in pairs(dups) do
    if d.track_id == "track_v2" then vdup = d
    elseif d.track_id == "track_a2" then adup = d end
end
assert(vdup, "video duplicate must land on V2")
assert(adup, "audio duplicate must land on A2 (shifted +1 audio track, same as anchor)")
assert(vdup.start == 400, string.format("video dup at frame 400, got %s", tostring(vdup.start)))
assert(adup.start == 400, string.format("audio dup at frame 400, got %s", tostring(adup.start)))

-- New link group: shared by both duplicates, distinct from the source pair.
assert(vdup.link_group, "video duplicate must be linked")
assert(adup.link_group, "audio duplicate must be linked")
assert(vdup.link_group == adup.link_group,
    "the two duplicates must share ONE link group")
assert(vdup.link_group ~= source_group,
    "duplicates' link group must be NEW, distinct from the source pair's")

-- Roles preserved.
local roles = {}
for _, m in ipairs(clip_link.get_link_group(next(dups), db)) do
    roles[m.role] = true
end
assert(roles.video and roles.audio, "new group must carry video+audio roles")
print("  ✓ both halves duplicated, linked as a new group, audio on A2 @400")

-- ── Undo: duplicates and their link group vanish ─────────────────────────
assert(undo().success, "undo should succeed")
assert(count("SELECT COUNT(*) FROM clips WHERE id NOT IN ('clip_v','clip_a')") == 0,
    "undo must remove both duplicate clips")
assert(count(string.format(
    "SELECT COUNT(*) FROM clip_links WHERE link_group_id = '%s'", vdup.link_group)) == 0,
    "undo must remove the duplicates' link group (no orphan clip_links)")
-- Source pair's link group untouched.
assert(count(string.format(
    "SELECT COUNT(*) FROM clip_links WHERE link_group_id = '%s'", source_group)) == 2,
    "source pair must stay linked after undo")
print("  ✓ undo removes both duplicates + their link group, source pair intact")

-- ── Redo: restores both, re-linked ───────────────────────────────────────
assert(redo().success, "redo should succeed")
local dups2 = duplicates()
local n2 = 0
local grp
for _, d in pairs(dups2) do n2 = n2 + 1; grp = grp or d.link_group end
assert(n2 == 2, "redo must restore both duplicates")
for _, d in pairs(dups2) do
    assert(d.link_group and d.link_group == grp, "redo must re-link both duplicates as one group")
end
print("  ✓ redo restores both duplicates, re-linked")

print("\n✅ test_duplicate_clips_link_groups.lua passed")
