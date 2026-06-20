#!/usr/bin/env luajit

-- Regression: the peak cache directory must be GLOBAL, not project-scoped.
--
-- Background. Peaks are a pure function of (source file bytes, channel).
-- The peak file is named <media_id>__ch<N>.peaks, and media_id is already
-- the source format's stable per-file identity (the Resolve <MediaRef>
-- UUID for DRP media; a persisted minted UUID otherwise). Yet the cache
-- DIRECTORY was keyed by project_id:
--     ~/Library/Caches/JVE/<name>_<project_id>/peaks/
-- Opening a .drp mints a fresh random project_id every time, so the cache
-- directory changed on every open even though the media_ids were stable —
-- a cold cache that regenerated thousands of peak files on each import
-- (TSO 2026-06-19: 2347 peaks regenerated after a DRP re-open).
--
-- Domain rule under test: where the editor stores a file's waveform must
-- depend ONLY on the file's identity, never on which project happens to
-- reference it. Two different projects asking for the cache location must
-- get the SAME directory, so a peak generated under one project is found
-- by the next.

require("test_env")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== peak cache dir: global, project-independent ===")

local HOME = assert(os.getenv("HOME"), "HOME required for test")

-- Don't pollute the real cache location: record the path mkdir is asked
-- to create instead of creating it. (The function still must ASK to
-- create its directory — we assert it returns the global path.)
local mkdir_paths = {}
-- luacheck: push ignore 121 122
local original_mkdir = _G.qt_fs_mkdir_p
_G.qt_fs_mkdir_p = function(path)
    mkdir_paths[#mkdir_paths + 1] = path
    return true
end
-- luacheck: pop

local database = require("core.database")

-- The cache dir is queried with NO project argument — it is not a
-- per-project concept. Two queries return the identical global path.
local ok1, dir1 = pcall(database.get_peak_cache_dir)
local ok2, dir2 = pcall(database.get_peak_cache_dir)

-- luacheck: push ignore 121 122
_G.qt_fs_mkdir_p = original_mkdir
-- luacheck: pop

check("get_peak_cache_dir() callable with no project argument", ok1 and ok2)

local expected = HOME .. "/Library/Caches/JVE/peaks"
check("returns the global peaks dir (~/Library/Caches/JVE/peaks)",
    dir1 == expected)
check("two calls return the identical path (project-independent)",
    ok1 and ok2 and dir1 == dir2)

-- No project UUID may appear anywhere in the path. A 36-char UUID has the
-- 8-4-4-4-12 hex shape; assert the path contains no such substring.
local function has_uuid(s)
    return s ~= nil and s:match("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x") ~= nil
end
check("path embeds no project_id UUID", ok1 and not has_uuid(dir1))

-- The function asked to create its directory, and it was the global path.
check("ensures the global directory exists",
    #mkdir_paths >= 1 and mkdir_paths[1] == expected)

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("✅ test_peak_cache_dir_global.lua passed")
