#!/usr/bin/env luajit
--- Partial-coverage playback on one monitor must not invalidate another's TMB
---
--- Domain contract: each SequenceMonitor owns a PlaybackEngine. Two
--- engines coexist (source + record monitors). Playing back through a
--- partial-coverage clip on the SOURCE engine must NOT cause the RECORD
--- engine's TMB clip layout to be cleared and reloaded — that's the
--- mechanism that produces the user-visible "record monitor shows black
--- on clips that have video" regression (TSO 2026-05-15 02:46).
---
--- Why this matters: media_status_changed is a broadcast signal. EVERY
--- PlaybackEngine subscribes. Its handler unconditionally clears
--- TMB clip caches and calls RELOAD_ALL_CLIPS when the path is
--- "active in TMB". Reloading is async — there's a window between the
--- clear and the next clip_provider call when deliverFrame sees an
--- empty TMB layout → "no clip on N tracks" → surface.clearFrame() →
--- black, no overlay. With partial-coverage playback the renderer
--- previously oscillated the file's media_status as the playhead
--- crossed coverage boundaries; each oscillation broadcast → every
--- engine reloaded → the record monitor never stayed populated.
---
--- The contract: simulating partial-coverage source-side activity
--- (offline=true on past-coverage frames, frames decoding on in-coverage
--- frames) must produce ZERO `media_status_changed` emissions and
--- therefore ZERO RELOAD_ALL_CLIPS on the unrelated record engine.

require('test_env')

print("=== test_partial_coverage_no_cross_engine_reload.lua ===")

-- ---------------------------------------------------------------------
-- Mocks: just enough to run Renderer.get_video_frame through the path
-- that previously fired update_from_tmb. We don't need real engines
-- here — the contract under test is "the renderer-via-TMB edge MUST
-- NOT broadcast" which is sufficient to prevent cross-engine reload.
-- A more end-to-end variant would wire two real engines and a real
-- PLAYBACK.RELOAD_ALL_CLIPS counter; that's covered separately.
-- ---------------------------------------------------------------------

local Signals = require("core.signals")

-- Count every media_status_changed emission. Zero is the contract.
local broadcast_count = 0
local broadcast_history = {}
local conn = Signals.connect("media_status_changed", function(path, status)
    broadcast_count = broadcast_count + 1
    broadcast_history[#broadcast_history + 1] = {
        path = path,
        offline = status and status.offline,
        error_code = status and status.error_code,
    }
end)

-- TMB stub: returns alternating in-coverage / past-coverage frames for
-- the same clip. This is what playback through a partial-coverage clip
-- looks like at the TMB boundary: the decode_path / cache_only path
-- reports offline=true EOFReached for frames past media end, real
-- frames for frames inside coverage.
local tmb_responses = {}
package.loaded["core.qt_constants"] = {
    EMP = {
        TMB_GET_VIDEO_FRAME = function(_tmb, track_idx, frame)
            local track = tmb_responses[track_idx]
            local entry = track and track[frame]
            if entry then return entry.frame_handle, entry.metadata end
            return nil, { clip_id = "", offline = false }
        end,
        COMPOSE_OFFLINE_FRAME = function() return "offline_handle" end,
    },
}

-- Real media_status. We want to exercise the actual `update_from_tmb`
-- behavior (its "only emit on real change" guard is important). A stub
-- here would let us miss the case where the renderer fires the signal
-- on EVERY frame even when value doesn't change — that's the same
-- failure mode but cheaper to detect.
local media_status = require("core.media.media_status")

package.loaded["core.media.offline_frame_cache"] = {
    get_frame = function() return "offline_overlay" end,
}

-- Renderer.get_sequence_info dependency (we never call it but the
-- module-level require chain pulls Sequence).
package.loaded["models.sequence"] = {
    load = function() return { id = "x", frame_rate = { fps_numerator = 24, fps_denominator = 1 } } end,
}

local Renderer = require("core.renderer")
local mock_tmb = "mock_tmb"

local PARTIAL_PATH = "/Users/joe/footage/PARTIAL.mov"
local COVERAGE_END = 480  -- in-coverage: frames 0..479. past-coverage: 480+.
local TOTAL = 500          -- clip duration

-- Pre-populate TMB responses for the full clip range. Track 1 only.
tmb_responses = { [1] = {} }
for f = 0, TOTAL - 1 do
    if f < COVERAGE_END then
        tmb_responses[1][f] = {
            frame_handle = "frame_" .. f,
            metadata = {
                clip_id = "partial_clip",
                media_path = PARTIAL_PATH,
                offline = false,
                rotation = 0, par_num = 1, par_den = 1,
            },
        }
    else
        tmb_responses[1][f] = {
            frame_handle = nil,
            metadata = {
                clip_id = "partial_clip",
                media_path = PARTIAL_PATH,
                offline = true,
                error_code = "EOFReached",
            },
        }
    end
end

-- ---------------------------------------------------------------------
-- Scenario A: play forward through the entire clip — boundary crossed
-- once. Renderer must not broadcast media_status_changed.
-- ---------------------------------------------------------------------
print("\n--- Scenario A: forward playthrough across coverage boundary ---")
broadcast_count = 0
broadcast_history = {}
for f = 0, TOTAL - 1 do
    Renderer.get_video_frame(mock_tmb, {1}, f, {})
end
assert(broadcast_count == 0, string.format(
    "Forward playthrough through %d frames (boundary at %d) produced "
    .. "%d media_status_changed emission(s). Contract: ZERO. Each "
    .. "emission triggers RELOAD_ALL_CLIPS on every engine that "
    .. "references this path — and clears the unrelated record "
    .. "monitor's TMB clip layout (TSO 2026-05-15: 'no clip on 2 "
    .. "tracks' across dozens of consecutive deliverFrame calls).",
    TOTAL, COVERAGE_END, broadcast_count))
print(string.format("  ✓ %d-frame playthrough: 0 broadcasts", TOTAL))

-- ---------------------------------------------------------------------
-- Scenario B: scrub back-and-forth across the boundary 100 times.
-- Even tighter oscillation — this is what trackpad scrubbing across
-- the boundary looks like at the renderer layer.
-- ---------------------------------------------------------------------
print("\n--- Scenario B: 100x scrub back-and-forth across boundary ---")
broadcast_count = 0
broadcast_history = {}
for _ = 1, 100 do
    Renderer.get_video_frame(mock_tmb, {1}, COVERAGE_END - 1, {})  -- in-cov
    Renderer.get_video_frame(mock_tmb, {1}, COVERAGE_END, {})      -- past-cov
end
assert(broadcast_count == 0, string.format(
    "100x scrubbing across the boundary produced %d emissions. "
    .. "Contract: ZERO. This was %d reload storms in the live "
    .. "TSO (one per emission, per engine).",
    broadcast_count, broadcast_count * 2))
print(string.format("  ✓ 100x boundary scrub: 0 broadcasts"))

Signals.disconnect(conn)
print("\n✅ test_partial_coverage_no_cross_engine_reload.lua passed")
