--- Black-box tests for the probe-cache classification logic.
-- The pure helper decides for each input path whether to serve a hit
-- (cache entry matches current stat), a miss (stale or absent entry),
-- or a missing-file miss (no stat at all — file was deleted). The
-- function is pure — no disk, no EMP — so we drive it directly with
-- synthetic entries + stats tables and assert the shape of the
-- classification result.

require("test_env")

local cache = require("core.media_probe_cache")

local failed = 0
local function check(label, cond)
    if cond then
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- Dummy info payload. Must include the three presence flags the
-- classifier requires (has_duration, has_video_tc_origin,
-- has_audio_tc_origin) — they're what makes an entry "fresh-shape"
-- versus "pre-c2b2b505 legacy shape that should be re-probed".
-- We only care about object identity for "did the hit return the
-- right cached object?", so tag field is the distinguisher.
local INFO_A = {
    tag = "info_a",
    has_duration = true,
    has_video_tc_origin = true,
    has_audio_tc_origin = false,
}
local INFO_B = {
    tag = "info_b",
    has_duration = true,
    has_video_tc_origin = false,
    has_audio_tc_origin = true,
}

-- ---------------------------------------------------------------------------
-- All hits: every path has a cache entry with matching mtime+size.
-- ---------------------------------------------------------------------------
print("\n--- all hits ---")
do
    local paths = { "/a", "/b" }
    local entries = {
        ["/a"] = { mtime = 100, size = 1000, info = INFO_A },
        ["/b"] = { mtime = 200, size = 2000, info = INFO_B },
    }
    local stats = {
        ["/a"] = { mtime = 100, size = 1000 },
        ["/b"] = { mtime = 200, size = 2000 },
    }
    local c = cache._classify_paths(paths, entries, stats)
    check("hit_count reflects both hits", c.hit_count == 2)
    check("no misses reported", #c.miss_paths == 0)
    check("no missing files reported", c.missing_count == 0)
    check("results[1] returns cached INFO_A", c.results[1] == INFO_A)
    check("results[2] returns cached INFO_B", c.results[2] == INFO_B)
end

-- ---------------------------------------------------------------------------
-- All misses: paths exist on disk but cache has no entry for them.
-- ---------------------------------------------------------------------------
print("\n--- all misses (fresh cache) ---")
do
    local paths = { "/new1", "/new2" }
    local entries = {}  -- empty cache
    local stats = {
        ["/new1"] = { mtime = 10, size = 100 },
        ["/new2"] = { mtime = 20, size = 200 },
    }
    local c = cache._classify_paths(paths, entries, stats)
    check("no hits", c.hit_count == 0)
    check("both paths classified as misses", #c.miss_paths == 2)
    check("no missing-file count", c.missing_count == 0)
    check("miss indices map to input positions",
        c.miss_indices[1] == 1 and c.miss_indices[2] == 2)
    check("miss paths preserve input order",
        c.miss_paths[1] == "/new1" and c.miss_paths[2] == "/new2")
end

-- ---------------------------------------------------------------------------
-- Stale entries: cached mtime or size doesn't match current stat.
-- ---------------------------------------------------------------------------
print("\n--- stale entries (file changed since cached) ---")
do
    local paths = { "/stale_mtime", "/stale_size" }
    local entries = {
        ["/stale_mtime"] = { mtime = 100, size = 500, info = INFO_A },
        ["/stale_size"]  = { mtime = 200, size = 500, info = INFO_B },
    }
    local stats = {
        ["/stale_mtime"] = { mtime = 101, size = 500 },  -- mtime +1
        ["/stale_size"]  = { mtime = 200, size = 501 },  -- size +1
    }
    local c = cache._classify_paths(paths, entries, stats)
    check("stale mtime → miss", c.hit_count == 0 and #c.miss_paths == 2)
    check("neither stale entry appears in results",
        c.results[1] == nil and c.results[2] == nil)
end

-- ---------------------------------------------------------------------------
-- Missing files: file exists in cache but stat returns no entry (file
-- was deleted/renamed). Classified as miss AND counted separately so
-- the caller can log missing-file totals.
-- ---------------------------------------------------------------------------
print("\n--- missing files (no stat) ---")
do
    local paths = { "/gone" }
    local entries = {
        ["/gone"] = { mtime = 1, size = 1, info = INFO_A },
    }
    local stats = {}  -- no stat entries
    local c = cache._classify_paths(paths, entries, stats)
    check("missing-file is a miss", #c.miss_paths == 1)
    check("missing-file is counted separately", c.missing_count == 1)
    check("missing-file's cached info is not served",
        c.results[1] == nil)
end

-- ---------------------------------------------------------------------------
-- Mixed: hit + stale + fresh-miss + missing-file in one call.
-- Confirms misses are contiguously indexed and results preserve positions.
-- ---------------------------------------------------------------------------
print("\n--- mixed (hit, stale, fresh, missing) ---")
do
    local paths = { "/hit", "/stale", "/fresh", "/gone" }
    local entries = {
        ["/hit"]   = { mtime = 1, size = 10, info = INFO_A },
        ["/stale"] = { mtime = 2, size = 20, info = INFO_B },
        -- "/fresh" absent — never cached
        ["/gone"]  = { mtime = 3, size = 30, info = INFO_A },
    }
    local stats = {
        ["/hit"]   = { mtime = 1, size = 10 },      -- matches
        ["/stale"] = { mtime = 9, size = 20 },      -- mtime differs
        ["/fresh"] = { mtime = 4, size = 40 },      -- not cached
        -- "/gone" absent from stats → missing file
    }
    local c = cache._classify_paths(paths, entries, stats)
    check("one hit total", c.hit_count == 1)
    check("three misses total (stale + fresh + gone)", #c.miss_paths == 3)
    check("exactly one missing-file", c.missing_count == 1)
    check("hit sits at input position 1", c.results[1] == INFO_A)
    check("miss indices are the non-hit positions (2, 3, 4)",
        c.miss_indices[1] == 2
        and c.miss_indices[2] == 3
        and c.miss_indices[3] == 4)
    check("miss paths preserve input order",
        c.miss_paths[1] == "/stale"
        and c.miss_paths[2] == "/fresh"
        and c.miss_paths[3] == "/gone")
end

-- ---------------------------------------------------------------------------
-- Empty input: no classification needed, caller gets a zero result.
-- ---------------------------------------------------------------------------
print("\n--- empty input ---")
do
    local c = cache._classify_paths({}, {}, {})
    check("empty input: zero hits", c.hit_count == 0)
    check("empty input: zero misses", #c.miss_paths == 0)
    check("empty input: zero missing files", c.missing_count == 0)
    check("empty input: empty results", next(c.results) == nil)
end

if failed > 0 then
    print(string.format("\n%d check(s) failed", failed))
    os.exit(1)
end
print("\n✅ test_media_probe_cache_classify.lua passed")
