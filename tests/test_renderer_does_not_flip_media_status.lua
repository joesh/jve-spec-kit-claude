#!/usr/bin/env luajit
--- Renderer view-layer ≠ media_status writer
---
--- Domain contract: the renderer is a hot-path view consumer of TMB
--- frame results. media_status is a model-layer cache of file-level
--- health (file exists, codec works), maintained by:
---   - bg codec probe at project open
---   - FS watcher on file/dir changes
---   - relinker when offline_note is written
---
--- Per-frame TMB results are NOT file-level signals. In particular:
---   - EOFReached: clip references frames past media end. The file
---     is fine; the clip is over-extended. Per-frame, not file-level.
---   - DecodeFailed / SeekFailed: codec glitch on this frame. Transient.
---   - FileNotFound: file disappeared between probe and decode (rare;
---     FS watcher catches it shortly after — renderer's write would
---     be a redundant fast path with bad side effects).
---   - Unsupported: discovered at reader-open time via TMB's m_offline
---     registry. bg probe also catches it at project open. Renderer's
---     write is redundant.
---
--- Why this is a contract worth pinning: renderer flipping media_status
--- emits `media_status_changed`, which broadcasts to every consumer.
--- Subscribers include EACH PlaybackEngine instance — its
--- `_on_media_status_changed_signal` invalidates TMB and calls
--- RELOAD_ALL_CLIPS. With partial-coverage playback, the playhead
--- crossing the coverage boundary flips status repeatedly → reload
--- storm → other monitors' TMB clip layouts get cleared → those
--- monitors render gap-black (no clip at this frame log). The user-
--- visible symptom of the storm is "lots of black-only media" on the
--- record monitor while the source viewer is showing the offline overlay
--- on the same partial-coverage file (TSO 2026-05-15 02:46).
---
--- Contract: Renderer.get_video_frame MUST NOT call
--- media_status.update_from_tmb. Period. The signal is not the
--- renderer's to fire. Any required state change happens through the
--- authoritative writers (bg probe, FS watcher, relinker).

require('test_env')

print("=== test_renderer_does_not_flip_media_status.lua ===")

-- ---------------------------------------------------------------------
-- Mocks: minimum surface Renderer needs. Each test resets call counts
-- so we can prove the contract on every scenario independently.
-- ---------------------------------------------------------------------

local tmb_responses = {}  -- {[track_idx] = {[frame] = {frame, metadata}}}

package.loaded["core.qt_constants"] = {
    EMP = {
        TMB_GET_VIDEO_FRAME = function(_tmb, track_idx, frame)
            local track = tmb_responses[track_idx]
            local entry = track and track[frame]
            if entry then return entry.frame_handle, entry.metadata end
            return nil, { clip_id = "", offline = false }
        end,
        COMPOSE_OFFLINE_FRAME = function() return "offline_composite" end,
    },
}

-- Record every media_status writer call. The contract is: zero calls
-- from any Renderer.get_video_frame invocation across all error codes.
local update_calls = {}
package.loaded["core.media.media_status"] = {
    update_from_tmb = function(path, offline, error_code)
        update_calls[#update_calls + 1] = {
            path = path, offline = offline, error_code = error_code,
        }
    end,
    get = function() return nil end,
    get_offline_note = function() return nil end,
}

-- offline_frame_cache stub: just return a sentinel so the assert in
-- Renderer doesn't fire. The test isn't about overlay composition.
package.loaded["core.media.offline_frame_cache"] = {
    get_frame = function() return "offline_overlay_handle" end,
}

-- Sequence stub (Renderer.get_sequence_info uses it; here we only need
-- get_video_frame, so a minimal stub).
package.loaded["models.sequence"] = {
    load = function(seq_id)
        return {
            id = seq_id,
            frame_rate = { fps_numerator = 24, fps_denominator = 1 },
            width = 1920, height = 1080, name = "Test", kind = "sequence",
            audio_sample_rate = 48000,
        }
    end,
}

local Renderer = require("core.renderer")
local mock_tmb = "mock_tmb_handle"

local function reset()
    update_calls = {}
    tmb_responses = {}
end

-- ---------------------------------------------------------------------
-- Case 1: Partial-coverage clip — EOFReached on a past-coverage frame.
-- The renderer must compose the offline overlay AND NOT write to
-- media_status. EOFReached is per-frame, not file-level.
-- ---------------------------------------------------------------------
print("\n--- Case 1: EOFReached past-coverage frame ---")
reset()
tmb_responses = {
    [1] = {
        [500] = {
            frame_handle = nil,
            metadata = {
                clip_id = "partial_clip",
                media_path = "/Users/joe/footage/A005.mov",
                offline = true,
                error_code = "EOFReached",
            },
        },
    },
}
local frame, meta = Renderer.get_video_frame(mock_tmb, {1}, 500, {})
assert(frame == "offline_overlay_handle",
    "EOFReached frame must compose offline overlay (got " .. tostring(frame) .. ")")
assert(meta.offline == true,
    "EOFReached metadata.offline preserved")
