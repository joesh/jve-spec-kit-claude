#!/usr/bin/env luajit
--- DuplicateMasterClip honors the TC + placement-unit conventions
--- that Sequence.ensure_master establishes.
---
--- Domain contract (CLAUDE.md feedback_timecode_is_truth + post-unification):
---   For a V+A master created from media at non-zero TC:
---     - V MR.sequence_start_frame = V MR.source_in_frame = video TC
---       (master.fps frames). The MR sits at the file's TC origin and
---       spans [tc, tc + dur).
---     - A MR.sequence_start_frame = video TC (master.fps frames =
---       video frames for V+A), .duration_frames = video-frame extent.
---     - A MR.source_in_frame = audio TC (file-natural samples),
---       .source_out_frame = audio_tc + duration_samples.
---   DuplicateMasterClip is a "make a second master row pointing at the
---   same media" command; it MUST produce MRs in the same shape as
---   ensure_master or the duplicated master plays from frame 0 (wrong),
---   shows audio clips 1920× too long (wrong), and resolver math diverges
---   between the original and the copy.
---
--- Pre-fix DuplicateMasterClip wrote ts=0/source_in=0 for V and
--- duration_frames=duration_samples for A — a leftover from when audio
--- MR placement was stored in samples.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_duplicate_master_clip_tc_units.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")
local json = require("dkjson")

local Sequence = require("models.sequence")

local function media_refs(seq_id)
    local stmt = database.get_connection():prepare([[
        SELECT mr.id, t.track_type,
               mr.sequence_start_frame, mr.duration_frames,
               mr.source_in_frame, mr.source_out_frame
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        WHERE mr.owner_sequence_id = ?
        ORDER BY t.track_type, mr.id
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local out = {}
    while stmt:next() do
        out[#out + 1] = {
            id = stmt:value(0), track_type = stmt:value(1),
            ts = stmt:value(2), dur = stmt:value(3),
            sin = stmt:value(4), sout = stmt:value(5),
        }
    end
    stmt:finalize()
    return out
end

local TEST_DB = "/tmp/jve/test_duplicate_master_clip_tc_units.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local FPS, SR = 25, 48000
local VIDEO_TC = 2236              -- 01:29:24:11 @ 25fps
local DUR_FRAMES = 7124            -- ~285s @ 25fps
local AUDIO_TC = VIDEO_TC * SR / FPS         -- 4293120 samples
local DUR_SAMPLES = DUR_FRAMES * SR / FPS    -- 13678080 samples

local proj = "p1"
local media_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'P', 'resample', %d, %d, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, metadata, created_at, modified_at)
    VALUES ('%s', '%s', 'A038.mov', '/tmp/A038.mov', %d, %d, 1, %d, 2,
            1920, 1080,
            '{"start_tc_value":%d,"start_tc_rate":%d,"start_tc_audio_samples":%d,"start_tc_audio_rate":%d}',
            %d, %d);
]], proj, now, now,
    media_id, proj, DUR_FRAMES, FPS, SR, VIDEO_TC, FPS, AUDIO_TC, SR, now, now))

-- Bootstrap a record sequence so command_manager.init has an edit target.
local rec_seq_id = uuid.generate()
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Rec', 'sequence', %d, 1, %d, 1920, 1080,
            0, 500, 0, '[]', '[]', '[]', 0, %d, %d);
]], rec_seq_id, proj, FPS, SR, now, now))

-- Build the ORIGINAL master via ensure_master — establishes the
-- canonical shape we want the duplicate to mirror.
local orig_master_id = Sequence.ensure_master(media_id, proj)
local orig_mrs = media_refs(orig_master_id)
local orig_v, orig_a
for _, r in ipairs(orig_mrs) do
    if r.track_type == "VIDEO" then orig_v = r
    elseif r.track_type == "AUDIO" then orig_a = r end
end
assert(orig_v and orig_a, "ensure_master fixture: must have V + A MRs")
assert(orig_v.ts == VIDEO_TC and orig_v.sin == VIDEO_TC,
    "ensure_master fixture: V MR must sit at video_tc")
assert(orig_a.ts == VIDEO_TC and orig_a.dur == DUR_FRAMES,
    "ensure_master fixture: A MR placement in master.fps frames")
assert(orig_a.sin == AUDIO_TC,
    "ensure_master fixture: A MR source_in in samples")

command_manager.init(rec_seq_id, proj)

