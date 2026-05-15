#!/usr/bin/env luajit
--- media_status_changed cascade after _reset_clip_snapshots
---
--- Domain contract: a single legitimate media_status flip on an active
--- path must trigger EXACTLY ONE RELOAD_ALL_CLIPS. Subsequent flips for
--- UNRELATED paths must be filtered out — they aren't in this engine's
--- clip layout, so reloading for them is wasted work.
---
--- The architectural invariant under test: `_on_media_status_changed_signal`
--- calls `_reset_clip_snapshots()` (which clears `_active_media_paths`)
--- followed by `RELOAD_ALL_CLIPS`. In production, RELOAD_ALL_CLIPS is
--- SYNCHRONOUS — the C++ `PlaybackController::reloadAllClips()`
--- (playback_controller.mm:1312) calls `ClearAllClips()` +
--- `prefetchClips()`, and `prefetchClips()` calls back into Lua's
--- `_provide_clips`, which repopulates `_active_media_paths` (line 601
--- of playback_engine.lua: `self._active_media_paths[entry.media_path] = true`).
---
--- Therefore the cascade window — when the filter set is empty and
--- `_path_is_active_in_tmb` is permissive — must NOT survive past the
--- handler return. By the time control returns to the signal dispatcher
--- and a sibling subscriber's flip is delivered, the set is already
--- repopulated. If a future refactor makes RELOAD_ALL_CLIPS async (e.g.
--- defers _provide_clips via a queued event), this invariant breaks and
--- the bg-probe storm at project open will produce N reloads instead of 1.
---
--- This test mocks RELOAD_ALL_CLIPS as the production synchronous chain:
--- the mock invokes a callback that repopulates _active_media_paths,
--- matching what prefetchClips → _provide_clips does in C++.

require('test_env')

print("=== test_media_status_cascade_after_reset.lua ===")

-- ---------------------------------------------------------------------
-- Mocks. The key fidelity here is that RELOAD_ALL_CLIPS synchronously
-- triggers the equivalent of _provide_clips, which repopulates the
-- engine's _active_media_paths set. A mock that just bumps a counter
-- (the previous mistake) would falsely claim a cascade exists.
-- ---------------------------------------------------------------------

_G.qt_create_single_shot_timer = function() end

local reload_count = 0
local invalidate_calls = {}
local repopulate_fn = nil   -- set after engine constructed; called by RELOAD_ALL_CLIPS mock

_G.qt_constants = {
    EMP = {
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_INVALIDATE_PATH = function(_tmb, path)
            invalidate_calls[#invalidate_calls + 1] = path
        end,
        TMB_CLEAR_OFFLINE = function() end,
    },
    PLAYBACK = {
        RELOAD_ALL_CLIPS = function()
            reload_count = reload_count + 1
            -- Production: ClearAllClips + prefetchClips. prefetchClips
            -- synchronously calls back into Lua _provide_clips, which
            -- repopulates _active_media_paths. Mock that here.
            if repopulate_fn then repopulate_fn() end
        end,
    },
}
package.loaded["core.qt_constants"] = _G.qt_constants

package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

package.loaded["core.media.media_status"] = {
    get = function() return nil end,
    ensure_clip_status = function() end,
}

local PlaybackEngine = require("core.playback.playback_engine")

local engine = PlaybackEngine.new({
    on_show_frame       = function() end,
    on_show_gap         = function() end,
    on_set_rotation     = function() end,
    on_set_par          = function() end,
    on_position_changed = function() end,
})
engine._tmb = "mock_tmb"
engine._playback_controller = "mock_pc"
engine._active_media_paths = { ["/used.mov"] = true }

-- Production-fidelity: RELOAD_ALL_CLIPS triggers prefetchClips →
-- _provide_clips → set repopulation. Here the engine has one clip
-- layout (/used.mov) so the repopulation is single-entry.
repopulate_fn = function()
    engine._active_media_paths["/used.mov"] = true
end

-- ---------------------------------------------------------------------
-- (1) Single legitimate flip on the active path: exactly ONE reload.
-- ---------------------------------------------------------------------
print("\n--- (1) single legitimate flip on active path ---")
reload_count = 0
invalidate_calls = {}
engine:_on_media_status_changed_signal("/used.mov", { offline = false })
assert(reload_count == 1, string.format(
    "active-path flip must trigger exactly one reload, got %d", reload_count))
assert(#invalidate_calls == 1 and invalidate_calls[1] == "/used.mov",
    "invalidate must target the active path exactly")
print("  ✓ active-path flip → 1 reload")

-- ---------------------------------------------------------------------
-- (2) 500 UNRELATED paths flip status (bg-probe completion storm). The
-- filter — repopulated by the synchronous _provide_clips during the
-- prior reload — must reject all of them.
-- ---------------------------------------------------------------------
print("\n--- (2) 500 unrelated paths post-reset ---")
for i = 1, 500 do
    engine:_on_media_status_changed_signal("/unrelated/" .. i .. ".mov",
        { offline = false })
end
assert(reload_count == 1, string.format(
    "500 unrelated path flips after the active-path reload must trigger "
    .. "ZERO additional reloads. Got reload_count=%d (expected 1 from "
    .. "step 1 only).\nIf this assertion fires, the production invariant "
    .. "that RELOAD_ALL_CLIPS synchronously repopulates "
    .. "_active_media_paths is broken — the bg-probe storm at project "
    .. "open will produce N reloads instead of 1.",
    reload_count))
print(string.format("  ✓ 500 unrelated flips: still %d reload(s) total", reload_count))

-- ---------------------------------------------------------------------
-- (3) After the storm, ANOTHER legitimate flip on the active path
-- must still trigger a reload.
-- ---------------------------------------------------------------------
print("\n--- (3) second legitimate flip after the storm ---")
engine:_on_media_status_changed_signal("/used.mov", { offline = true, error_code = "FileNotFound" })
assert(reload_count == 2, string.format(
    "second flip on active path must trigger one more reload, got %d (expected 2 total)",
    reload_count))
print("  ✓ second legitimate flip: reload fired correctly")

-- ---------------------------------------------------------------------
-- (4) Regression guard: if a future refactor breaks the synchronous
-- repopulation (e.g. defers _provide_clips), the filter window stays
-- open and the cascade returns. Simulate that by making the mock NOT
-- repopulate, and confirm the cascade reappears — proving this test
-- discriminates the broken from the working case.
-- ---------------------------------------------------------------------
print("\n--- (4) discrimination check: async-reload simulation ---")
repopulate_fn = function() end  -- async reload: set stays cleared
reload_count = 0
engine._active_media_paths = { ["/used.mov"] = true }
engine:_on_media_status_changed_signal("/used.mov", { offline = false })
-- After the handler returns with no repopulation, the set is empty;
-- _path_is_active_in_tmb returns true on empty, so unrelated flips
-- now cascade. This is the BAD behavior we're guarding against.
for i = 1, 10 do
    engine:_on_media_status_changed_signal("/unrelated/" .. i .. ".mov",
        { offline = false })
end
assert(reload_count == 11, string.format(
    "discrimination check: with async-reload mock, 1+10 unrelated "
    .. "flips should cascade to 11 reloads, got %d. If this fails the "
    .. "test no longer discriminates broken vs working behavior.",
    reload_count))
print("  ✓ async-reload simulation produces cascade (11 reloads) — test discriminates correctly")

print("\n✅ test_media_status_cascade_after_reset.lua passed")