assert(#update_calls == 0, string.format(
    "EOFReached MUST NOT trigger media_status.update_from_tmb — that flip "
    .. "broadcasts media_status_changed → every engine reloads → partial-"
    .. "coverage playback creates a reload storm. Got %d call(s).",
    #update_calls))
print("  ✓ EOFReached past-coverage frame: zero media_status writes")

-- ---------------------------------------------------------------------
-- Case 2: Within-coverage frame DECODES successfully.
-- Even if media_status currently thinks the path is offline, the
-- renderer must NOT clear it — that's a feedback edge that oscillates
-- with case 1 as the playhead crosses the coverage boundary.
-- Set up media_status.get to report offline=true so the dead "clear
-- stale offline" branch (if any) is exercised.
-- ---------------------------------------------------------------------
print("\n--- Case 2: Successful decode while cache says offline ---")
reset()
package.loaded["core.media.media_status"].get = function()
    return { offline = true, error_code = "EOFReached" }
end
tmb_responses = {
    [1] = {
        [100] = {
            frame_handle = "real_frame_pixels",
            metadata = {
                clip_id = "partial_clip",
                media_path = "/Users/joe/footage/A005.mov",
                offline = false,
                rotation = 0, par_num = 1, par_den = 1,
            },
        },
    },
}
local f2, m2 = Renderer.get_video_frame(mock_tmb, {1}, 100, {})
assert(f2 == "real_frame_pixels", "in-coverage frame must return the real frame")
assert(m2.offline == false, "in-coverage metadata.offline preserved")
assert(#update_calls == 0, string.format(
    "Successful decode MUST NOT call media_status.update_from_tmb to clear "
    .. "stale state — for partial-coverage clips this oscillates with the "
    .. "EOFReached write on adjacent frames. Got %d call(s).",
    #update_calls))
print("  ✓ Successful decode (cache=offline): zero media_status writes")
-- Restore default mock for subsequent cases.
package.loaded["core.media.media_status"].get = function() return nil end

-- ---------------------------------------------------------------------
-- Case 3: FileNotFound. Renderer still doesn't flip media_status —
-- the bg probe / FS watcher are the authoritative writers for file
-- existence. (If the file was missing at project open, bg probe set
-- the status already. If the file disappeared during the session,
-- FS watcher reprobes via dir-change. Renderer's write would be a
-- redundant fast path that creates feedback edges.)
-- ---------------------------------------------------------------------
print("\n--- Case 3: FileNotFound — still no renderer write ---")
reset()
tmb_responses = {
    [1] = {
        [200] = {
            frame_handle = nil,
            metadata = {
                clip_id = "missing_clip",
                media_path = "/Users/joe/footage/gone.mov",
                offline = true,
                error_code = "FileNotFound",
            },
        },
    },
}
Renderer.get_video_frame(mock_tmb, {1}, 200, {})
assert(#update_calls == 0, string.format(
    "FileNotFound on the render path MUST NOT call update_from_tmb. "
    .. "bg probe + FS watcher are authoritative. Got %d call(s).",
    #update_calls))
print("  ✓ FileNotFound: zero media_status writes (bg probe / FS watcher own this)")

-- ---------------------------------------------------------------------
-- Case 4: Unsupported codec. Same contract.
-- ---------------------------------------------------------------------
print("\n--- Case 4: Unsupported codec — still no renderer write ---")
reset()
tmb_responses = {
    [1] = {
        [300] = {
            frame_handle = nil,
            metadata = {
                clip_id = "weird_codec_clip",
                media_path = "/Users/joe/footage/x.braw",
                offline = true,
                error_code = "Unsupported",
            },
        },
    },
}
Renderer.get_video_frame(mock_tmb, {1}, 300, {})
assert(#update_calls == 0, string.format(
    "Unsupported codec on the render path MUST NOT call update_from_tmb. "
    .. "bg probe owns codec status. Got %d call(s).",
    #update_calls))
print("  ✓ Unsupported: zero media_status writes")

-- ---------------------------------------------------------------------
-- Case 5: Scrubbing across coverage boundary — domain-level test of
-- the actual symptom. Walk through 10 frames alternating in/out of
-- coverage and assert zero signal emissions across the whole walk.
-- ---------------------------------------------------------------------
print("\n--- Case 5: Scrubbing across coverage boundary (10 frames) ---")
reset()
local in_cov_meta = {
    clip_id = "boundary_clip",
    media_path = "/Users/joe/footage/B003.mov",
    offline = false, rotation = 0, par_num = 1, par_den = 1,
}
local out_cov_meta = {
    clip_id = "boundary_clip",
    media_path = "/Users/joe/footage/B003.mov",
    offline = true,
    error_code = "EOFReached",
}
tmb_responses = { [1] = {} }
for i = 100, 109 do
    if i % 2 == 0 then
        tmb_responses[1][i] = { frame_handle = "in_cov_" .. i, metadata = in_cov_meta }
    else
        tmb_responses[1][i] = { frame_handle = nil, metadata = out_cov_meta }
    end
end
for i = 100, 109 do
    Renderer.get_video_frame(mock_tmb, {1}, i, {})
end
assert(#update_calls == 0, string.format(
    "10 frames scrubbing across coverage boundary produced %d "
    .. "media_status.update_from_tmb call(s). The contract is ZERO. "
    .. "Any nonzero count is a signal-storm vector — every flip "
    .. "broadcasts to every engine which calls RELOAD_ALL_CLIPS, "
    .. "and across two monitors that is the user-visible black-frames "
    .. "regression (TSO 2026-05-15 02:46).",
    #update_calls))
print("  ✓ 10-frame scrub across coverage boundary: zero writes")

print("\n✅ test_renderer_does_not_flip_media_status.lua passed")
