-- Tests for find dialog domain behavior at the find_state + query_engine level.
-- These exercise the layer that DOES work correctly, serving as regression guards.
-- Integration tests for the Qt UI layer (query_has_changed, bool field picker,
-- signal-driven refresh) require --test mode and are not included here.

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local find_state = require("core.find_state")
local query_engine = require("core.query_engine")

-- Representative clip set: mix of online/offline, enabled/disabled, various codecs
local clips = {
    {id = "c_online_enabled",   name = "Forest_WideShot",  enabled = true,  offline = false, codec = "ProRes"},
    {id = "c_online_disabled",  name = "City_CutawayB",    enabled = false, offline = false, codec = "ProRes"},
    {id = "c_offline_enabled",  name = "Studio_Interview",  enabled = true,  offline = true,  codec = "DNxHD"},
    {id = "c_offline_disabled", name = "Archive_Negative",  enabled = false, offline = true,  codec = "DNxHD"},
}

-- ============================================================================
-- Boolean field: offline (Lua boolean values, as returned by fixed get_clips())
-- ============================================================================
print("--- bool find: offline field ---")

find_state.clear()
find_state.execute(clips, {column = "offline", operator = "equals", value = "true"})
check("offline=true: finds 2 offline clips", find_state.get_match_count() == 2)
check("offline=true: active", find_state.is_active())

-- Both offline clips are found
local offline_ids = {}
offline_ids[find_state.get_current_match()] = true
find_state.next()
offline_ids[find_state.get_current_match()] = true
check("offline=true: c_offline_enabled found", offline_ids["c_offline_enabled"] == true)
check("offline=true: c_offline_disabled found", offline_ids["c_offline_disabled"] == true)

find_state.clear()
find_state.execute(clips, {column = "offline", operator = "equals", value = "false"})
check("offline=false: finds 2 online clips", find_state.get_match_count() == 2)

-- ============================================================================
-- Boolean field: enabled
-- ============================================================================
print("--- bool find: enabled field ---")

find_state.clear()
find_state.execute(clips, {column = "enabled", operator = "equals", value = "true"})
check("enabled=true: finds 2 enabled clips", find_state.get_match_count() == 2)

find_state.clear()
find_state.execute(clips, {column = "enabled", operator = "equals", value = "false"})
check("enabled=false: finds 2 disabled clips", find_state.get_match_count() == 2)

-- ============================================================================
-- Boolean field: numeric representation (SQLite returns 0/1 integers)
-- Both get_clips() implementations normalize to Lua booleans, but query_engine
-- also handles raw numerics defensively.
-- ============================================================================
print("--- bool find: numeric 0/1 representation ---")

local clips_numeric = {
    {id = "n_offline",  name = "MediaA", offline = 1},  -- SQLite integer
    {id = "n_online",   name = "MediaB", offline = 0},  -- SQLite integer
}

check("offline=1 matches value=true",
    query_engine.match(clips_numeric[1], {column = "offline", operator = "equals", value = "true"}))
check("offline=1 does not match value=false",
    not query_engine.match(clips_numeric[1], {column = "offline", operator = "equals", value = "false"}))
check("offline=0 matches value=false",
    query_engine.match(clips_numeric[2], {column = "offline", operator = "equals", value = "false"}))
check("offline=0 does not match value=true",
    not query_engine.match(clips_numeric[2], {column = "offline", operator = "equals", value = "true"}))

-- ============================================================================
-- Boolean field: missing from clip data (documents why get_clips() must include it)
-- When get_clips() omits offline, all clips match neither true nor false.
-- This is the ROOT CAUSE of Bug 3: the field must be in the clip table.
-- ============================================================================
print("--- bool find: missing offline field ---")

local clips_no_offline = {
    {id = "x1", name = "ClipA"},  -- no offline field (old broken get_clips behavior)
    {id = "x2", name = "ClipB"},  -- no offline field
}

-- Both must return 0 matches — there's nothing to match against
find_state.clear()
find_state.execute(clips_no_offline, {column = "offline", operator = "equals", value = "true"})
check("offline missing in clip → 0 matches for true", find_state.get_match_count() == 0)

find_state.clear()
find_state.execute(clips_no_offline, {column = "offline", operator = "equals", value = "false"})
check("offline missing in clip → 0 matches for false", find_state.get_match_count() == 0)

-- ============================================================================
-- Re-execute with updated clip data (Bug 1: DB change should refresh results)
-- After a command mutates clips, executing again with fresh data must give
-- updated results — not the stale session from the prior run.
-- ============================================================================
print("--- find: re-execute with fresh clip data ---")

local clips_before = {
    {id = "d1", name = "Dailies_001", enabled = true},
    {id = "d2", name = "Dailies_002", enabled = false},
}
find_state.clear()
find_state.execute(clips_before, {column = "name", operator = "contains", value = "Dailies"})
check("before mutation: 2 matches", find_state.get_match_count() == 2)
check("before mutation: active", find_state.is_active())

-- Simulate DB mutation: one clip gets renamed, a new clip appears
local clips_after = {
    {id = "d1", name = "Renamed_001", enabled = true},   -- name changed
    {id = "d2", name = "Dailies_002", enabled = false},  -- unchanged
    {id = "d3", name = "Dailies_003", enabled = true},   -- new clip
}
-- Re-execute the SAME query against the mutated clip list
find_state.execute(clips_after, {column = "name", operator = "contains", value = "Dailies"})
check("after mutation: 2 matches (d1 renamed, d3 added)", find_state.get_match_count() == 2)
check("after mutation: d1 not in results", find_state.get_current_match() ~= "d1")

-- ============================================================================
-- Re-execute with changed query (Bug 2: Next/Prev must detect query change)
-- The find_state itself correctly replaces prior results on every execute().
-- Bug 2 is in the dialog: it must call execute() again, not just next/prev.
-- ============================================================================
print("--- find: re-execute with changed query ---")

local clips_mixed = {
    {id = "m1", name = "Alpha_WideShot", enabled = true},
    {id = "m2", name = "Beta_Interview",  enabled = true},
    {id = "m3", name = "Alpha_CutawayB", enabled = false},
}

find_state.clear()
find_state.execute(clips_mixed, {column = "name", operator = "contains", value = "Alpha"})
check("query=Alpha: 2 matches", find_state.get_match_count() == 2)
check("query=Alpha: query stored", find_state.get_current_query() ~= nil)

local stored = find_state.get_current_query()
check("stored query has 1 entry", #stored == 1)
check("stored query column=name", stored[1].column == "name")
check("stored query value=Alpha", stored[1].value == "Alpha")

-- Changing the query: execute with "Beta" instead
find_state.execute(clips_mixed, {column = "name", operator = "contains", value = "Beta"})
check("query=Beta: 1 match", find_state.get_match_count() == 1)
check("query=Beta: correct match", find_state.get_current_match() == "m2")

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_find_dialog_behavior.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_find_dialog_behavior.lua passed (%d assertions)", pass_count))
