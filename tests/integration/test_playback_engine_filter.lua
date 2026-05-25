-- Integration: PlaybackEngine's media_status filter + handler input
-- assertions on a real engine instance.
--
-- Replaces sections (B) and (D) of the prior mock-based
-- test_playback_engine_media_status.lua. Section (A) — offline source
-- in ClipInfo — moved to the pure test_tmb_clip_builder_offline.lua.
-- Section (C) — end-to-end signal filter wiring — would need a real TMB
-- + PlaybackController to verify RELOAD_ALL_CLIPS calls; the same wiring
-- is exercised by test_media_status_cascade_after_reset (also via a
-- mock; the real-TMB conversion is tracked separately).
--
-- What stays observable from Lua:
--   * _path_is_active_in_tmb's filter semantics on a real PlaybackEngine
--   * Handler-method input assertions (these fire before any TMB call,
--     so no real TMB is needed)

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_playback_engine_filter.lua ===")

require("test_env")
local PlaybackEngine = require("core.playback.playback_engine")
local test_env       = require("test_env")

-- Real engine, no fake_engine setmetatable trick.
local engine = PlaybackEngine.new("source", {
    on_show_frame       = function() end,
    on_show_gap         = function() end,
    on_set_rotation     = function() end,
    on_set_par          = function() end,
    on_position_changed = function() end,
})

-- ── (1) Empty active set must NOT filter ─────────────────────────────
-- First clip build through _provide_clips hasn't happened yet; rejecting
-- the reload would be wrong on the very first flip when the set hasn't
-- been populated. Empty == "we don't know yet" == permissive.
print("-- (1) empty active set is permissive --")
engine._active_media_paths = {}
assert(engine:_path_is_active_in_tmb("/anything.mov") == true,
    "empty active set must NOT filter (first-population safety)")
print("  PASS")

-- ── (2) Non-empty set, path absent → filter ──────────────────────────
print("-- (2) non-empty set, path absent → filter --")
engine._active_media_paths = {
    ["/sequence/a.mov"] = true,
    ["/sequence/b.mov"] = true,
}
assert(engine:_path_is_active_in_tmb("/other/c.mov") == false,
    "path not in active set must be filtered")
print("  PASS")

-- ── (3) Non-empty set, path present → admit ──────────────────────────
print("-- (3) non-empty set, path present → admit --")
assert(engine:_path_is_active_in_tmb("/sequence/a.mov") == true,
    "path in active set must NOT be filtered")
print("  PASS")

-- ── (4) Handler input assertions ─────────────────────────────────────
-- The signal handlers fire from the global Signals dispatcher; bad
-- payloads from the emitter must crash loudly with a message naming the
-- function + bad parameter (rules 1.14, 2.32). All assertion messages
-- must match the "must be <type>" shape so we catch lazy asserts.
--
-- These assertions fire BEFORE the handler touches TMB or
-- PlaybackController, so no real TMB is required to exercise them.
print("-- (4) handler input assertions --")

test_env.expect_error(
    function() engine:_on_content_changed_signal(nil) end,
    "_on_content_changed_signal: seq_id must be non%-empty string")
test_env.expect_error(
    function() engine:_on_content_changed_signal("") end,
    "_on_content_changed_signal: seq_id must be non%-empty string")
test_env.expect_error(
    function() engine:_on_media_content_changed_signal(nil) end,
    "_on_media_content_changed_signal: path must be non%-empty string")
test_env.expect_error(
    function() engine:_on_media_content_changed_signal("") end,
    "_on_media_content_changed_signal: path must be non%-empty string")
test_env.expect_error(
    function() engine:_on_media_status_changed_signal(nil, { offline = false }) end,
    "_on_media_status_changed_signal: path must be non%-empty string")
test_env.expect_error(
    function() engine:_on_media_status_changed_signal("/x.mov", nil) end,
    "_on_media_status_changed_signal: status must be table")
test_env.expect_error(
    function() engine:_on_media_status_changed_signal("/x.mov", {}) end,
    "_on_media_status_changed_signal: status%.offline must be boolean")
test_env.expect_error(
    function() engine:_on_media_status_changed_signal("/x.mov",
        { offline = "true" }) end,
    "_on_media_status_changed_signal: status%.offline must be boolean")
test_env.expect_error(
    function() engine:_path_is_active_in_tmb(nil) end,
    "_path_is_active_in_tmb: path must be non%-empty string")
print("  PASS")

print("\nPASS test_playback_engine_filter.lua")
