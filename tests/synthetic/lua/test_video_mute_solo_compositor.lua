--- test_video_mute_solo_compositor.lua
--
-- Domain behavior: given a set of video tracks with muted/soloed booleans,
-- the compositor must produce the correct effective track index list.
--
-- Rules (FR-019, FR-020):
--   Muted track: skip entirely. Lower non-muted track promotes.
--   Solo (≥1 track soloed): only soloed-AND-not-muted tracks participate.
--   Solo additive set: all soloed tracks compose top-down (no single-winner).
--   Topmost-wins among participants is inherent to the index ordering.
--
-- Expected values derived from NLE domain semantics, NOT from tracing code.
require('test_env')

local renderer = require("core.renderer")

print("=== test_video_mute_solo_compositor.lua ===")

local compute = renderer.compute_effective_video_indices

assert(type(compute) == "function",
    "FAIL: renderer.compute_effective_video_indices must be a function")

-- ── Helper: make a track-state entry ────────────────────────────────────────
local function t(index, muted, soloed)
    return { track_index = index, muted = muted, soloed = soloed }
end

-- ── 1. No tracks — empty result ──────────────────────────────────────────────
print("-- 1. empty tracks --")
do
    local result = compute({})
    assert(#result == 0, "FAIL: empty input must produce empty effective set")
    print("  OK")
end

-- ── 2. All tracks active, none muted, none soloed ────────────────────────────
print("-- 2. all-active no mute no solo --")
do
    -- V3=3 (topmost), V2=2, V1=1 — all participate
    local result = compute({ t(3,false,false), t(2,false,false), t(1,false,false) })
    assert(#result == 3, string.format("FAIL: all-active: expected 3 indices, got %d", #result))
    assert(result[1] == 3, "FAIL: topmost (3) must be first")
    assert(result[2] == 2, "FAIL: V2 must be second")
    assert(result[3] == 1, "FAIL: V1 must be third")
    print("  OK")
end

-- ── 3. Mute topmost track → lower track promotes ─────────────────────────────
print("-- 3. mute topmost (V3) --")
do
    -- FR-019: muted track is skipped; V2 becomes topmost participant
    local result = compute({ t(3,true,false), t(2,false,false), t(1,false,false) })
    assert(#result == 2, string.format("FAIL: mute-top: expected 2 indices, got %d", #result))
    assert(result[1] == 2, "FAIL: after muting V3, V2 must be topmost")
    assert(result[2] == 1, "FAIL: V1 must follow")
    print("  OK")
end

-- ── 4. Solo one track → only that track participates ─────────────────────────
print("-- 4. solo V2 only --")
do
    -- FR-020: soloing V2 excludes V3 and V1
    local result = compute({ t(3,false,false), t(2,false,true), t(1,false,false) })
    assert(#result == 1, string.format("FAIL: solo-one: expected 1 index, got %d", #result))
    assert(result[1] == 2, "FAIL: only V2 is soloed, must be only participant")
    print("  OK")
end

-- ── 5. Solo two tracks → additive set, topmost among soloed wins ─────────────
print("-- 5. solo V2+V3 additive set --")
do
    -- FR-020: both V2 and V3 are soloed → both participate; V1 excluded
    local result = compute({ t(3,false,true), t(2,false,true), t(1,false,false) })
    assert(#result == 2, string.format("FAIL: solo-two: expected 2 indices, got %d", #result))
    assert(result[1] == 3, "FAIL: V3 must be topmost of soloed set")
    assert(result[2] == 2, "FAIL: V2 must follow in soloed set")
    print("  OK")
end

-- ── 6. Solo AND muted on same track → solo wins (matches audio path) ─────────
print("-- 6. soloed + muted same track → solo wins, track participates --")
do
    -- Domain: solo overrides mute in the render path (mirrors audio_playback.lua
    -- which computes vol = track.soloed and track.volume or 0 — ignores muted
    -- when any_solo is active). V2 is soloed AND muted: it participates.
    -- V3 and V1 are not soloed → excluded.
    local result = compute({ t(3,false,false), t(2,true,true), t(1,false,false) })
    assert(#result == 1,
        string.format("FAIL: soloed+muted: expected 1 participant (V2), got %d", #result))
    assert(result[1] == 2,
        "FAIL: soloed+muted: V2 must be the sole participant")
    print("  OK")
end

-- ── 7. All muted → empty result ──────────────────────────────────────────────
print("-- 7. all muted --")
do
    local result = compute({ t(3,true,false), t(2,true,false), t(1,true,false) })
    assert(#result == 0, "FAIL: all-muted must produce empty effective set")
    print("  OK")
end

-- ── 8. Input ordering preserved (highest index must stay first) ───────────────
print("-- 8. input given lowest-first, output still topmost-first --")
do
    -- Caller may provide tracks in any order; result must be descending
    local result = compute({ t(1,false,false), t(2,false,false), t(3,false,false) })
    assert(result[1] == 3 and result[2] == 2 and result[3] == 1,
        "FAIL: output must be sorted descending regardless of input order")
    print("  OK")
end

print("✅ test_video_mute_solo_compositor.lua passed")
