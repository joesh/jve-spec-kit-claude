#!/usr/bin/env luajit
--- Relink must rebase media_refs to the file's actual TC origin
---
--- Domain contract (CLAUDE.md "TIMECODE IS THE SOURCE OF TRUTH"):
---   media_refs sit at timeline_start = file_tc_origin, spanning
---   [tc_origin, tc_origin + file_duration). When relink probes a
---   replacement file and discovers its tmcd-derived TC origin differs
---   from what the project recorded (e.g. DRP claimed an old file's
---   TC; Resolve Media-Manage trimmed the head so the new file's
---   tmcd shifted forward), the media_ref MUST be moved to match the
---   new file's TC. Otherwise the resolver computes coverage in the
---   stale TC space and reports phantom gaps for clips whose source_in
---   is in the new file's range but past the stale media_ref window.
---
--- Live symptom (TSO 2026-05-15 12:20:21):
---   A035_11192237_C016.mov — file actually 426 frames @ TC origin
---   2036608. media row's metadata.start_tc_value got updated to
---   2036608 (relink wrote it). But media_ref kept its DRP-stated
---   timeline_start = 2036268 and source_out = 2037265 (= 2036268 +
---   997, the DRP's claimed extent). A clip at source_in=2036633
---   .. source_out=2036733 (100 frames, well inside the file's actual
---   range [2036608, 2037034)) resolved to: 61 frames in coverage
---   (2036633..2036694) + 39 phantom-gap frames (2036694..2036733).
---   User-visible: video plays for 18 frames then goes black mid-clip.
---
--- This test models that exact shape: a media whose probed TC differs
--- from the imported TC, relinked, with a clip referencing a range
--- that's inside the NEW TC window but past the OLD one. Pre-fix:
--- media_ref keeps old TC, resolver reports phantom gap. Post-fix:
--- media_ref rebases to new TC, clip resolves to full coverage.

require("test_env")

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_rebases_media_ref_tc.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")
local json = require("dkjson")

local Clip = require("models.clip")
local Media = require("models.media")
local Sequence = require("models.sequence")

-- Direct media_refs lookup by (media_id, track_type) — no model helper
-- exists for this and we don't want to add one just for a test.
local function media_refs_by_type(media_id, track_type)
    local stmt = database.get_connection():prepare([[
        SELECT mr.id, mr.timeline_start_frame, mr.source_in_frame,
               mr.source_out_frame, mr.duration_frames
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        WHERE mr.media_id = ? AND t.track_type = ?
        ORDER BY mr.id
    ]])
    assert(stmt, "media_refs_by_type: prepare failed")
    stmt:bind_value(1, media_id)
    stmt:bind_value(2, track_type)
    assert(stmt:exec(), "media_refs_by_type: exec failed")
    local out = {}
    while stmt:next() do
        out[#out + 1] = {
            id = stmt:value(0),
            timeline_start_frame = stmt:value(1),
            source_in_frame = stmt:value(2),
            source_out_frame = stmt:value(3),
            duration_frames = stmt:value(4),
        }
    end
    stmt:finalize()
    return out
end

local TEST_DB = "/tmp/jve/test_relink_rebases_media_ref_tc.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

-- ---------------------------------------------------------------------
-- Numbers chosen to mirror the live TSO incident with A035.
-- ---------------------------------------------------------------------
local OLD_TC  = 2036268   -- DRP-stated origin (stale)
local NEW_TC  = 2036608   -- Probed origin (file's tmcd atom, authoritative)
local OLD_DUR = 997       -- DRP-claimed extent (pre-Media-Manage)
local NEW_DUR = 426       -- Probed extent
local SR      = 48000     -- audio sample rate
local FPS     = 25        -- video rate
local SAMPLES_PER_FRAME = SR / FPS  -- 1920

local OLD_TC_AUDIO = OLD_TC * SAMPLES_PER_FRAME
local NEW_TC_AUDIO = NEW_TC * SAMPLES_PER_FRAME
local OLD_DUR_AUDIO = OLD_DUR * SAMPLES_PER_FRAME
local NEW_DUR_AUDIO = NEW_DUR * SAMPLES_PER_FRAME

local CLIP_SRC_IN  = 2036633   -- inside [NEW_TC, NEW_TC + NEW_DUR) and [OLD_TC, OLD_TC + OLD_DUR)
local CLIP_SRC_OUT = 2036733   -- 100-frame clip
local CLIP_LEN     = CLIP_SRC_OUT - CLIP_SRC_IN

-- The clip's range lies fully within the file's ACTUAL TC window:
assert(CLIP_SRC_IN  >= NEW_TC and CLIP_SRC_OUT <= NEW_TC + NEW_DUR,
    "fixture invariant: clip range must fit inside the probed file extent")
-- But it extends PAST the stale media_ref window:
assert(CLIP_SRC_OUT > OLD_TC + NEW_DUR,
    "fixture invariant: clip must overshoot the (origin=OLD, dur=NEW) window — "
    .. "that is the phantom-gap shape")

local now = os.time()
local project_id = "proj-relink-rebase"
local user_seq_id = uuid.generate()
local user_v_track = uuid.generate()
local user_a_track = uuid.generate()
local media_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'P', 'resample', %d, %d, '{}');
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Main', 'sequence', 25, 1, 48000, 1920, 1080, 0, 500, 0,
        '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked,
        muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked,
        muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], project_id, now, now,
    user_seq_id, project_id, now, now,
    user_v_track, user_seq_id,
    user_a_track, user_seq_id))

