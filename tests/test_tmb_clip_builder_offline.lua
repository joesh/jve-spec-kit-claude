--- Pure black-box tests for tmb_clip_builder.build_clip's offline source.
---
--- Pins the contract that ClipInfo.offline is sourced from media_status
--- (single source of truth shared with browser icons + timeline label),
--- with a one-shot io.open fallback only when the path has never been
--- registered (first clip build during sequence load, before bg probe).
---
--- This replaces section (A) of the prior mock-based
--- test_playback_engine_media_status.lua. Both modules are pure Lua:
--- tmb_clip_builder.build_clip and media_status only need a real Signals
--- module — no Qt, no qt_constants mock.

require("test_env")

local tmb_clip_builder = require("core.playback.tmb_clip_builder")
local media_status     = require("core.media.media_status")

print("=== test_tmb_clip_builder_offline.lua ===")

local function entry_for(path)
    return {
        media_path     = path,
        clip_id        = "c1",
        media_kind     = "video",
        fps_numerator  = 24, fps_denominator = 1,
        sequence_start = 0, duration = 10,
        source_in      = 0, source_out = 10,
        volume         = 1.0,
        track_index    = 0,
    }
end

-- ── (1) media_status says online → clip built as online ───────────────
print("-- (1) cached online → clip.offline=false --")
do
    media_status.clear()
    -- _set_cache: stamp cache without triggering a probe. This is the
    -- "bg probe just delivered" state.
    media_status._set_cache("/a.mov", { offline = false })

    local clip = tmb_clip_builder.build_clip(entry_for("/a.mov"), 1.0)
    assert(clip.offline == false, string.format(
        "cached offline=false must produce clip.offline=false; got %s",
        tostring(clip.offline)))
    print("  PASS")
end

-- ── (2) media_status says offline → clip built as offline ─────────────
print("-- (2) cached offline → clip.offline=true --")
do
    media_status.clear()
    media_status._set_cache("/b.mov",
        { offline = true, error_code = "FileNotFound" })

    local clip = tmb_clip_builder.build_clip(entry_for("/b.mov"), 1.0)
    assert(clip.offline == true, string.format(
        "cached offline=true must produce clip.offline=true; got %s",
        tostring(clip.offline)))
    print("  PASS")
end

-- ── (3) Unregistered + missing on disk → fallback says offline ────────
-- Tests the io.open fallback when bg probe hasn't populated the cache yet.
print("-- (3) unregistered + missing → fallback marks offline --")
do
    media_status.clear()
    local missing = "/tmp/jve/tmb_clip_builder_missing_"
        .. os.time() .. "_" .. math.random(1e6) .. ".mov"
    -- Belt + suspenders — ensure it really doesn't exist.
    os.remove(missing)

    local clip = tmb_clip_builder.build_clip(entry_for(missing), 1.0)
    assert(clip.offline == true,
        "unregistered missing path must fall back to io.open → offline")
    print("  PASS")
end

-- ── (4) Unregistered + present on disk → fallback says online ─────────
print("-- (4) unregistered + present → fallback marks online --")
do
    media_status.clear()
    os.execute("mkdir -p /tmp/jve")
    local present = "/tmp/jve/tmb_clip_builder_present_"
        .. os.time() .. "_" .. math.random(1e6) .. ".mov"
    local f = io.open(present, "w"); f:write("x"); f:close()

    local clip = tmb_clip_builder.build_clip(entry_for(present), 1.0)
    assert(clip.offline == false,
        "unregistered present path must fall back to io.open → online")
    os.remove(present)
    print("  PASS")
end

-- ── (5) Cache takes precedence over disk reality ──────────────────────
-- If a file exists on disk but media_status says offline (e.g. codec
-- error discovered by a previous probe), build_clip must trust the
-- cache — disagreement between ClipInfo.offline and the browser/label
-- was the original bug that drove the single-source-of-truth rule.
print("-- (5) cache wins over disk reality --")
do
    media_status.clear()
    os.execute("mkdir -p /tmp/jve")
    local present_but_cached_offline = "/tmp/jve/cache_wins_"
        .. os.time() .. "_" .. math.random(1e6) .. ".mov"
    local f = io.open(present_but_cached_offline, "w"); f:write("x"); f:close()

    media_status._set_cache(present_but_cached_offline,
        { offline = true, error_code = "Unsupported" })

    local clip = tmb_clip_builder.build_clip(
        entry_for(present_but_cached_offline), 1.0)
    assert(clip.offline == true,
        "cached offline=true must win over file-exists fallback")
    os.remove(present_but_cached_offline)
    print("  PASS")
end

print("\nPASS test_tmb_clip_builder_offline.lua")
