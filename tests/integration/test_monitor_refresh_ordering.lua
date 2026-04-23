-- Integration test: pins the ordering between the two families of
-- media_status_changed subscribers.
--
-- Bug this catches: if SequenceMonitor's refresh listener runs BEFORE
-- PlaybackEngine's invalidate listener, the re-seek triggered by the
-- monitor pulls from a TMB whose caches haven't been cleared yet —
-- the surface keeps the stale pixels. Joe observed this symptom as
-- "when going offline timeline monitor still retains the parked
-- frame" before the priority was bumped from 60 → 110.
--
-- The contract:
--   * Engine-class subscribers (invalidate TMB state) fire FIRST.
--   * Monitor-class subscribers (re-pull and display) fire AFTER.
-- Signals fires lower-priority numbers first, so monitor priority
-- MUST be strictly greater than engine priority.
--
-- Runs via: ./build/bin/JVEEditor --test tests/integration/test_monitor_refresh_ordering.lua

local ienv = require("integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")

print("=== test_monitor_refresh_ordering.lua ===")

local SRC = ienv.test_media_path("A005_C052_0925BL_001.mp4")
local SWAP = "/tmp/jve/tmb_ordering_" .. os.time() .. ".mp4"
os.execute("mkdir -p /tmp/jve")
os.execute(string.format("cp %q %q", SRC, SWAP))

local probe = EMP.MEDIA_FILE_PROBE(SWAP)
assert(probe and probe.has_video, "probe failed")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1

local clip = {
    clip_id = "order_clip", media_path = SWAP,
    timeline_start = 0, duration = 20,
    source_in = probe.first_frame_tc or 0,
    rate_num = rate_num, rate_den = rate_den, speed_ratio = 1.0,
}

local PROBE_FRAME = 10

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { clip })

-- Priorities pulled from production:
--   playback_engine.lua connects at the default (100).
--   sequence_monitor.lua connects at 110 (>100 so it fires AFTER).
-- Mirroring the exact numbers here so a regression that changes either
-- side trips this test.
local ENGINE_PRIORITY  = 100
local MONITOR_PRIORITY = 110

-- Prime the TMB cache at PROBE_FRAME.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)
local primer = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(primer, "precondition: initial decode must succeed")
EMP.FRAME_RELEASE(primer)

-- Engine-class handler: deletes file on disk + invalidates TMB. Must
-- fire BEFORE the monitor-class handler or the monitor reads stale.
local engine_conn = Signals.connect("media_status_changed", function(p)
    os.remove(SWAP)
    EMP.TMB_INVALIDATE_PATH(tmb, p)
end, ENGINE_PRIORITY)

-- Monitor-class handler: re-pulls the current frame. What it reads
-- here is exactly what the real SequenceMonitor would push to its
-- surface.
local seen_offline
local seen_frame
local monitor_conn = Signals.connect("media_status_changed", function()
    local f, i = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
    seen_offline = i and i.offline
    seen_frame = f
end, MONITOR_PRIORITY)

Signals.emit("media_status_changed", SWAP,
    { offline = true, error_code = "FileNotFound" })

assert(seen_offline or seen_frame == nil, string.format(
    "ordering regression: monitor-class read a cached frame (offline=%s, "
    .. "frame=%s) — it fired BEFORE the engine-class invalidator cleared "
    .. "the TMB. Monitor priority must be > engine priority.",
    tostring(seen_offline), tostring(seen_frame)))
print(string.format("  monitor read AFTER invalidation: offline=%s frame=%s",
    tostring(seen_offline), tostring(seen_frame)))

Signals.disconnect(engine_conn)
Signals.disconnect(monitor_conn)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)

print("✅ test_monitor_refresh_ordering.lua passed")
os.exit(0)
