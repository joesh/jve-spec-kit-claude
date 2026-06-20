#!/usr/bin/env luajit
-- Domain: an expanded per-channel audio clip plays the audio channel of the
-- master audio track it is pinned to (master_audio_track_id). On a multi-channel
-- master (a synced clip with several external audio channels), two expanded
-- clips that pin two DIFFERENT master audio tracks must resolve to those tracks'
-- DIFFERENT source channels — not one arbitrary channel shared by both.
--
-- The bug this guards: load_clips joined media_refs by track_type alone (any
-- AUDIO ref of the master), so GROUP BY picked an arbitrary channel and every
-- expanded clip on the same master drew the SAME (wrong) waveform channel.

require("test_env")
_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = { get_active_sequence_monitor = function() return nil end }

local database = require("core.database")
local Project  = require("models.project")
local Sequence = require("models.sequence")
local Track    = require("models.track")
local Clip     = require("models.clip")
local Media    = require("models.media")
local dkjson   = require("dkjson")

local DB = "/tmp/jve/test_expanded_clip_channel_pinning.db"
os.execute("mkdir -p /tmp/jve")
for _, s in ipairs({ "", "-wal", "-shm" }) do os.remove(DB .. s) end
assert(database.init(DB))
local db = database.get_connection()

print("=== test_expanded_clip_channel_pinning.lua ===")

-- ── Project ──────────────────────────────────────────────────────────────────
local project = Project.create("Chan", {
    id = "p", fps_mismatch_policy = "resample",
    settings = { master_clock_hz = 192000, default_fps = { num = 24, den = 1 } },
})
assert(project:save())

-- ── Multi-channel master: video (2ch camera scratch) + synced 5ch external WAV.
-- ensure_master writes one audio track per channel, each media_ref carrying a
-- distinct source_channel (camera 0..1, sync 0..4).
local tc_frames  = 86400
local tc_samples = 172800000
local vid = Media.create({
    id = "vid", project_id = "p", name = "A001_C001.mov",
    file_path = "synthetic://A001_C001.mov",
    duration_frames = 240, fps_numerator = 24, fps_denominator = 1,
    width = 1920, height = 1080, audio_channels = 2, audio_sample_rate = 48000,
    codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = tc_frames, start_tc_rate = 24,
        start_tc_audio_samples = tc_samples, start_tc_audio_rate = 48000 }),
})
assert(vid:save())
local ext = Media.create({
    id = "ext", project_id = "p", name = "A001.wav",
    file_path = "synthetic://A001.wav",
    duration_frames = 480000, fps_numerator = 48000, fps_denominator = 1,
    width = 0, height = 0, audio_channels = 5, audio_sample_rate = 48000,
    codec = "pcm",
    metadata = dkjson.encode({
        start_tc_audio_samples = tc_samples, start_tc_audio_rate = 48000 }),
})
assert(ext:save())

local master_seq = Sequence.ensure_master("vid", "p", {
    synced_audio_streams = { { media_id = "ext", sample_offsets = { 0, 0, 0, 0, 0 } } },
})

-- Learn the master's (audio track id -> source_channel) mapping from the DATA
-- itself, not from the query under test. Channels 3 and 4 exist only on the
-- 5ch sync stream (camera scratch is 2ch), so they unambiguously name sync tracks.
local function master_sync_track_for_channel(ch)
    local q = assert(db:prepare([[
        SELECT t.id FROM tracks t
        JOIN media_refs mr ON mr.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND mr.source_channel = ? AND t.source_kind = 'sync'
        LIMIT 1 ]]))
    q:bind_value(1, master_seq)
    q:bind_value(2, ch)
    assert(q:exec())
    local id = q:next() and q:value(0) or nil
    q:finalize()
    return id
end
local track_ch3 = master_sync_track_for_channel(3)
local track_ch4 = master_sync_track_for_channel(4)
assert(track_ch3 and track_ch4 and track_ch3 ~= track_ch4,
    "fixture: master must have distinct sync audio tracks for channels 3 and 4")

-- ── Owner timeline sequence + one audio track holding two expanded clips, each
-- pinning a different master audio track. ───────────────────────────────────
local owner = Sequence.create("Timeline", "p", { fps_numerator = 24, fps_denominator = 1 },
    1920, 1080, { id = "owner", kind = "sequence", audio_sample_rate = 48000,
        view_start_frame = 0, view_duration_frames = 10000, playhead_frame = 0 })
assert(owner:save())
local a1 = Track.create_audio("A1", "owner", { index = 1 })
assert(a1:save())

local function expanded_clip(id, start_frame, pinned_track)
    return Clip.create({
        id = id, project_id = "p", owner_sequence_id = "owner", track_id = a1.id,
        sequence_id = master_seq, master_audio_track_id = pinned_track,
        name = "exp", sequence_start_frame = start_frame, duration_frames = 100,
        source_in_frame = 48000, source_out_frame = 96000,
        source_in_subframe = 0, source_out_subframe = 0,
        fps_mismatch_policy = "resample", enabled = true, volume = 1.0,
        playhead_frame = 0,
    })
end
expanded_clip("clip_lo", 0, track_ch3)
expanded_clip("clip_hi", 500, track_ch4)

-- ── Assert each expanded clip resolves to ITS pinned channel. ────────────────
local clips = database.load_clips("owner")
local by_id = {}
for _, c in ipairs(clips) do by_id[c.id] = c end
assert(by_id.clip_lo and by_id.clip_hi, "both expanded clips must load")
assert(by_id.clip_lo.resolved_media, "clip_lo must resolve a media ref")
assert(by_id.clip_hi.resolved_media, "clip_hi must resolve a media ref")

assert(by_id.clip_lo.resolved_media.source_channel == 3, string.format(
    "expanded clip pinned to the channel-3 master track must read channel 3, got %s",
    tostring(by_id.clip_lo.resolved_media.source_channel)))
assert(by_id.clip_hi.resolved_media.source_channel == 4, string.format(
    "expanded clip pinned to the channel-4 master track must read channel 4, got %s",
    tostring(by_id.clip_hi.resolved_media.source_channel)))
print("  ✓ load_clips: each expanded per-channel clip resolves to its pinned master channel")

-- Same invariant via the single-clip entry path (load_clip_entry shares the JOIN).
local lo = database.load_clip_entry("clip_lo")
local hi = database.load_clip_entry("clip_hi")
assert(lo and lo.resolved_media and lo.resolved_media.source_channel == 3, string.format(
    "load_clip_entry(clip_lo) must read channel 3, got %s",
    lo and lo.resolved_media and tostring(lo.resolved_media.source_channel) or "nil"))
assert(hi and hi.resolved_media and hi.resolved_media.source_channel == 4, string.format(
    "load_clip_entry(clip_hi) must read channel 4, got %s",
    hi and hi.resolved_media and tostring(hi.resolved_media.source_channel) or "nil"))
print("  ✓ load_clip_entry: pinned channel preserved on the single-clip path")

print("✅ test_expanded_clip_channel_pinning.lua passed")
