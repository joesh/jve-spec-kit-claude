-- Integration test: when a media file's bytes are rewritten in place,
-- TMB MUST re-decode on the next GetVideoFrame rather than returning
-- cached frames from the old bytes.
--
-- Domain behavior under test:
--   1. Decode frame N from a media file → TMB caches the decoded pixels.
--   2. Overwrite that file with different content at the same path.
--   3. Emit `media_content_changed` (the signal the FS watcher fires on
--      in-place rewrite).
--   4. Decode frame N again → pixels MUST reflect the new bytes on disk,
--      not TMB's cached copy.
--
-- Uses two fixtures with identical container/codec/dimensions but
-- different visual content. Same path, different bytes.
--
-- Runs via: ./build/bin/jve --test tests/integration/test_tmb_content_rewrite_invalidation.lua

local ienv = require("integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")
local ffi = require("ffi")

print("=== test_tmb_content_rewrite_invalidation.lua ===")

local SRC_A = ienv.test_media_path("A005_C052_0925BL_001.mp4")  -- 108f, h264 yuv420p
local SRC_B = ienv.test_media_path("A002_C018_0922BW_002.mp4")  -- 26f,  h264 yuv420p
local SWAP = "/tmp/jve/tmb_content_swap_" .. os.time() .. ".mp4"
os.execute("mkdir -p /tmp/jve")

local function copy_file(src, dst)
    local cmd = string.format("cp %q %q", src, dst)
    local rc = os.execute(cmd)
    assert(rc == 0 or rc == true, "cp failed: " .. cmd)
end

-- Frame pixel hash: FNV-1a over the first 8KB of the decoded image plane.
-- The two fixtures have completely different visual content, so bytes
-- differ across the whole frame — a small window is plenty to detect
-- "same vs different."
local function hash_frame(frame, info)
    local ptr = EMP.FRAME_DATA_PTR(frame)
    assert(ptr, "FRAME_DATA_PTR returned nil")
    local bytes = ffi.cast("const uint8_t*", ptr)
    local n = math.min(8192, info.stride * info.height)
    local h = 2166136261ULL
    for i = 0, n - 1 do
        h = bit.bxor(h, bytes[i])
        h = h * 16777619ULL
    end
    return tostring(h)
end

-- ------------------------------------------------------------------
-- Stage A: SWAP contains SRC_A's bytes. Build TMB + decode frame 10.
-- ------------------------------------------------------------------
copy_file(SRC_A, SWAP)

local probe = EMP.MEDIA_FILE_PROBE(SWAP)
assert(probe and probe.has_video, "probe failed on SWAP (stage A)")
local rate_num = probe.fps_numerator or 24
local rate_den = probe.fps_denominator or 1
local tc_origin = probe.first_frame_tc or 0

local clip = {
    clip_id        = "swap_clip",
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
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)

-- Wire the production contract: `media_content_changed` (fired by the FS
-- watcher on in-place byte rewrite) MUST invalidate the TMB's per-path
-- caches. This mirrors the subscription the real PlaybackEngine owns.
local listener = Signals.connect("media_content_changed", function(p)
    EMP.TMB_INVALIDATE_PATH(tmb, p)
end, 20)

local frame_a = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(frame_a, "stage A: TMB_GET_VIDEO_FRAME returned nil")
local info_a = EMP.FRAME_INFO(frame_a)
local hash_a = hash_frame(frame_a, info_a)
EMP.FRAME_RELEASE(frame_a)
print(string.format("  stage A decoded frame %d: %dx%d, hash=%s",
    PROBE_FRAME, info_a.width, info_a.height, hash_a))

-- ------------------------------------------------------------------
-- Stage B: overwrite SWAP with SRC_B (different pixels, same codec/
-- container). Emit media_content_changed — the signal the FS watcher
-- will fire on real in-place rewrite. TMB must invalidate its
-- per-path caches (reader pool, video cache, audio cache, mixed
-- cache, EOF info) so the next GetVideoFrame re-opens the file.
-- ------------------------------------------------------------------
copy_file(SRC_B, SWAP)
Signals.emit("media_content_changed", SWAP)

-- Re-park to the same frame so the pull path runs again.
EMP.TMB_SET_PLAYHEAD(tmb, PROBE_FRAME, 0, 1.0)

local frame_b = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, PROBE_FRAME)
assert(frame_b, "stage B: TMB_GET_VIDEO_FRAME returned nil")
local info_b = EMP.FRAME_INFO(frame_b)
local hash_b = hash_frame(frame_b, info_b)
EMP.FRAME_RELEASE(frame_b)
print(string.format("  stage B decoded frame %d: %dx%d, hash=%s",
    PROBE_FRAME, info_b.width, info_b.height, hash_b))

-- ------------------------------------------------------------------
-- Assertion: bytes changed on disk + invalidation fired →
-- the decoded pixels MUST differ. Equal hashes means TMB served a
-- cached frame from the stale bytes — the exact bug this test pins.
-- ------------------------------------------------------------------
assert(hash_a ~= hash_b, string.format(
    "TMB served stale pixels after content rewrite + media_content_changed "
    .. "(hash_a=%s hash_b=%s) — decoder cache invalidation regressed",
    hash_a, hash_b))

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)
os.remove(SWAP)

print("✅ test_tmb_content_rewrite_invalidation.lua passed")
os.exit(0)
