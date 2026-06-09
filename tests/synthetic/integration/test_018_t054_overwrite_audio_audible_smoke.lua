-- 018 T054 smoke (automated replacement for the manual F10 check).
--
-- End-to-end Primary User Story:
--   New V11 project (canonical-flicks clock, default_fps=25/1) →
--   build dual-medium V+A master pointing at countdown_chirp_30s.mp4
--   (25 fps, 48 kHz mono, time-varying audio) →
--   set master marks at [200, 400) frames (8s-16s into the file) →
--   Overwrite onto a record sequence at playhead 0 →
--   pull the resolver entry the playback engine would produce →
--   feed it to a real C++ TMB through the exact same
--   PlaybackEngine:_build_tmb_clip path that production uses →
--   decode 0.5 seconds of audio at a playhead position INSIDE the new clip →
--   assert RMS > 0.001 (audible).
--
-- Why drive `_build_tmb_clip` rather than crafting the TMB clip by hand
-- like test_playback_av_sync.lua does: that test sidesteps the engine's
-- entry→clip converter, so it can't catch a unit mismatch BETWEEN the
-- resolver and the converter. The F10 silence symptom 018 was written to
-- fix lives precisely at that seam (resolver gives audio source_in in
-- file-natural samples; the converter must hand TMB a matching rate).
-- A smoke that bypasses the converter cannot fail when the converter is
-- wrong.

local ienv = require("synthetic.integration.integration_test_env")
local ffi  = require("ffi")
local EMP  = ienv.require_emp()

print("=== test_018_t054_overwrite_audio_audible_smoke.lua ===")

require("test_env")
local database  = require("core.database")
local Sequence  = require("models.sequence")
local Overwrite = require("core.commands.overwrite")
local PlaybackEngine = require("core.playback.playback_engine")

local MEDIA_PATH = ienv.test_media_path("countdown_chirp_30s.mp4")
local FPS_NUM, FPS_DEN = 25, 1
local SR              = 48000
local CHANNELS        = 1
local NATIVE_FRAMES   = 750
local SAMPLES_PER_FRAME = SR * FPS_DEN / FPS_NUM  -- 1920 (exact)
local MASTER_CLOCK    = 705600000

local MARK_IN  = 200
local MARK_OUT = 400

-- ── Fresh V11 project + master + record sequence + media_refs ───────
local DB = "/tmp/jve/test_018_t054_smoke.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB), "database.init failed")
local db = database.get_connection()
local now = os.time()

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
        created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":%d,"default_fps":{"num":%d,"den":%d}}',
            %d, %d);

    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, created_at, modified_at)
    VALUES ('m', 'p', 'M', 'master',   %d, %d, NULL,  320, 240, 0, %d, %d),
           ('e', 'p', 'E', 'sequence', %d, %d, 48000, 320, 240, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index) VALUES
        ('m-v1', 'm', 'V1', 'VIDEO', 1),
        ('m-a1', 'm', 'A1', 'AUDIO', 1),
        ('e-v1', 'e', 'V1', 'VIDEO', 1),
        ('e-a1', 'e', 'A1', 'AUDIO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('med', 'p', 'chirp.mp4', '%s', %d, %d, %d, %d, %d, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-v', 'p', 'm', 'm-v1', 'med', 0, %d, 0, %d,
            1, 1.0, 0, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('mr-a', 'p', 'm', 'm-a1', 'med', 0, %d, 0, %d,
            %d, 1, 1.0, 0, %d, %d);
]],
    MASTER_CLOCK, FPS_NUM, FPS_DEN,
    now, now,
    FPS_NUM, FPS_DEN, now, now,
    FPS_NUM, FPS_DEN, now, now,
    MEDIA_PATH, NATIVE_FRAMES, FPS_NUM, FPS_DEN, CHANNELS, SR, now, now,
    NATIVE_FRAMES, NATIVE_FRAMES, now, now,
    NATIVE_FRAMES * SAMPLES_PER_FRAME, NATIVE_FRAMES,
    SR, now, now)))

assert(db:exec(string.format(
    "UPDATE sequences SET mark_in_frame=%d, mark_out_frame=%d WHERE id='m'",
    MARK_IN, MARK_OUT)))

-- ── F10 equivalent ─────────────────────────────────────────────────
local result = Overwrite.execute({
    sequence_id          = "e",
    source_sequence_id   = "m",
    sequence_start_frame = 0,
})
assert(result and result.audio_clip_id, "Overwrite did not produce an audio clip")

-- ── Clip-row invariants (018 surface) ──────────────────────────────
local stmt = assert(db:prepare([[
    SELECT source_in_frame, source_out_frame,
           source_in_subframe, source_out_subframe
    FROM clips WHERE id = ?
]]))
stmt:bind_value(1, result.audio_clip_id)
assert(stmt:exec() and stmt:next())
local clip = { si = stmt:value(0), so = stmt:value(1),
               ssi = stmt:value(2), sso = stmt:value(3) }
stmt:finalize()
assert(clip.si == MARK_IN and clip.so == MARK_OUT,
    string.format("audio clip source_*_frame must be master.fps frames; got %d/%d, want %d/%d",
        clip.si, clip.so, MARK_IN, MARK_OUT))