-- Media: pre-relink (DRP-stated origin + DRP-claimed extent).
local media = Media.create({
    id = media_id, project_id = project_id,
    file_path = "/offline/A035_11192237_C016.mov",
    name = "A035_11192237_C016.mov",
    duration_frames = OLD_DUR,
    fps_numerator = FPS, fps_denominator = 1,
    width = 2048, height = 1152,
    audio_channels = 2, audio_sample_rate = SR,
    metadata = json.encode({
        start_tc_value = OLD_TC, start_tc_rate = FPS,
        start_tc_audio_samples = OLD_TC_AUDIO, start_tc_audio_rate = SR,
    }),
})
media:save(db)

-- ensure_master creates the master sequence with V + A media_refs sitting
-- at the stated TC origin. This mirrors what DRP import produces.
local master_seq = Sequence.ensure_master(media_id, project_id)

-- Clip on the user's V1 track references this master at a TC range
-- inside the file's ACTUAL window but past the stale media_ref window.
local clip_id = uuid.generate()
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'Shot', '%s', '%s', '%s',
        0, %d, %d, %d, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
]], clip_id, project_id, user_v_track, master_seq, user_seq_id,
    CLIP_LEN, CLIP_SRC_IN, CLIP_SRC_OUT, now, now))

command_manager.init(user_seq_id, project_id)

