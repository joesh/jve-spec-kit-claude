#!/usr/bin/env luajit
-- Unit test T012a: persistent_widget cross-session roundtrip (FR-021a / /analyze G2).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: persistent_widget roundtrip unit test ===\n")

local state_path = "/tmp/jve/test_persistent_widget_state.json"
os.remove(state_path)
os.execute("mkdir -p /tmp/jve")

-- Round 1: write.
package.loaded["core.persistent_widget"] = nil
local pw = require("core.persistent_widget")
pw._set_path_for_test(state_path)
pw._reset_for_test()

pw.set("inspector.section.clip.Audio.expanded", false)
pw.set("inspector.section.clip.File.expanded",  true)
pw.set("some.number", 42)
pw.set("some.string", "hello")
pw.save()

check("state file was written", io.open(state_path, "r") ~= nil)

-- Round 2: fresh module load (simulated relaunch) — must read back.
package.loaded["core.persistent_widget"] = nil
pw = require("core.persistent_widget")
pw._set_path_for_test(state_path)
pw._reset_for_test()

check("roundtrip: Audio.expanded=false",
    pw.get("inspector.section.clip.Audio.expanded", true) == false)
check("roundtrip: File.expanded=true",
    pw.get("inspector.section.clip.File.expanded", false) == true)
check("roundtrip: number",  pw.get("some.number", 0) == 42)
check("roundtrip: string",  pw.get("some.string", "") == "hello")
check("missing key returns fallback",
    pw.get("not.there", "dflt") == "dflt")

-- Non-scalar value must be rejected (rule 2.13 — no silent schema drift).
local ok = pcall(function() pw.set("table_key", {a = 1}) end)
check("set rejects table value", not ok)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
os.remove(state_path)
print("✅ test_inspector_persistent_widget.lua passed")
