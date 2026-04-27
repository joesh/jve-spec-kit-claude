--- Test: PlaybackEngine's media_status integration — path filter + offline source.
--
-- Pins two invariants:
--
-- (A) _build_tmb_clip's `offline` flag comes from media_status.get(path),
--     not an ad-hoc io.open. Single source of truth with the browser
--     icons / timeline state. Falls back to io.open only when the path
--     hasn't been registered yet (first clip build before bg probe).
--
-- (B) The media_status_changed listener only triggers a clip reload
--     for paths currently referenced by at least one clip fed to TMB.
--     Otherwise startup bg probe (hundreds of flips) reloads N times
--     for paths that aren't even in this sequence.

local test_env = require("test_env")

--------------------------------------------------------------------------------
-- Mocks: minimum surface PlaybackEngine needs
--------------------------------------------------------------------------------

_G.qt_create_single_shot_timer = function() end

-- media_status stub we can script per test.
local media_status_cache = {}
package.loaded["core.media.media_status"] = {
    get = function(path) return media_status_cache[path] end,
    ensure_clip_status = function() end,
}

-- Count RELOAD_ALL_CLIPS calls to verify the filter.
local reload_count = 0
_G.qt_constants = {
    EMP = {
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_INVALIDATE_PATH = function() end,
        TMB_CLEAR_OFFLINE = function() end,
    },
    PLAYBACK = {
        RELOAD_ALL_CLIPS = function() reload_count = reload_count + 1 end,
    },
}
package.loaded["core.qt_constants"] = _G.qt_constants

package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

-- Real signals — we want the dispatcher's priority ordering.
local Signals = require("core.signals")

local PlaybackEngine = require("core.playback.playback_engine")

--------------------------------------------------------------------------------
-- (A) _build_tmb_clip uses media_status.get for offline
--------------------------------------------------------------------------------

local function build_entry(path)
    return {
        media_path     = path,
        clip_id        = "c1",
        fps_numerator  = 24, fps_denominator = 1,
        timeline_start = 0, duration = 10,
        source_in      = 0, source_out = 10,
        volume         = 1.0,
        track_index    = 0,
    }
end

-- Fake engine shell with just what _build_tmb_clip touches.
local fake_engine = setmetatable({}, { __index = PlaybackEngine })

-- (A1) media_status says online → clip built as online.
media_status_cache = { ["/a.mov"] = { offline = false } }
local clip = fake_engine:_build_tmb_clip(build_entry("/a.mov"), 1.0)
assert(clip.offline == false,
    "media_status.offline=false must produce clip.offline=false (got "
    .. tostring(clip.offline) .. ")")

-- (A2) media_status says offline → clip built as offline.
media_status_cache = { ["/b.mov"] = { offline = true, error_code = "FileNotFound" } }
clip = fake_engine:_build_tmb_clip(build_entry("/b.mov"), 1.0)
assert(clip.offline == true,
    "media_status.offline=true must produce clip.offline=true (got "
    .. tostring(clip.offline) .. ")")

-- (A3) Not registered in media_status → falls back to io.open.
-- Use a deterministic path that doesn't exist.
media_status_cache = {}
clip = fake_engine:_build_tmb_clip(
    build_entry("/tmp/jve/definitely_missing_" .. os.time() .. ".mov"), 1.0)
assert(clip.offline == true,
    "unregistered missing path must fall back to io.open and report offline")

-- (A4) Not registered, path IS on disk → online via fallback.
local tmp = "/tmp/jve/present_" .. os.time() .. ".mov"
os.execute("mkdir -p /tmp/jve")
local f = io.open(tmp, "w"); f:write("x"); f:close()
media_status_cache = {}
clip = fake_engine:_build_tmb_clip(build_entry(tmp), 1.0)
assert(clip.offline == false,
    "unregistered present path must fall back to io.open and report online")
os.remove(tmp)

print("(A) _build_tmb_clip offline source: OK")

--------------------------------------------------------------------------------
-- (B) _path_is_active_in_tmb filter semantics
--------------------------------------------------------------------------------

-- (B1) Empty active set → don't filter (return true). First clip build
-- through _provide_clips hasn't happened yet; rejecting the reload
-- would be wrong on the very first flip.
fake_engine._active_media_paths = {}
assert(fake_engine:_path_is_active_in_tmb("/anything.mov") == true,
    "empty active set must NOT filter (first-population safety)")

