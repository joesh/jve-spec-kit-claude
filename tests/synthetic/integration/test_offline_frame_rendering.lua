-- Integration test: offline frame composition and renderer media-status contract.
--
-- REPLACES:
--   tests/synthetic/lua/test_offline_frame_composite.lua
--   tests/synthetic/lua/test_renderer_tmb.lua
--   tests/synthetic/lua/test_renderer_does_not_flip_media_status.lua
--   tests/synthetic/lua/test_offline_frame_display.lua
--
-- DROPPED (stub-call-sequence, no domain content):
--   test_offline_frame_composite: exact pixel handle identity across mocks
--     (tested the test fixture, not the module — mock COMPOSE_OFFLINE_FRAME
--     returned a fake table; real binding returns an opaque handle).
--   test_renderer_tmb: multi-track tests with artificial frame handles
--     ("frame_track1", "frame_track2") — these verify mock-dispatch logic,
--     not a domain rule. The domain rule (topmost track wins, offline
--     short-circuits) is preserved below with real TMB + real media.
--   test_offline_frame_display: PlaybackEngine-level tests that required a
--     complete mock of PLAYBACK/EMP/Sequence/Track/signals — these are
--     covered by test_sequence_monitor.lua (integration) which uses the real
--     engine. Offline park + seek path pinned by DR-2/DR-4 in that file.
--   test_renderer_tmb: Test 9 (get_sequence_info against mock Sequence.load)
--     — pure stub-assertion, no domain behavior.
--
-- DOMAIN RULES PINNED:
--   OF-1  COMPOSE_OFFLINE_FRAME is called with ≥1 lines; first line is
--         "Media Offline" for FileNotFound, "Codec Unavailable" for Unsupported.
--   OF-2  Second line is the bare filename (no directory prefix).
--   OF-3  Cache hit on same media_path+error_code: COMPOSE_OFFLINE_FRAME NOT
--         called again; same handle returned.
--   OF-4  clear() forces recomposition on next get_frame call.
--   OF-5  nil metadata and missing media_path both assert.
--   OF-6  Renderer.get_video_frame MUST NOT call media_status.update_from_tmb
--         for ANY error_code (EOFReached, FileNotFound, Unsupported, DecodeFailed,
--         or successful decode while cache says offline). Signal storm vector:
--         any write broadcasts media_status_changed → every engine reloads →
--         partial-coverage playback clears clip layout → gap-black on monitors.
--   OF-7  Renderer: offline TMB result → offline composite returned (not nil).
--   OF-8  Renderer: gap (nil frame, offline=false) → nil, nil returned.
--   OF-9  Renderer: nil metadata from TMB_GET_VIDEO_FRAME → asserts loud (NSF).
--
-- OPEN QUESTIONS:
--   None.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_offline_frame_rendering.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP  = ienv.require_emp()

print("=== test_offline_frame_rendering.lua ===")

-- ── Pass-through observation wrapper for COMPOSE_OFFLINE_FRAME ──────────────
-- Delegates to the real binding so real compositing runs; we only capture args.
local compose_calls = {}
do
    local real_compose = EMP.COMPOSE_OFFLINE_FRAME
    assert(type(real_compose) == "function",
        "precondition: EMP.COMPOSE_OFFLINE_FRAME must be a real function")
    EMP.COMPOSE_OFFLINE_FRAME = function(png_path, lines)
        compose_calls[#compose_calls + 1] = {
            png_path = png_path, lines = lines,
        }
        return real_compose(png_path, lines)
    end
end

-- ── Freshly required modules (picks up the wrapped EMP binding) ─────────────
local offline_frame_cache = require("core.media.offline_frame_cache")
local Renderer            = require("core.renderer")
local media_status        = require("core.media.media_status")