-- Run DuplicateMasterClip.
print("\n--- Run DuplicateMasterClip ---")
local new_master_id = uuid.generate()
local cmd = Command.create("DuplicateMasterClip", proj)
cmd:set_parameter("project_id", proj)
cmd:set_parameter("new_master_id", new_master_id)
cmd:set_parameter("name", "A038 (copy)")
cmd:set_parameter("clip_snapshot", {
    media_id = media_id,
    fps_numerator = FPS,
    fps_denominator = 1,
    sequence_start = 0,
    duration = DUR_FRAMES,
    source_in = 0,
    source_out = DUR_FRAMES,
})
local result = command_manager.execute(cmd)
assert(result and result.success,
    "DuplicateMasterClip must succeed: " .. tostring(result and result.error_message))

-- ── Assertion: duplicate's MRs match the original's shape ──
local dup_mrs = media_refs(new_master_id)
local dup_v, dup_a
for _, r in ipairs(dup_mrs) do
    if r.track_type == "VIDEO" then dup_v = r
    elseif r.track_type == "AUDIO" then dup_a = r end
end
assert(dup_v, "duplicate master missing V MR")
assert(dup_a, "duplicate master missing A MR")

-- V MR: same shape as ensure_master
assert(dup_v.ts == VIDEO_TC, string.format(
    "duplicate V MR.sequence_start: expected %d (video_tc), got %d. "
    .. "Writing 0 here puts the duplicate at frame 0 instead of TC, "
    .. "diverging from the original master.",
    VIDEO_TC, dup_v.ts))
assert(dup_v.sin == VIDEO_TC, string.format(
    "duplicate V MR.source_in: expected %d, got %d (must equal "
    .. "video_tc — file_pos = source_in - first_frame_tc at decode)",
    VIDEO_TC, dup_v.sin))
assert(dup_v.sout == VIDEO_TC + DUR_FRAMES, string.format(
    "duplicate V MR.source_out: expected %d, got %d",
    VIDEO_TC + DUR_FRAMES, dup_v.sout))
assert(dup_v.dur == DUR_FRAMES,
    "duplicate V MR.duration_frames must equal source duration")
print(string.format("  ✓ V MR: ts=%d dur=%d src=[%d,%d)",
    dup_v.ts, dup_v.dur, dup_v.sin, dup_v.sout))

-- A MR: placement in master.fps frames (= V frames for V+A),
-- source range in file-natural samples.
assert(dup_a.ts == VIDEO_TC, string.format(
    "duplicate A MR.sequence_start: expected %d (master.fps frames, "
    .. "same as V), got %d. Pre-unification overload wrote samples here "
    .. "and the audio virtual clip became invisible / 1920× misplaced.",
    VIDEO_TC, dup_a.ts))
assert(dup_a.dur == DUR_FRAMES, string.format(
    "duplicate A MR.duration_frames: expected %d (master.fps frames), "
    .. "got %d. Writing duration_samples here (= %d) is the pre-"
    .. "unification leftover that made src-tab audio lanes appear empty.",
    DUR_FRAMES, dup_a.dur, DUR_SAMPLES))
assert(dup_a.sin == AUDIO_TC, string.format(
    "duplicate A MR.source_in (file-natural samples): expected %d, got %d",
    AUDIO_TC, dup_a.sin))
assert(dup_a.sout == AUDIO_TC + DUR_SAMPLES, string.format(
    "duplicate A MR.source_out (samples): expected %d, got %d",
    AUDIO_TC + DUR_SAMPLES, dup_a.sout))
print(string.format("  ✓ A MR: ts=%d dur=%d src=[%d,%d)",
    dup_a.ts, dup_a.dur, dup_a.sin, dup_a.sout))

-- Cross-check: duplicate's MRs match the original's exactly (modulo IDs)
assert(dup_v.ts == orig_v.ts and dup_v.dur == orig_v.dur
    and dup_v.sin == orig_v.sin and dup_v.sout == orig_v.sout,
    "duplicate V MR must be identical to original V MR")
assert(dup_a.ts == orig_a.ts and dup_a.dur == orig_a.dur
    and dup_a.sin == orig_a.sin and dup_a.sout == orig_a.sout,
    "duplicate A MR must be identical to original A MR")
print("  ✓ duplicate MRs match original exactly")

print("\n✅ test_duplicate_master_clip_tc_units.lua passed")
_ = json  -- luacheck: ignore (used by other test runs in this file)
