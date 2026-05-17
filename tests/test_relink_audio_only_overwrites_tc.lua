#!/usr/bin/env luajit
--- Relink must overwrite audio-only files' TC metadata from the
--- chosen file, and the master audio media_ref's placement column
--- must agree with its sample-space source column.
---
--- Domain contract (CLAUDE.md "TIMECODE IS THE SOURCE OF TRUTH"
--- + feedback_timecode_is_truth post-unification convention):
---   For an audio-only master, master.fps == sample_rate. The audio
---   media_ref's timeline_start_frame (master.fps frames = samples)
---   and source_in_frame (file-natural samples) MUST encode the
---   same TC moment — both equal to the file's audio TC origin
---   in samples. Any divergence between the two means the resolver
---   walks at one TC while the decoder reads at another, producing
---   silent gaps / 4-second delays / "beep on F" offline tones.
---
--- Live symptom (TSO 2026-05-16, anamnesis-gold-timeline.jvp):
---   Long stereo-mix WAV ("Anemnesis Stereo Mix - Online 23012026_01"):
---     media_ref.timeline_start_frame = 172508160 (DRP-claimed TC)
---     media_ref.source_in_frame      = 172320000 (BWF time_reference)
---     Δ = 188160 samples = 3.92 s
---   Clips on the rec timeline play 4 s late and beep offline on
---   F-MatchFrame because C++ TMB's file_pos = source_in − first_sample_tc
---   computes to a negative offset.
---
--- Root: media.start_tc_value was set at IMPORT time from DRP's
--- claim. Relink probes the file's BWF time_reference but the
--- writer path (Media.batch_set_file_paths) gated TC updates behind
--- path_changes, so when a relink confirms an unchanged path no TC
--- sync fires. Joe's directive (2026-05-16): "when relink runs
--- those start tc's MUST be replaced by what's in the file chosen
--- by relink."
---
--- This test: build an audio-only master whose media row carries the
--- old start_tc_value overload (audio TC stored in start_tc_value
--- with rate == sample_rate). Run RelinkClips with a clean-shape
--- probed_tc (start_tc_audio_samples set, start_tc_value nil — the
--- normalized post-overload form). Assert that:
---   1. media.metadata uses the new clean shape (no audio TC in
---      start_tc_value).
---   2. Audio MR timeline_start_frame and source_in_frame both
---      equal the BWF audio TC in samples.
---   3. They agree on the same TC moment.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_audio_only_overwrites_tc.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")
local json = require("dkjson")

local Media = require("models.media")
local Sequence = require("models.sequence")

local function media_refs_by_type(media_id, track_type)
    local stmt = database.get_connection():prepare([[
        SELECT mr.id, mr.timeline_start_frame, mr.source_in_frame,
               mr.source_out_frame, mr.duration_frames
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        WHERE mr.media_id = ? AND t.track_type = ?
        ORDER BY mr.id
    ]])
    assert(stmt, "prepare failed")
    stmt:bind_value(1, media_id)
    stmt:bind_value(2, track_type)
    assert(stmt:exec())
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

local function load_media_metadata(media_id)
    local stmt = database.get_connection():prepare(
        "SELECT metadata FROM media WHERE id = ?")
    stmt:bind_value(1, media_id)
    assert(stmt:exec() and stmt:next())
    local meta_str = stmt:value(0)
    stmt:finalize()
    return json.decode(meta_str)
end

local TEST_DB = "/tmp/jve/test_relink_audio_only_overwrites_tc.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Numbers mirror the live anamnesis-gold-timeline bug.
local SR             = 48000
-- Stale DRP claim: file is at TC 172508160 samples (≈ 59m54s @ 48k).
local STALE_TC_SAMP  = 172508160
-- Probed BWF time_reference from the actual file — 188160 samples earlier.
local BWF_TC_SAMP    = 172320000
local DUR_SAMPLES    = 219440640   -- ~76 min stereo mix
assert(STALE_TC_SAMP ~= BWF_TC_SAMP,
    "fixture: stale and probed TCs must differ to exercise the bug")