assert(clip.ssi == 0 and clip.sso == 0,
    "subframes must be 0 at 25/48k frame-aligned marks")
print("  PASS: clip row — source in master.fps frames; subframes=0")

-- ── Build a real PlaybackEngine to exercise the production
--    resolver → _build_tmb_clip → TMB path. ──────────────────────────
local seq_obj = assert(Sequence.load("e"), "Sequence.load returned nil")
seq_obj.audio_sample_rate = SR

-- Pull entries the playback engine would consume, then run them through
-- the engine's own resolver→TMB converter. _build_tmb_clip and
-- _compute_audio_speed_ratio only read `self.fps_num/fps_den`, so a
-- minimal stand-in `self` reproduces the production conversion exactly
-- without spinning up a CVDisplayLink-bound engine.
local entries = seq_obj:get_audio_in_range(0, MARK_OUT - MARK_IN)
assert(#entries > 0, "get_audio_in_range returned no entries")
local audio_entry = entries[1]

local engine_self = { fps_num = FPS_NUM, fps_den = FPS_DEN }
local speed = PlaybackEngine._compute_audio_speed_ratio(engine_self, audio_entry)
if audio_entry.source_in and audio_entry.source_out
    and audio_entry.source_out < audio_entry.source_in then
    speed = -speed
end
local tmb_clip = PlaybackEngine._build_tmb_clip(engine_self, audio_entry, speed)

-- ── Decode 0.5s of audio at PLAYHEAD inside the new clip. ──────────
local PLAYHEAD = 50  -- 50 frames in = 2s into the clip = ~10s into chirp
local PLAYHEAD_US = math.floor(PLAYHEAD * 1000000 * FPS_DEN / FPS_NUM)
local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { tmb_clip })

local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, PLAYHEAD_US,
    PLAYHEAD_US + 500000, SR, CHANNELS)
assert(pcm, string.format(
    "TMB_GET_TRACK_AUDIO returned nil — playback engine's resolver→TMB "
    .. "conversion produced an audio clip the decoder can't seek into. "
    .. "TMB clip: source_in=%d rate=%d/%d. F10'd audio would be silent.",
    tmb_clip.source_in, tmb_clip.rate_num, tmb_clip.rate_den))

local info = EMP.PCM_INFO(pcm)
assert(info.frames > 0,
    "TMB returned 0 audio frames — decoder could open the file but "
    .. "couldn't extract samples at the resolved file position")

local function rms(pcm_handle)
    local i = EMP.PCM_INFO(pcm_handle)
    local p = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm_handle))
    local n = i.frames * i.channels
    local s = 0
    for k = 0, n - 1 do local x = p[k]; s = s + x * x end
    return math.sqrt(s / n)
end
local r = rms(pcm)
EMP.TMB_CLOSE(tmb)
assert(r > 0.001, string.format(
    "FAIL: F10'd audio at PLAYHEAD=%d (clip_id=%s) decoded with RMS=%.6f "
    .. "— silent. This is the FR-025 user-visible bug. "
    .. "TMB clip: source_in=%d rate=%d/%d.",
    PLAYHEAD, tmb_clip.clip_id:sub(1,8), r,
    tmb_clip.source_in, tmb_clip.rate_num, tmb_clip.rate_den))
print(string.format("  PASS: F10'd audio decodes audible (RMS=%.4f, %d frames)",
    r, info.frames))

-- Reference decode: same file, same window, hand-crafted with the
-- known-good (samples, sample_rate) contract. Match within codec
-- jitter to prove the resolver path lands on the SAME content.
local tmb_ref = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb_ref, FPS_NUM, FPS_DEN)
EMP.TMB_SET_AUDIO_FORMAT(tmb_ref, SR, CHANNELS)
EMP.TMB_SET_TRACK_CLIPS(tmb_ref, "audio", 1, {{
    clip_id        = "ref",
    media_path     = MEDIA_PATH,
    sequence_start = 0,
    duration       = MARK_OUT - MARK_IN,
    source_in      = MARK_IN * SAMPLES_PER_FRAME,
    rate_num       = SR,
    rate_den       = 1,
    speed_ratio    = 1.0,
}})
local pcm_ref = EMP.TMB_GET_TRACK_AUDIO(tmb_ref, 1, PLAYHEAD_US,
    PLAYHEAD_US + 500000, SR, CHANNELS)
assert(pcm_ref and EMP.PCM_INFO(pcm_ref).frames > 0,
    "reference decode produced no frames")
local r_ref = rms(pcm_ref)
EMP.TMB_CLOSE(tmb_ref)

local rel = math.abs(r - r_ref) / math.max(r_ref, 1e-6)
assert(rel < 0.05, string.format(
    "RMS via resolver=%.4f vs direct=%.4f at same offset — relative %.2f%%; "
    .. "resolver path lands on a different region of the file",
    r, r_ref, rel * 100))
print(string.format("  PASS: resolver-path audio matches direct decode (Δ=%.2f%%)",
    rel * 100))

print("\n✅ test_018_t054_overwrite_audio_audible_smoke.lua passed")
