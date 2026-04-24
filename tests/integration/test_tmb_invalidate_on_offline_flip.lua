-- Integration test: TMB must drop its per-path caches on EVERY status
-- flip, not just offline→online. Pins the regression Joe hit:
--
--   "When going offline timeline monitor still retains the parked frame"
--
-- Root cause was that PlaybackEngine's media_status_changed handler
-- only invalidated the TMB when status.offline == false. A file being
-- deleted (online→offline) left the cached frame in video_cache, and
-- the re-seek triggered by the monitor served it right back. This test
-- deletes the file, fires the status-flip signal, asks for the same
-- frame, and asserts TMB does NOT serve the stale cached pixels.
--
-- Runs via: ./build/bin/JVEEditor --test tests/integration/test_tmb_invalidate_on_offline_flip.lua

local ienv = require("integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")

print("=== test_tmb_invalidate_on_offline_flip.lua ===")

local SRC = ienv.test_media_path("A005_C052_0925BL_001.mp4")
local SWAP = "/tmp/jve/tmb_offline_flip_" .. os.time() .. ".mp4"
os.execute("mkdir -p /tmp/jve")
os.execute(string.format("cp %q %q", SRC, SWAP))

local probe = EMP.MEDIA_FILE_PROBE(SWAP)
assert(probe and probe.has_video, "probe failed on SWAP")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1
local tc_origin = probe.first_frame_tc or 0

local clip = {
    clip_id        = "offline_flip_clip",
    media_path     = SWAP,
    timeline_start = 0,
    duration       = 20,
    source_in      = tc_origin,
    rate_num       = rate_num,
    rate_den       = rate_den,
    speed_ratio    = 1.0,
}

local PROBE_FRAME = 10

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { clip })

-- Mirror the production subscription. The semantic under test is: on
-- EVERY flip, invalidate — even offline=true. The earlier (buggy)
-- version only invalidated when offline=false. A regression to that
-- form would keep serving the cached frame and trip the assertion.
local listener = Signals.connect("media_status_changed", function(p, status)
    if status then
        EMP.TMB_INVALIDATE_PATH(tmb, p)
        if not status.offline and EMP.TMB_CLEAR_OFFLINE then
            EMP.TMB_CLEAR_OFFLINE(tmb, p)
        end
    end
end, 20)

-- Stage 1: decode — file present, real frame returned and cached.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)
local f1, i1 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(f1, "stage 1: TMB must decode a real frame while file exists")
assert(i1 and not i1.offline,
    "stage 1: frame must NOT be offline while file exists")
print("  stage 1: file present → real frame cached in TMB")

-- Stage 2: delete file on disk, fire the flip signal the FS watcher
-- would emit on real delete. TMB must invalidate and the next decode
-- must NOT return the cached frame.
os.remove(SWAP)
Signals.emit("media_status_changed", SWAP,
    { offline = true, error_code = "FileNotFound" })

-- Re-park triggers a fresh cache lookup → decode → acquire_reader →
-- MediaFile::Open fails → empty handle → frame returns as offline.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)
local f2, i2 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(i2, "stage 2: info table must be present")
assert(i2.offline or f2 == nil, string.format(
    "stage 2: after delete + status flip, TMB must NOT serve the cached "
    .. "frame. Got offline=%s, frame=%s — invalidate-on-offline regressed",
    tostring(i2.offline), tostring(f2)))
print("  stage 2: file deleted + signal → TMB reports offline (no stale frame)")

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)

print("✅ test_tmb_invalidate_on_offline_flip.lua passed")
os.exit(0)
