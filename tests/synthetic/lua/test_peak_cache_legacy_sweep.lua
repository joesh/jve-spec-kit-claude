#!/usr/bin/env luajit

-- Behavior: when the peak cache moved from the old per-project layout
--     ~/Library/Caches/JVE/<name>_<project_id>/peaks/
-- to the global layout
--     ~/Library/Caches/JVE/peaks/
-- the orphaned per-project directories must be swept once and only once.
-- Those dirs hold regenerable peak files keyed under dead project_ids; left
-- in place they silently consume gigabytes that nothing will ever read.
--
-- Domain rule under test: the migration reclaims every dead per-project
-- cache directory, leaves the live global peaks/ directory untouched, and
-- is idempotent — running it again does nothing (a marker records that the
-- one-time sweep already happened).

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

local function dir_exists(path)
    return os.execute(string.format("test -d %q", path)) == 0
end
local function file_exists(path)
    local f = io.open(path, "rb"); if f then f:close(); return true end; return false
end

print("\n=== peak cache legacy layout sweep (one-time, idempotent) ===")

local sweep = require("core.media.peak_cache_reclaim")

local ROOT = "/tmp/jve/cacheroot_" .. tostring(os.time()) .. "/JVE"
sh(string.format("rm -rf %q && mkdir -p %q", ROOT, ROOT))

-- New global layout: keep this.
sh(string.format("mkdir -p %q/peaks", ROOT))
local keep = ROOT .. "/peaks/keep__ch0.peaks"
sh(string.format("touch %q", keep))

-- Two legacy per-project dirs (name_uuid): sweep these.
local legacy1 = ROOT .. "/anamnesis-gold-timeline_d0857a2f-3b12-405b-9bc2-049338374073"
local legacy2 = ROOT .. "/some-other-project_69c94963-38ef-4cee-96df-f19787f5be21"
sh(string.format("mkdir -p %q/peaks && touch %q/peaks/x__ch0.peaks", legacy1, legacy1))
sh(string.format("mkdir -p %q/peaks && touch %q/peaks/y__ch0.peaks", legacy2, legacy2))

-- ---- First sweep ----------------------------------------------------------
local r = sweep.migrate_legacy_layout(ROOT)
check("first sweep returns a table", type(r) == "table")
check("legacy project dir #1 removed", not dir_exists(legacy1))
check("legacy project dir #2 removed", not dir_exists(legacy2))
check("global peaks/ dir untouched", dir_exists(ROOT .. "/peaks"))
check("global peak file untouched", file_exists(keep))
check("reports two dirs removed", type(r) == "table" and r.removed == 2)
check("marker written after sweep",
    file_exists(ROOT .. "/.global_layout_v1"))

-- ---- Second sweep: idempotent --------------------------------------------
-- Re-create a legacy dir to prove the marker (not the absence of dirs)
-- gates the sweep: once migrated, we never scan/delete again.
sh(string.format("mkdir -p %q/peaks && touch %q/peaks/z__ch0.peaks", legacy1, legacy1))
local r2 = sweep.migrate_legacy_layout(ROOT)
check("second sweep is a no-op (already migrated)",
    type(r2) == "table" and r2.skipped == true)
check("second sweep does NOT re-scan/remove (marker gates it)",
    dir_exists(legacy1))
check("global peaks/ still intact after second call",
    dir_exists(ROOT .. "/peaks") and file_exists(keep))

sh(string.format("rm -rf %q", ROOT:match("(.+)/JVE$") or ROOT))

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
print("✅ test_peak_cache_legacy_sweep.lua passed")
