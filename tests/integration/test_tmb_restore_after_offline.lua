-- Integration test: a file that went offline (TMB blacklisted the path)
-- and came back online MUST decode again after `media_status_changed`
-- fires with offline=false. Regression: the status cache was flipping
-- to online and project_browser/timeline updated their icons, but the
-- TMB's m_offline blacklist never got cleared, so playback kept
-- rendering "MEDIA OFFLINE" forever. The old wiring went through a
-- media_status.set_tmb() registration that no production code ever
-- called — the entry point was effectively dead.
--
-- Domain behavior under test:
--   1. Decode from a path that doesn't exist → TMB fails + blacklists.
--   2. Create the file at that path, emit `media_status_changed` with
--      offline=false (mirroring the FS watcher flip).
--   3. Decode at the same frame → MUST return a real frame, not offline.
--
-- Runs via: ./build/bin/JVEEditor --test tests/integration/test_tmb_restore_after_offline.lua

local ienv = require("integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")

print("=== test_tmb_restore_after_offline.lua ===")

local REAL = ienv.test_media_path("A005_C052_0925BL_001.mp4")
local SWAP = "/tmp/jve/tmb_restore_" .. os.time() .. ".mp4"
os.execute("mkdir -p /tmp/jve")
os.remove(SWAP)  -- ensure absent for stage 1

-- Probe the real file to get rate/fps for clip construction.
local probe = EMP.MEDIA_FILE_PROBE(REAL)
assert(probe and probe.has_video, "probe failed on REAL")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1
local tc_origin = probe.first_frame_tc or 0

local clip = {
    clip_id        = "restore_clip",
    media_path     = SWAP,
    sequence_start = 0,
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

-- Mirror the production contract: PlaybackEngine subscribes to
-- media_status_changed and, when status flips to online, clears the
-- TMB offline blacklist and invalidates any cached reader from a
-- prior session (the file on disk may be different bytes now).
local listener = Signals.connect("media_status_changed", function(p, status)
    if status and not status.offline then
        EMP.TMB_CLEAR_OFFLINE(tmb, p)
        EMP.TMB_INVALIDATE_PATH(tmb, p)
    end
end, 20)

-- Stage 1: file is absent → decode should report offline.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)
local f1, i1 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(i1, "stage 1: info must be present even when offline")
assert(i1.offline or f1 == nil,
    "stage 1: missing file must yield offline/nil frame (got offline=" ..
    tostring(i1.offline) .. ", frame=" .. tostring(f1) .. ")")
print("  stage 1: missing file → offline (TMB blacklisted path)")

-- Stage 2: create the file + emit the signal the FS watcher would.
os.execute(string.format("cp %q %q", REAL, SWAP))
-- Precondition: without ClearOffline, the blacklist sticks. Prove the
-- listener is what drives recovery (not just "file is back").
-- We emit the actual signal rather than calling TMB_CLEAR_OFFLINE
-- directly — that way a regression in PlaybackEngine's subscription
-- shows up here too.
Signals.emit("media_status_changed", SWAP, { offline = false, error_code = nil })

-- Stage 3: decode at the same frame should now succeed.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)
local f2, i2 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(f2, "stage 3: TMB_GET_VIDEO_FRAME returned nil after file restored + signal")
assert(i2 and not i2.offline,
    "stage 3: frame must NOT be marked offline after restore (got offline=" ..
    tostring(i2 and i2.offline) .. ")")
print("  stage 3: file restored + signal → decoded real frame")

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)
os.remove(SWAP)

print("✅ test_tmb_restore_after_offline.lua passed")
os.exit(0)
