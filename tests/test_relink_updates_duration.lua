#!/usr/bin/env luajit

-- Relink must refresh the media's duration_frames AND the spans of every
-- media_ref that points at the media. Symptom (reported 2026-05-12): a
-- DRP-imported clip carried duration_frames=2913 (1m56s) because the
-- file was 1m56s when Resolve indexed it. The file was later trimmed
-- to 30.2s (755 frames) on disk. After relinking in JVE, file_path and
-- TC origin update, but duration_frames stays at 2913 — so the source
-- viewer reports the clip as 1m56s, edits use the stale extent, and
-- playback falls offline past frame 755.
--
-- This regression test sets up the same shape: media row + V/A
-- media_refs with stale durations, then runs RelinkClips with a new
-- probed-duration for the file. Asserts media.duration_frames and the
-- media_refs' duration_frames (V in frames, A in samples) follow the
-- probed file.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_updates_duration.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Media = require("models.media")

local DB = "/tmp/jve/test_relink_updates_duration.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Stale state matches the user's DRP-imported A023 row exactly.
local OLD_DUR_FRAMES   = 2913          -- stale: 1m56s @ 25fps
local OLD_DUR_SAMPLES  = 5592960       -- stale: 1m56s × 48 kHz
local NEW_DUR_FRAMES   = 755           -- actual file is 30.2s @ 25fps
local NEW_DUR_SAMPLES  = 1449600       -- actual file is 30.2s × 48 kHz
local TC_ORIGIN_25     = 1248362       -- 13:52:29:07 @ 25fps
local SAMPLE_RATE      = 48000

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
]], now, now))

-- The stale media row (matches the bug report).
db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path,
        duration_frames, fps_numerator, fps_denominator,
        audio_sample_rate, audio_channels, width, height,
        codec, metadata, created_at, modified_at)
    VALUES ('media_a023', 'proj', 'A023.mov',
            '/old/stale/path/A023.mov',
            %d, 25, 1, %d, 2, 1920, 1080, 'prores',
            '{"start_tc_value":%d,"start_tc_rate":25,"start_tc_audio_samples":%d,"start_tc_audio_rate":%d}',
            %d, %d);
]], OLD_DUR_FRAMES, SAMPLE_RATE, TC_ORIGIN_25,
    TC_ORIGIN_25 * SAMPLE_RATE / 25, SAMPLE_RATE, now, now))

-- Master sequence + V/A media_refs sized to the old (stale) duration.
-- A bootstrap record sequence is added below so command_manager.init can
-- be called with a record id (FR-005: active edit target must never be a
-- master). The relink path under test is project-scoped — it touches the
-- master row directly and is agnostic to which sequence is active.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, start_timecode_frame, playhead_frame,
        view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('rec_bootstrap', 'proj', 'Bootstrap', 'sequence', 25, 1, %d, 1920, 1080,
            0, 0, 0, 300, %d, %d),
           ('msa', 'proj', 'A023 Master', 'master', 25, 1, %d, 1920, 1080,
            %d, 0, 0, %d, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('msa_v', 'msa', 'V1', 'VIDEO', 1, 1),
      ('msa_a', 'msa', 'A1', 'AUDIO', 1, 1);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        timeline_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mref_v', 'proj', 'msa', 'msa_v', 'media_a023', 0, %d,
            %d, %d, 1, 1.0, 0, %d, %d),
      ('mref_a', 'proj', 'msa', 'msa_a', 'media_a023', 0, %d,
            %d, %d, 1, 1.0, 0, %d, %d);
]], SAMPLE_RATE, now, now, SAMPLE_RATE, TC_ORIGIN_25, OLD_DUR_FRAMES, now, now,
    OLD_DUR_FRAMES, TC_ORIGIN_25, OLD_DUR_FRAMES, now, now,
    OLD_DUR_SAMPLES, TC_ORIGIN_25 * SAMPLE_RATE / 25, OLD_DUR_SAMPLES,
    now, now))

command_manager.init('rec_bootstrap', 'proj')

-- Drive RelinkClips with a freshly-probed file: same TC origin, but the
-- new file is 755 frames (matches the ffprobe of the actual fixture).
local NEW_PATH = "/new/correct/path/A023.mov"
local result = command_manager.execute("RelinkClips", {
    project_id = "proj",
    clip_relink_map = {},  -- no clip writes; this relink is media-only
    media_path_changes = { ["media_a023"] = NEW_PATH },
    media_tc_updates   = { ["media_a023"] = {
        start_tc_value = TC_ORIGIN_25,
        start_tc_rate = 25,
        start_tc_audio_samples = TC_ORIGIN_25 * SAMPLE_RATE / 25,
        start_tc_audio_rate = SAMPLE_RATE,
    } },
    media_duration_updates = { ["media_a023"] = {
        duration_frames = NEW_DUR_FRAMES,
        audio_duration_samples = NEW_DUR_SAMPLES,
    } },
})
assert(result and result.success,
    "RelinkClips must succeed: " .. tostring(result and result.error_message))