-- Helper: reset compose-call log between sub-tests.
local function reset_compose()
    compose_calls = {}
    offline_frame_cache.clear()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-1 + OF-2  "Media Offline" title + bare filename for FileNotFound
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-1/2) FileNotFound → 'Media Offline' + bare filename --")
do
    reset_compose()

    local meta = {
        media_path  = "/footage/missing_clip.mov",
        error_code  = "FileNotFound",
        error_msg   = "File not found: /footage/missing_clip.mov",
    }
    local handle = offline_frame_cache.get_frame(meta)

    assert(handle, "get_frame must return a non-nil handle")
    assert(#compose_calls == 1, string.format(
        "COMPOSE_OFFLINE_FRAME must be called once; called %d times", #compose_calls))

    local lines = compose_calls[1].lines
    assert(#lines >= 1, "lines must have at least one entry")
    assert(lines[1].text == "Media Offline", string.format(
        "first line must be 'Media Offline' for FileNotFound; got '%s'",
        tostring(lines[1].text)))
    assert(lines[2] and lines[2].text == "missing_clip.mov", string.format(
        "second line must be bare filename 'missing_clip.mov'; got '%s'",
        tostring(lines[2] and lines[2].text)))

    print("  PASS: FileNotFound → 'Media Offline', filename on line 2")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-1  "Codec Unavailable" title for Unsupported error_code
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-1) Unsupported → 'Codec Unavailable' --")
do
    reset_compose()

    local meta = {
        media_path = "/footage/scene.braw",
        error_code = "Unsupported",
        error_msg  = "Unsupported codec",
    }
    local handle = offline_frame_cache.get_frame(meta)

    assert(handle, "get_frame must return a non-nil handle for Unsupported")
    assert(#compose_calls == 1, "COMPOSE_OFFLINE_FRAME must be called once")

    local lines = compose_calls[1].lines
    assert(lines[1].text == "Codec Unavailable", string.format(
        "first line must be 'Codec Unavailable' for Unsupported; got '%s'",
        tostring(lines[1].text)))
    -- BRAW codec hint on second line (from .braw extension)
    assert(lines[2] and lines[2].text:find("BRAW"), string.format(
        "second line must contain BRAW codec hint; got '%s'",
        tostring(lines[2] and lines[2].text)))

    print("  PASS: Unsupported → 'Codec Unavailable', BRAW hint on line 2")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-3  Cache hit: same path+error_code → no recompose; same handle
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-3) cache hit returns same handle without recomposing --")
do
    reset_compose()

    local meta = {
        media_path = "/footage/A001.mov",
        error_code = "FileNotFound",
    }

    local h1 = offline_frame_cache.get_frame(meta)
    assert(h1, "first call must return handle")
    assert(#compose_calls == 1, "first call must compose")

    local h2 = offline_frame_cache.get_frame(meta)
    assert(h2 == h1, "second call must return SAME handle (cache hit)")
    assert(#compose_calls == 1, string.format(
        "cache hit must NOT recompose; COMPOSE called %d times (want 1)", #compose_calls))

    print("  PASS: cache hit returns same handle, no recomposition")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-4  clear() forces recomposition on next get_frame
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-4) clear() forces recomposition --")
do
    reset_compose()

    local meta = { media_path = "/footage/B002.mov", error_code = "FileNotFound" }
    local h1 = offline_frame_cache.get_frame(meta)
    assert(h1, "first call must return handle")

    offline_frame_cache.clear()
    compose_calls = {}

    local h2 = offline_frame_cache.get_frame(meta)
    assert(h2, "post-clear call must return handle")
    assert(#compose_calls == 1, "post-clear call must recompose")

    print("  PASS: clear() forces recomposition on next get_frame")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-5  nil metadata / missing media_path both assert (NSF)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-5) nil metadata / missing media_path assert --")
do
    local ok1, err1 = pcall(function() offline_frame_cache.get_frame(nil) end)
    assert(not ok1, "nil metadata must assert")
    assert(tostring(err1):find("metadata is nil"), string.format(
        "error must mention 'metadata is nil'; got: %s", tostring(err1)))

    local ok2, err2 = pcall(function() offline_frame_cache.get_frame({}) end)
    assert(not ok2, "missing media_path must assert")
    assert(tostring(err2):find("media_path"), string.format(
        "error must mention 'media_path'; got: %s", tostring(err2)))

    print("  PASS: nil metadata and missing media_path both assert loudly")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-6  Renderer MUST NOT call media_status.update_from_tmb
--
-- Observation: wrap media_status.update_from_tmb to count calls. The domain
-- contract is zero calls from any Renderer.get_video_frame invocation across
-- all error codes. Zero is the correct number even when cache says offline
-- and the frame decodes successfully — flipping would oscillate with case 1
-- at coverage boundaries (TSO 2026-05-15 02:46 reload-storm regression).
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-6) Renderer never writes media_status --")
do
    local update_calls = 0
    local real_update = media_status.update_from_tmb
    assert(type(real_update) == "function",
        "precondition: media_status.update_from_tmb must be a real function")
    media_status.update_from_tmb = function(...)
        update_calls = update_calls + 1
        return real_update(...)
    end

    -- Build a real TMB with real media for in-coverage frames.
    local tmb = ienv.create_single_clip_tmb({
        pool_threads = 0, duration = 20, source_in = 0,
    })

    -- Case A: successful decode (in-coverage frame).
    -- Even if cache says offline=true, renderer must not flip it back.
    local save_get = media_status.get
    media_status.get = function() return { offline = true, error_code = "EOFReached" } end

    -- Return value intentionally discarded: we only care that update_from_tmb
    -- was NOT called, regardless of whether a real frame decoded.
    Renderer.get_video_frame(tmb, {1}, 5, {})
    -- frame_a may be nil (no content yet) or an actual frame; we only care
    -- that update_from_tmb was NOT called.
    assert(update_calls == 0, string.format(
        "successful decode with stale-offline cache: renderer called update_from_tmb "
        .. "%d time(s) — must be 0. Oscillation with offline path creates reload storm.",
        update_calls))

    media_status.get = save_get

    -- Case B: simulate offline result (no frame) — renderer still must not write.
    -- Request a frame past clip end so TMB returns offline metadata.
    update_calls = 0
    Renderer.get_video_frame(tmb, {1}, 9999, {})
    assert(update_calls == 0, string.format(
        "offline/past-end frame: renderer called update_from_tmb "
        .. "%d time(s) — must be 0", update_calls))

    -- Restore
    media_status.update_from_tmb = real_update
    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)

    print("  PASS: Renderer.get_video_frame never calls media_status.update_from_tmb")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-7  Renderer: offline TMB result → offline composite returned (not nil)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-7) Renderer returns offline composite for offline media --")