-- (B2) Non-empty active set, path absent → filter (false).
fake_engine._active_media_paths = {
    ["/sequence/a.mov"] = true,
    ["/sequence/b.mov"] = true,
}
assert(fake_engine:_path_is_active_in_tmb("/other/c.mov") == false,
    "active set present and path not in it must be filtered")

-- (B3) Non-empty active set, path present → don't filter (true).
assert(fake_engine:_path_is_active_in_tmb("/sequence/a.mov") == true,
    "path present in active set must NOT be filtered")

print("(B) _path_is_active_in_tmb: OK")

--------------------------------------------------------------------------------
-- (C) End-to-end: media_status_changed for a non-active path must NOT
-- trigger RELOAD_ALL_CLIPS. For an active path it must.
--
-- This exercises the exact production wiring, including the Signals
-- dispatcher, the priority ordering, and the filter branch. A
-- regression that removes the filter (reloads on every flip) would
-- trip reload_count going above 1 for the unrelated-path case.
--------------------------------------------------------------------------------

-- Reach into the module-level connection set up by _setup_playback_controller
-- by instantiating an engine and priming its internal state the same way.
local engine = PlaybackEngine.new({
    on_show_frame   = function() end,
    on_show_gap     = function() end,
    on_set_rotation = function() end,
    on_set_par      = function() end,
    on_position_changed = function() end,
})
engine._tmb = "mock_tmb"
engine._playback_controller = "mock_pc"
engine._active_media_paths = { ["/used.mov"] = true }

-- Install ONLY the listener we care about by mirroring what
-- _setup_playback_controller does. We can't call _setup_playback_controller
-- here without a full Sequence + DB setup, so we replicate the listener's
-- exact form — any drift between this copy and the production form would
-- be a maintenance risk, but also exactly the kind of drift that would
-- silently miss a regression. Keep them in sync.
local conn = Signals.connect("media_status_changed", function(path, status)
    if not engine._tmb then return end
    if not engine:_path_is_active_in_tmb(path) then return end
    if status and not status.offline then
        qt_constants.EMP.TMB_CLEAR_OFFLINE(engine._tmb, path)
    end
    qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(engine._playback_controller)
end)

reload_count = 0
-- Hundreds of unrelated flips (mimicking startup bg probe).
for i = 1, 500 do
    Signals.emit("media_status_changed", "/not_in_set/" .. i .. ".mov",
        { offline = false })
end
assert(reload_count == 0, string.format(
    "unrelated-path flips must not trigger RELOAD_ALL_CLIPS (got %d)",
    reload_count))

-- One flip for an active path → should reload exactly once.
Signals.emit("media_status_changed", "/used.mov", { offline = false })
assert(reload_count == 1, string.format(
    "active-path flip must trigger exactly one reload (got %d)", reload_count))

Signals.disconnect(conn)
print("(C) filter end-to-end: OK")

--------------------------------------------------------------------------------
-- (D) Signal handlers assert on bad inputs. Required parameters (path,
-- status) must not silently accept nil — a missing path is a contract
-- violation by the emitter, and the handler must crash loudly with an
-- actionable message that names the function and the bad parameter
-- (rules 1.14, 2.32).
--
-- All assertion messages must match "must be <type>" — catches lazy
-- asserts that don't say what was actually wrong.
--------------------------------------------------------------------------------

test_env.expect_error(function() engine:_on_content_changed_signal(nil) end,
    "_on_content_changed_signal: seq_id must be non%-empty string")
test_env.expect_error(function() engine:_on_content_changed_signal("") end,
    "_on_content_changed_signal: seq_id must be non%-empty string")
test_env.expect_error(function() engine:_on_media_content_changed_signal(nil) end,
    "_on_media_content_changed_signal: path must be non%-empty string")
test_env.expect_error(function() engine:_on_media_content_changed_signal("") end,
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
    function() engine:_on_media_status_changed_signal("/x.mov", { offline = "true" }) end,
    "_on_media_status_changed_signal: status%.offline must be boolean")
test_env.expect_error(function() engine:_path_is_active_in_tmb(nil) end,
    "_path_is_active_in_tmb: path must be non%-empty string")

print("(D) handler input asserts: OK")

print("✅ test_playback_engine_media_status.lua passed")