-- ── Assertion 1: media.duration_frames updated ──
local m = Media.load("media_a023")
assert(m, "media row must exist after relink")
-- Media model exposes file_path via getter (private _file_path field).
local mpath = m:get_file_path()
assert(mpath == NEW_PATH,
    string.format("file_path: expected %s, got %s", NEW_PATH, tostring(mpath)))
assert(m.duration == NEW_DUR_FRAMES, string.format(
    "media.duration_frames: expected %d (probed), got %s — relink must "
    .. "refresh the length, not just the TC",
    NEW_DUR_FRAMES, tostring(m.duration)))
print(string.format("  ✓ media.duration_frames updated %d → %d",
    OLD_DUR_FRAMES, m.duration))

-- ── Assertion 2: V media_ref duration_frames updated ──
local stmt = db:prepare(
    "SELECT duration_frames FROM media_refs WHERE id = 'mref_v'")
assert(stmt and stmt:exec() and stmt:next())
local vdur = stmt:value(0)
stmt:finalize()
assert(vdur == NEW_DUR_FRAMES, string.format(
    "media_refs[V].duration_frames: expected %d, got %d — every "
    .. "media_ref over this media must follow the new file",
    NEW_DUR_FRAMES, vdur))
print(string.format("  ✓ V media_ref duration_frames updated %d → %d",
    OLD_DUR_FRAMES, vdur))

-- ── Assertion 3: A media_ref duration in samples updated ──
local stmt_a = db:prepare(
    "SELECT duration_frames FROM media_refs WHERE id = 'mref_a'")
assert(stmt_a and stmt_a:exec() and stmt_a:next())
local adur = stmt_a:value(0)
stmt_a:finalize()
assert(adur == NEW_DUR_SAMPLES, string.format(
    "media_refs[A].duration (samples): expected %d, got %d",
    NEW_DUR_SAMPLES, adur))
print(string.format("  ✓ A media_ref duration (samples) updated %d → %d",
    OLD_DUR_SAMPLES, adur))

-- ── Assertion 4: undo restores the pre-relink durations ──
local undo_result = command_manager.undo()
assert(undo_result and undo_result.success,
    "undo must succeed: " .. tostring(undo_result and undo_result.error_message))
local m2 = Media.load("media_a023")
assert(m2.duration == OLD_DUR_FRAMES, string.format(
    "after undo, media.duration_frames must restore to %d; got %s",
    OLD_DUR_FRAMES, tostring(m2.duration)))
local s_v = db:prepare("SELECT duration_frames FROM media_refs WHERE id = 'mref_v'")
assert(s_v and s_v:exec() and s_v:next())
assert(s_v:value(0) == OLD_DUR_FRAMES, string.format(
    "after undo, V media_ref must restore to %d; got %d",
    OLD_DUR_FRAMES, s_v:value(0)))
s_v:finalize()
local s_a = db:prepare("SELECT duration_frames FROM media_refs WHERE id = 'mref_a'")
assert(s_a and s_a:exec() and s_a:next())
assert(s_a:value(0) == OLD_DUR_SAMPLES, string.format(
    "after undo, A media_ref must restore to %d samples; got %d",
    OLD_DUR_SAMPLES, s_a:value(0)))
s_a:finalize()
print("  ✓ undo restores media + media_refs durations")

-- ── Assertion 5: orphan duration update (no matching path change) refuses ──
local asserts = require("core.asserts")
asserts._set_enabled_for_tests(false)
local bad = command_manager.execute("RelinkClips", {
    project_id = "proj",
    clip_relink_map = {},
    media_path_changes = {},   -- empty
    media_duration_updates = { ["media_a023"] = {
        duration_frames = NEW_DUR_FRAMES,
        audio_duration_samples = NEW_DUR_SAMPLES,
    } },
})
asserts._set_enabled_for_tests(true)
assert(bad and bad.success == false, "orphan duration update must refuse")
assert(tostring(bad.error_message):match("media_path_changes does not"),
    "error must explain the orphan: " .. tostring(bad.error_message))
print("  ✓ orphan duration update refused with clear error")

print("✅ test_relink_updates_duration.lua passed")