local now        = os.time()
local project_id = "proj-audio-only-relink"
local media_id   = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'P', 'resample', %d, %d, '{}');
]], project_id, now, now))

-- Audio-only media row in the NEW clean shape: start_tc_audio_samples
-- carries the file's audio TC; start_tc_value stays nil (V-only). This
-- mirrors what build_media_metadata + the relinker probe now produce.
local media = Media.create({
    id = media_id, project_id = project_id,
    file_path = "/old/path/Anemnesis Stereo Mix.wav",
    name = "Anemnesis Stereo Mix.wav",
    duration_frames = DUR_SAMPLES,           -- audio-only: frames === samples
    fps_numerator = SR, fps_denominator = 1, -- DRP convention: frame_rate == sr
    audio_channels = 2, audio_sample_rate = SR,
    metadata = json.encode({
        -- No start_tc_value — file has no video stream.
        start_tc_audio_samples = STALE_TC_SAMP,
        start_tc_audio_rate    = SR,
    }),
})
media:save(db)

Sequence.ensure_master(media_id, project_id)

-- Pre-relink invariant: master audio MR's ts and source_in should
-- match each other at the stale TC (both derive from the same overload).
print("\n--- Pre-relink: audio MR at stale TC (both columns agree) ---")
do
    local a = media_refs_by_type(media_id, "AUDIO")
    assert(#a >= 1, "expected ≥1 audio MR")
    for _, r in ipairs(a) do
        assert(r.timeline_start_frame == r.source_in_frame, string.format(
            "pre-relink invariant: audio MR ts (%d) must equal source_in (%d) "
            .. "for audio-only master (both express the same TC in samples). "
            .. "If this fires, ensure_master is already producing the bug.",
            r.timeline_start_frame, r.source_in_frame))
        assert(r.timeline_start_frame == STALE_TC_SAMP, string.format(
            "pre-relink: audio MR ts must equal stale TC (%d), got %d",
            STALE_TC_SAMP, r.timeline_start_frame))
    end
    print(string.format("  ✓ %d audio MR(s): ts=source_in=%d (stale TC)",
        #a, a[1].timeline_start_frame))
end

-- Bootstrap a record sequence so command_manager.init has an edit target.
local rec_seq_id = uuid.generate()
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Rec', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 500, 0, '[]', '[]', '[]', 0, %d, %d);
]], rec_seq_id, project_id, now, now))

command_manager.init(rec_seq_id, project_id)