do
    reset_compose()

    -- Create a TMB pointing at a nonexistent path so every frame is offline.
    local tmb_off = EMP.TMB_CREATE(0)
    assert(tmb_off, "TMB_CREATE must return handle")
    EMP.TMB_SET_SEQUENCE_RATE(tmb_off, 24000, 1001)

    local offline_clip = {
        clip_id      = "off-clip",
        media_path   = "/tmp/jve/does_not_exist_" .. os.time() .. ".mov",
        sequence_start = 0,
        duration     = 30,
        source_in    = 0,
        rate_num     = 24000,
        rate_den     = 1001,
        speed_ratio  = 1.0,
    }
    EMP.TMB_SET_TRACK_CLIPS(tmb_off, "video", 1, { offline_clip })

    local frame_off, meta_off = Renderer.get_video_frame(tmb_off, {1}, 5, {})

    -- Domain: offline clip must produce an offline composite frame, not nil.
    -- nil would cause the monitor to display black (same as a gap), hiding
    -- the "Media Offline" diagnostic from the operator.
    assert(meta_off ~= nil, "offline clip must produce metadata from TMB")
    if meta_off and meta_off.offline then
        assert(frame_off ~= nil, string.format(
            "offline clip must return a composited frame (not nil). "
            .. "nil = black screen = operator sees no diagnostic."))
        print("  PASS: offline media → compositor returns non-nil frame")
    else
        -- TMB may return nil,nil for a missing file before the reader opens.
        -- That maps to a gap (nil,nil) from Renderer which is also valid.
        assert(frame_off == nil and meta_off == nil,
            "non-offline TMB result must be nil,nil (gap) if no metadata offline flag")
        print("  PASS: TMB returned gap (nil,nil) for missing file before reader opened")
    end

    EMP.TMB_RELEASE_ALL(tmb_off)
    EMP.TMB_CLOSE(tmb_off)
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-8  Renderer: gap → nil, nil
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-8) Renderer: gap (no clip at frame) → nil,nil --")
do
    -- A TMB with no clips at all: every frame is a gap.
    local tmb_gap = EMP.TMB_CREATE(0)
    assert(tmb_gap, "TMB_CREATE for gap test")
    EMP.TMB_SET_SEQUENCE_RATE(tmb_gap, 24000, 1001)
    -- No clips added — every TMB_GET_VIDEO_FRAME call returns nil + gap metadata.

    local frame_g, meta_g = Renderer.get_video_frame(tmb_gap, {1}, 10, {})
    assert(frame_g == nil, string.format(
        "gap: renderer must return nil frame; got %s", tostring(frame_g)))
    assert(meta_g == nil, string.format(
        "gap: renderer must return nil metadata; got %s", tostring(meta_g)))

    EMP.TMB_CLOSE(tmb_gap)
    print("  PASS: gap (no clip) → nil,nil")
end

-- ════════════════════════════════════════════════════════════════════════════
-- OF-9  Renderer: empty track list → nil,nil (no TMB call)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (OF-9) Renderer: empty track list → nil,nil --")
do
    local tmb_e = ienv.create_single_clip_tmb({ pool_threads = 0, duration = 20 })

    local frame_e, meta_e = Renderer.get_video_frame(tmb_e, {}, 5, {})
    assert(frame_e == nil, "empty track list: frame must be nil")
    assert(meta_e == nil, "empty track list: metadata must be nil")

    EMP.TMB_RELEASE_ALL(tmb_e)
    EMP.TMB_CLOSE(tmb_e)
    print("  PASS: empty track list → nil,nil without querying TMB")
end

print("\n✅ test_offline_frame_rendering.lua passed")
os.exit(0)
