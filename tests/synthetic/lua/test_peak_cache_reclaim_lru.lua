#!/usr/bin/env luajit

-- Behavior: a GLOBAL peak cache has no per-project directory to delete on
-- project close, so disk is reclaimed by a size-capped LRU sweep keyed on
-- access time. The least-recently-ACCESSED peak files are evicted first
-- (a waveform shown recently on a timeline has a fresh atime and survives;
-- one never displayed ages out). Files currently in use this session are
-- never evicted, even if they are the oldest on disk.
--
-- Domain rule under test: the cache stays under a configured byte ceiling
-- by dropping the coldest regenerable peaks, and never drops peaks the
-- running editor still holds open.

require("test_env")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, "setup command failed: " .. cmd)
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Create a .peaks file of exactly `bytes` length, then stamp its atime.
-- atime stamp form for `touch -a -t`: [[CC]YY]MMDDhhmm[.SS].
local function make_peak(dir, stem, bytes, atime_stamp)
    local path = string.format("%s/%s.peaks", dir, stem)
    local w = assert(io.open(path, "wb"))
    w:write(string.rep("x", bytes))
    w:close()
    sh(string.format("touch -a -t %s %q", atime_stamp, path))
    return path
end

print("\n=== peak cache reclaim: size-capped LRU by atime ===")

local reclaim = require("core.media.peak_cache_reclaim")

-- ---- Scenario 1: plain LRU eviction down to the cap -----------------------
local DIR = "/tmp/jve/reclaim_lru_" .. tostring(os.time())
sh(string.format("rm -rf %q && mkdir -p %q", DIR, DIR))

-- 4 files × 100 bytes = 400 total. atimes ascending f1(oldest)..f4(newest).
local p1 = make_peak(DIR, "aaaa__ch0", 100, "200001010000")
local p2 = make_peak(DIR, "bbbb__ch0", 100, "200101010000")
local p3 = make_peak(DIR, "cccc__ch0", 100, "200201010000")
local p4 = make_peak(DIR, "dddd__ch0", 100, "200301010000")

-- Cap 250: must drop the two coldest (f1,f2 → 200 left ≤ 250), keep f3,f4.
local r = reclaim.reclaim_lru(DIR, 250, {})
check("scenario1: result is a table", type(r) == "table")
check("scenario1: coldest file evicted", not exists(p1))
check("scenario1: 2nd-coldest evicted", not exists(p2))
check("scenario1: warmer files kept", exists(p3) and exists(p4))
check("scenario1: freed exactly the two coldest (200 bytes)",
    type(r) == "table" and r.freed_bytes == 200)
check("scenario1: kept bytes reported (200)",
    type(r) == "table" and r.kept_bytes == 200)

-- ---- Scenario 2: in-use file is never evicted, even if coldest -----------
local DIR2 = "/tmp/jve/reclaim_inuse_" .. tostring(os.time())
sh(string.format("rm -rf %q && mkdir -p %q", DIR2, DIR2))
local q1 = make_peak(DIR2, "aaaa__ch0", 100, "200001010000") -- coldest, IN USE
local q2 = make_peak(DIR2, "bbbb__ch0", 100, "200101010000")
local q3 = make_peak(DIR2, "cccc__ch0", 100, "200201010000")
local q4 = make_peak(DIR2, "dddd__ch0", 100, "200301010000")

-- Cap 250, but aaaa__ch0 is held open this session: protect it, evict the
-- next-coldest instead (b,c → 200 left ≤ 250). Keep the in-use file + d.
local r2 = reclaim.reclaim_lru(DIR2, 250, { ["aaaa__ch0"] = true })
check("scenario2: in-use coldest file survives", exists(q1))
check("scenario2: next-coldest evicted", not exists(q2))
check("scenario2: third-coldest evicted", not exists(q3))
check("scenario2: warmest kept", exists(q4))
check("scenario2: freed the two evicted (200 bytes), protected file untouched",
    type(r2) == "table" and r2.freed_bytes == 200 and r2.kept_bytes == 200)

-- ---- Scenario 3: under cap → no eviction ---------------------------------
local DIR3 = "/tmp/jve/reclaim_undercap_" .. tostring(os.time())
sh(string.format("rm -rf %q && mkdir -p %q", DIR3, DIR3))
local s1 = make_peak(DIR3, "aaaa__ch0", 100, "200001010000")
local s2 = make_peak(DIR3, "bbbb__ch0", 100, "200101010000")
local r3 = reclaim.reclaim_lru(DIR3, 10000, {})
check("scenario3: nothing evicted when under cap", exists(s1) and exists(s2))
check("scenario3: freed_bytes == 0 under cap",
    type(r3) == "table" and r3.freed_bytes == 0)

sh(string.format("rm -rf %q %q %q", DIR, DIR2, DIR3))

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("✅ test_peak_cache_reclaim_lru.lua passed")