-- Run relink: pass CLEAN-shape probed_tc (post-normalization).
-- start_tc_value omitted because file has no video stream.
-- start_tc_audio_samples carries the BWF time_reference.
print("\n--- Run RelinkClips with clean-shape probed TC ---")
local cmd = Command.create("RelinkClips", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("clip_relink_map", {})
cmd:set_parameter("media_path_changes", {
    [media_id] = "/new/path/Anemnesis Stereo Mix.wav",
})
cmd:set_parameter("media_tc_updates", {
    [media_id] = {
        start_tc_audio_samples = BWF_TC_SAMP,
        start_tc_audio_rate    = SR,
        -- start_tc_value intentionally nil — no video stream.
    },
})
cmd:set_parameter("media_duration_updates", {
    [media_id] = {
        duration_frames        = DUR_SAMPLES,  -- audio-only: frames == samples
        audio_duration_samples = DUR_SAMPLES,
    },
})

local result = command_manager.execute(cmd)
assert(result and result.success,
    "RelinkClips must succeed: " .. tostring(result and result.error_message))

-- ── Assertion 1: media metadata uses the clean shape ──
print("\n--- Post-relink: media metadata in normalized shape ---")
local meta = load_media_metadata(media_id)
assert(meta.start_tc_audio_samples == BWF_TC_SAMP, string.format(
    "media.start_tc_audio_samples must reflect the new file's BWF TC "
    .. "(got %s, expected %d). Relink is the authoritative TC writer "
    .. "for the chosen file.",
    tostring(meta.start_tc_audio_samples), BWF_TC_SAMP))
assert(meta.start_tc_audio_rate == SR,
    "media.start_tc_audio_rate must equal sample rate")
assert(meta.start_tc_value == nil, string.format(
    "media.start_tc_value must be nil for audio-only files post-normalization "
    .. "(got %s). The old start_tc_value overload (audio TC stored under "
    .. "start_tc_value with rate == sr) is what produced the 4-second bug.",
    tostring(meta.start_tc_value)))
print(string.format("  ✓ metadata: start_tc_audio_samples=%d (start_tc_value nil)",
    meta.start_tc_audio_samples))

-- ── Assertion 2: audio MR placement + source columns BOTH at BWF TC ──
print("\n--- Post-relink: audio MR ts == source_in == BWF TC (samples) ---")
local a_refs_post = media_refs_by_type(media_id, "AUDIO")
for _, r in ipairs(a_refs_post) do
    assert(r.timeline_start_frame == BWF_TC_SAMP, string.format(
        "audio MR.timeline_start_frame must rebase to file's BWF audio TC "
        .. "(got %d, want %d samples). For audio-only master master.fps == "
        .. "sample_rate, so placement frames === samples.",
        r.timeline_start_frame, BWF_TC_SAMP))
    assert(r.source_in_frame == BWF_TC_SAMP, string.format(
        "audio MR.source_in_frame must equal new BWF TC (got %d, want %d). "
        .. "C++ TMB: file_pos = source_in − first_sample_tc; mismatch with "
        .. "first_sample_tc produces negative offsets → offline beep.",
        r.source_in_frame, BWF_TC_SAMP))
    assert(r.timeline_start_frame == r.source_in_frame, string.format(
        "audio MR ts (%d) must equal source_in (%d) for audio-only master "
        .. "— resolver walks ts space, decoder reads source_in space; any "
        .. "divergence is the 4-second-late / beep-on-F bug.",
        r.timeline_start_frame, r.source_in_frame))
    assert(r.source_out_frame == BWF_TC_SAMP + DUR_SAMPLES, string.format(
        "audio MR.source_out_frame must equal new_origin + duration "
        .. "(got %d, want %d)", r.source_out_frame, BWF_TC_SAMP + DUR_SAMPLES))
    assert(r.duration_frames == DUR_SAMPLES, string.format(
        "audio MR.duration_frames must equal new audio duration in samples "
        .. "(audio-only master: frames === samples). got %d, want %d",
        r.duration_frames, DUR_SAMPLES))
end
print(string.format("  ✓ %d audio MR(s): ts=source_in=%d, span=[%d, %d)",
    #a_refs_post, a_refs_post[1].timeline_start_frame,
    a_refs_post[1].source_in_frame, a_refs_post[1].source_out_frame))

-- ── Assertion 3: undo restores the stale state ──
print("\n--- Undo: media MR + metadata restore to pre-relink ---")
local undo_result = command_manager.undo()
assert(undo_result and undo_result.success,
    "undo must succeed: " .. tostring(undo_result and undo_result.error_message))
do
    local a = media_refs_by_type(media_id, "AUDIO")
    for _, r in ipairs(a) do
        assert(r.timeline_start_frame == STALE_TC_SAMP and
               r.source_in_frame == STALE_TC_SAMP,
            "undo: audio MR ts/source_in must restore to stale TC")
    end
    local m = load_media_metadata(media_id)
    assert(m.start_tc_audio_samples == STALE_TC_SAMP,
        "undo: media.start_tc_audio_samples must restore to pre-relink value")
    assert(m.start_tc_value == nil,
        "undo: media.start_tc_value must remain nil for audio-only file")
end
print("  ✓ undo restored audio MR + metadata")

print("\n✅ test_relink_audio_only_overwrites_tc.lua passed")
