-- Integration: Edit invalidation and partial-coverage cross-engine reload guard.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_playback_edit_invalidation.lua
--   test_partial_coverage_no_cross_engine_reload.lua
--
-- SCENARIOS KEPT:
--   DR-1   content_changed signal for a loaded sequence fires RELOAD_ALL_CLIPS
--            on that engine's PlaybackController (edit → C++ re-queries clips).
--   DR-2   content_changed for a DIFFERENT sequence does NOT reload this engine.
--   DR-3   Forward playthrough across a partial-coverage boundary produces
--            ZERO media_status_changed broadcasts (no cross-engine reload storm).
--   DR-4   100× scrub back-and-forth across the boundary produces ZERO broadcasts.
--
-- SCENARIOS DROPPED:
--   Exact RELOAD_ALL_CLIPS call-count after multiple rapid content_changed
--   signals — depends on debounce timer internals, not domain output.
--   TMB_SET_TRACK_CLIPS call verification — internal clip-feeding detail,
--   not observable user-facing behavior.
--
-- OPEN QUESTIONS:
--   Q1. DR-1/DR-2 use stub engine (not real EMP) because RELOAD_ALL_CLIPS
--       counting requires instrumenting the real C++ binding; confirming
--       that the real binding is invoked via test_playback_gap_clears_and_recovers.
--       If RELOAD_ALL_CLIPS is ever removed from the content_changed handler,
--       that test will also catch it.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_edit_invalidation.lua (integration) ===")

require("test_env")
local Signals = require("core.signals")
local setup   = require("synthetic.helpers.test_017_setup")

-- ── DR-1 / DR-2: content_changed → RELOAD_ALL_CLIPS ─────────────────────────

print("\n-- (DR-1/2) content_changed → RELOAD_ALL_CLIPS routing --")
do
    local reload_calls = {}
    setup.install_qt_stub()
    setup.fresh_project_db("test_edit_invalidation_integ.db")

    -- Instrument RELOAD_ALL_CLIPS on the stub so we can count per-controller.
    local qt = package.loaded["core.qt_constants"]
    qt.PLAYBACK.RELOAD_ALL_CLIPS = function(pc)
        reload_calls[#reload_calls + 1] = pc
    end

    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init("p")

    local rec = transport.engine_for_role("record")
    rec:load("rec")

    -- DR-1: content_changed for the loaded sequence must trigger RELOAD_ALL_CLIPS.
    reload_calls = {}
    Signals.emit("content_changed", "rec")

    assert(#reload_calls >= 1, string.format(
        "content_changed for 'rec' must call RELOAD_ALL_CLIPS; got %d calls",
        #reload_calls))
    print("  PASS DR-1: content_changed for loaded sequence fires RELOAD_ALL_CLIPS")

    -- DR-2: content_changed for a DIFFERENT sequence must NOT reload this engine.
    reload_calls = {}
    Signals.emit("content_changed", "src")   -- src is not loaded in rec engine

    assert(#reload_calls == 0, string.format(
        "content_changed for unrelated 'src' must NOT reload rec engine; got %d calls",
        #reload_calls))
    print("  PASS DR-2: content_changed for unrelated sequence does not reload engine")

    transport.shutdown()
end

-- ── DR-3 / DR-4: partial-coverage no cross-engine reload ────────────────────

print("\n-- (DR-3/4) partial-coverage: zero media_status_changed broadcasts --")
do
    -- Use real media_status module so the "only emit on real change" guard
    -- is exercised. A stub would mask the bug where the renderer emits on
    -- every frame regardless of whether status actually changed.
    local broadcast_count   = 0
    local broadcast_history = {}

    local conn = Signals.connect("media_status_changed", function(path, status)
        broadcast_count = broadcast_count + 1
        broadcast_history[#broadcast_history + 1] = {
            path      = path,
            offline   = status and status.offline,
            error_code = status and status.error_code,
        }
    end)

    -- Minimal stub: TMB returns alternating in-coverage / past-coverage frames.
    -- This simulates playback through a partial-coverage clip at the TMB boundary.
    local tmb_responses = {}
    package.loaded["core.qt_constants"].EMP.TMB_GET_VIDEO_FRAME =
        function(_tmb, track_idx, frame)
            local track = tmb_responses[track_idx]
            local entry = track and track[frame]
            if entry then return entry.frame_handle, entry.metadata end
            return nil, { clip_id = "", offline = false }
        end

    package.loaded["core.qt_constants"].EMP.COMPOSE_OFFLINE_FRAME =
        function() return "offline_handle" end

    -- Real media_status (not stubbed — exercises the "only emit on change" guard).
    require("core.media.media_status")

    package.loaded["core.media.offline_frame_cache"] = {
        get_frame = function() return "offline_overlay" end,
    }

    package.loaded["models.sequence"] = {
        load = function()
            return {
                id = "x",
                frame_rate = { fps_numerator = 24, fps_denominator = 1 },
            }
        end,
    }

    local Renderer = require("core.renderer")

    local PARTIAL_PATH   = "/test/PARTIAL.mov"
    local COVERAGE_END   = 480   -- in-coverage: 0..479; past-coverage: 480+
    local TOTAL          = 500

    -- Pre-populate TMB responses: one video track.
    tmb_responses = { [1] = {} }
    for f = 0, TOTAL - 1 do
        if f < COVERAGE_END then
            tmb_responses[1][f] = {
                frame_handle = "frame_" .. f,
                metadata = {
                    clip_id    = "partial_clip",
                    media_path = PARTIAL_PATH,
                    offline    = false,
                    rotation   = 0, par_num = 1, par_den = 1,
                },
            }
        else
            tmb_responses[1][f] = {
                frame_handle = nil,
                metadata = {
                    clip_id    = "partial_clip",
                    media_path = PARTIAL_PATH,
                    offline    = true,
                    error_code = "EOFReached",
                },
            }
        end
    end

    local mock_tmb = "mock_tmb"

    -- DR-3: forward playthrough through the entire clip — boundary crossed once.
    broadcast_count   = 0
    broadcast_history = {}
    for f = 0, TOTAL - 1 do
        Renderer.get_video_frame(mock_tmb, {1}, f, {})
    end
    assert(broadcast_count == 0, string.format(
        "Forward playthrough (%d frames, boundary at %d): "
        .. "got %d media_status_changed broadcast(s). "
        .. "Contract: ZERO. Each broadcast triggers RELOAD_ALL_CLIPS on "
        .. "every engine that holds this path — and blanks the unrelated "
        .. "record monitor's TMB clip layout (TSO 2026-05-15 regression).",
        TOTAL, COVERAGE_END, broadcast_count))
    print(string.format("  PASS DR-3: %d-frame forward playthrough: 0 broadcasts",
        TOTAL))

    -- DR-4: 100× scrub back-and-forth across the boundary.
    broadcast_count   = 0
    broadcast_history = {}
    for _ = 1, 100 do
        Renderer.get_video_frame(mock_tmb, {1}, COVERAGE_END - 1, {})  -- in-cov
        Renderer.get_video_frame(mock_tmb, {1}, COVERAGE_END,     {})  -- past-cov
    end
    assert(broadcast_count == 0, string.format(
        "100× boundary scrub: got %d media_status_changed broadcast(s). "
        .. "Contract: ZERO.",
        broadcast_count))
    print("  PASS DR-4: 100× boundary scrub: 0 broadcasts")

    Signals.disconnect(conn)

    -- Restore standard models.sequence stub so other tests aren't affected.
    package.loaded["models.sequence"] = nil
end

print("\nPASS test_edit_invalidation.lua")
os.exit(0)
