#!/usr/bin/env luajit
-- Regression: persistent_widget.set() must persist to disk without the
-- caller needing to wire a shutdown hook. Feature 012's collapse state
-- was defined as "persist across sessions (FR-021a)", but the original
-- implementation kept changes in memory only — schema.lua called set()
-- on every toggle, never save(), and no other subsystem drove the save
-- either. Net effect: user collapse preferences silently reverted to
-- defaults on every app restart.
--
-- Behavioral contract under test (domain-level, not tracing code):
--   * After a single set() with no subsequent save() call, relaunch
--     (simulated by fresh module load from the same state_path)
--     observes the stored value.
--   * Repeated set() with the same value does NOT churn the file
--     (irrelevant to correctness, but worth pinning so anyone looking
--     at this later doesn't assume every call rewrites).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

print("=== persistent_widget: set() is write-through ===")

local state_path = "/tmp/jve/test_persistent_widget_writes_through.json"
os.remove(state_path)
os.execute("mkdir -p /tmp/jve")

-- Round 1: single set(), no save() call.
package.loaded["core.persistent_widget"] = nil
local pw = require("core.persistent_widget")
pw._set_path_for_test(state_path)
pw._reset_for_test()
pw.set("section.Audio.expanded", false)

assert(io.open(state_path, "r"),
    "set() alone must produce a state file — no shutdown hook needed")
print("  OK: set() writes to disk immediately")

-- Round 2: fresh module load sees the value.
package.loaded["core.persistent_widget"] = nil
pw = require("core.persistent_widget")
pw._set_path_for_test(state_path)
pw._reset_for_test()
assert(pw.get("section.Audio.expanded", true) == false,
    "second process reads what the first set() wrote")
print("  OK: value survives simulated relaunch")

-- Round 3: setting to the same value is a no-op, but on-disk contents
-- stay present and correct.
local mtime_before = (function()
    local h = io.popen(string.format("stat -f '%%m' %q", state_path))
    local m = h and h:read("*l") or nil
    if h then h:close() end
    return tonumber(m)
end)()
os.execute("sleep 1")  -- mtime resolution
pw.set("section.Audio.expanded", false)
local mtime_after = (function()
    local h = io.popen(string.format("stat -f '%%m' %q", state_path))
    local m = h and h:read("*l") or nil
    if h then h:close() end
    return tonumber(m)
end)()
assert(mtime_before == mtime_after,
    string.format("unchanged set() should not rewrite file (mtime %s → %s)",
        tostring(mtime_before), tostring(mtime_after)))
print("  OK: set() with unchanged value is a no-op")

os.remove(state_path)
print("✅ test_persistent_widget_writes_through.lua passed")