-- ---------------------------------------------------------------------
-- Pre-relink: confirm the stale-TC fixture is set up correctly.
-- ---------------------------------------------------------------------
print("\n--- Pre-relink: media_refs at stale (DRP) TC ---")
local v_refs = media_refs_by_type(media_id, "VIDEO")
local a_refs = media_refs_by_type(media_id, "AUDIO")
assert(#v_refs == 1, string.format("expected 1 video media_ref, got %d", #v_refs))
assert(#a_refs >= 1, string.format("expected ≥1 audio media_ref, got %d", #a_refs))
local v_ref = v_refs[1]
assert(v_ref.timeline_start_frame == OLD_TC,
    string.format("pre: v_ref.timeline_start=%d expected %d", v_ref.timeline_start_frame, OLD_TC))
assert(v_ref.source_in_frame == OLD_TC,
    string.format("pre: v_ref.source_in=%d expected %d", v_ref.source_in_frame, OLD_TC))
assert(v_ref.source_out_frame == OLD_TC + OLD_DUR,
    string.format("pre: v_ref.source_out=%d expected %d", v_ref.source_out_frame, OLD_TC + OLD_DUR))
assert(v_ref.duration_frames == OLD_DUR,
    string.format("pre: v_ref.duration=%d expected %d", v_ref.duration_frames, OLD_DUR))
print(string.format("  ✓ v_ref: ts=%d src=[%d,%d) dur=%d  (stale DRP TC)",
    v_ref.timeline_start_frame, v_ref.source_in_frame, v_ref.source_out_frame,
    v_ref.duration_frames))

-- ---------------------------------------------------------------------
-- Run RelinkClips: probed TC + probed duration both differ from stored.
-- This is what media_relinker hands to the executor when the candidate
-- file's tmcd atom + container duration disagree with the DRP-stated
-- values (Resolve Media-Manage trim case).
-- ---------------------------------------------------------------------
print("\n--- Run RelinkClips with new TC + new duration ---")
local cmd = Command.create("RelinkClips", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("clip_relink_map", { [clip_id] = {} })  -- no source change
cmd:set_parameter("media_path_changes", {
    [media_id] = "/actual/A035_11192237_C016.mov",
})
cmd:set_parameter("media_tc_updates", {
    [media_id] = {
        start_tc_value = NEW_TC, start_tc_rate = FPS,
        start_tc_audio_samples = NEW_TC_AUDIO, start_tc_audio_rate = SR,
    },
})
cmd:set_parameter("media_duration_updates", {
    [media_id] = {
        duration_frames = NEW_DUR,
        audio_duration_samples = NEW_DUR_AUDIO,
    },
})

local result = command_manager.execute(cmd)
assert(result.success, "RelinkClips should succeed")

-- ---------------------------------------------------------------------
-- Post-relink: media_refs MUST sit at the new (probed) TC.
-- ---------------------------------------------------------------------
print("\n--- Post-relink: media_refs at new (probed) TC ---")
v_refs = media_refs_by_type(media_id, "VIDEO")
a_refs = media_refs_by_type(media_id, "AUDIO")
local v_ref_post = v_refs[1]
assert(v_ref_post.timeline_start_frame == NEW_TC, string.format(
    "post: v_ref.timeline_start must rebase to the file's actual TC origin. "
    .. "Got %d, expected %d. media_refs that don't follow the file's TC "
    .. "produce phantom gaps when clips reference the actual file range — "
    .. "TSO 2026-05-15: clip's last 39 of 100 frames went black despite "
    .. "the file holding them.",
    v_ref_post.timeline_start_frame, NEW_TC))
assert(v_ref_post.source_in_frame == NEW_TC, string.format(
    "post: v_ref.source_in must equal the new TC origin (got %d, want %d)",
    v_ref_post.source_in_frame, NEW_TC))
assert(v_ref_post.source_out_frame == NEW_TC + NEW_DUR, string.format(
    "post: v_ref.source_out must equal new_origin + new_duration "
    .. "(got %d, want %d). Stale source_out poisons clip-range containment "
    .. "checks even when the file is fully present.",
    v_ref_post.source_out_frame, NEW_TC + NEW_DUR))
assert(v_ref_post.duration_frames == NEW_DUR,
    string.format("post: v_ref.duration=%d expected %d",
        v_ref_post.duration_frames, NEW_DUR))
print(string.format("  ✓ v_ref: ts=%d src=[%d,%d) dur=%d  (probed TC)",
    v_ref_post.timeline_start_frame, v_ref_post.source_in_frame,
    v_ref_post.source_out_frame, v_ref_post.duration_frames))

-- Audio media_refs: independent timebase (samples), independent delta.
for _, a_ref in ipairs(a_refs) do
    assert(a_ref.timeline_start_frame == NEW_TC_AUDIO, string.format(
        "post: a_ref.timeline_start must rebase in audio-sample space "
        .. "(got %d, want %d)",
        a_ref.timeline_start_frame, NEW_TC_AUDIO))
    assert(a_ref.source_in_frame == NEW_TC_AUDIO, string.format(
        "post: a_ref.source_in must equal new audio TC origin (got %d, want %d)",
        a_ref.source_in_frame, NEW_TC_AUDIO))
    assert(a_ref.source_out_frame == NEW_TC_AUDIO + NEW_DUR_AUDIO, string.format(
        "post: a_ref.source_out must equal new_audio_origin + new_audio_dur "
        .. "(got %d, want %d)",
        a_ref.source_out_frame, NEW_TC_AUDIO + NEW_DUR_AUDIO))
end
print(string.format("  ✓ a_ref (n=%d): ts=%d src_out=%d  (probed audio TC)",
    #a_refs, a_refs[1].timeline_start_frame, a_refs[1].source_out_frame))

-- Clip is unchanged: its source_in/out are absolute TC moments; the
-- relink rewires the media_ref under them, not the clip.
local clip_post = Clip.load(clip_id)
assert(clip_post.source_in == CLIP_SRC_IN and clip_post.source_out == CLIP_SRC_OUT,
    "clip source range must not shift on a media-only relink")
print("  ✓ clip source range unchanged (rebase moves media_refs, not clips)")

-- The user-visible win: clip range is now fully covered.
assert(CLIP_SRC_IN  >= v_ref_post.source_in_frame
    and CLIP_SRC_OUT <= v_ref_post.source_out_frame,
    "post-relink invariant: clip range must be fully contained by the "
    .. "rebased media_ref (no phantom gaps)")
print("  ✓ clip range fully within rebased media_ref — no phantom gaps")

-- ---------------------------------------------------------------------
-- Undo: media_refs return to their pre-relink (stale-DRP) TC.
-- ---------------------------------------------------------------------
print("\n--- Undo: media_refs restored to stale TC ---")
command_manager.undo()

v_refs = media_refs_by_type(media_id, "VIDEO")
local v_ref_undo = v_refs[1]
assert(v_ref_undo.timeline_start_frame == OLD_TC, string.format(
    "undo: v_ref.timeline_start must restore to %d, got %d",
    OLD_TC, v_ref_undo.timeline_start_frame))
assert(v_ref_undo.source_in_frame == OLD_TC,
    "undo: v_ref.source_in must restore")
assert(v_ref_undo.source_out_frame == OLD_TC + OLD_DUR,
    "undo: v_ref.source_out must restore")
assert(v_ref_undo.duration_frames == OLD_DUR,
    "undo: v_ref.duration must restore")
print("  ✓ media_ref TC + extent restored after undo")

print("\n✅ test_relink_rebases_media_ref_tc.lua passed")
