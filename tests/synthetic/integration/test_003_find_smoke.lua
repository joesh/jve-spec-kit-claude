-- 003 smoke: Find selects clips matching a query.
--
-- Acceptance Scenario 1 (Bin Find): a project browser with master clips;
-- typing "INT" with Contains operator selects clips whose name contains "INT".
-- Black-box check against the production query_engine + find_state modules.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_003_find_smoke.lua ===")

require("test_env")
local query_engine = require("core.query_engine")
local find_state   = require("core.find_state")

-- Synthetic clip records as the find pipeline sees them — name + a few
-- searchable fields. query_engine.filter is the pure-data matcher (no DB).
local clips = {
    { id = "c1", name = "INT-warehouse-day"           },
    { id = "c2", name = "EXT-rooftop-night"           },
    { id = "c3", name = "INT-loft-magic-hour"         },
    { id = "c4", name = "B-roll-handheld"             },
    { id = "c5", name = "INTERVIEW-Anna"              },
}

local query = {{ column = "name", operator = "contains", value = "INT" }}
local matches = query_engine.filter(clips, query)
assert(#matches == 3, string.format(
    "Contains 'INT' must match c1, c3, c5 (INT-* + INTERVIEW); got %d",
    #matches))
local ids = {}
for _, c in ipairs(matches) do ids[#ids+1] = c.id end
table.sort(ids)
assert(ids[1] == "c1" and ids[2] == "c3" and ids[3] == "c5",
    "matched ids should be c1, c3, c5; got " .. table.concat(ids, ","))
print(string.format("  PASS: query_engine.filter matched %d/5 clips: %s",
    #matches, table.concat(ids, ", ")))

-- find_state records the match set and (separately) the prior selection
-- so Escape can restore. Smoke-check the public surface.
find_state.save_selection({ "c4" })
find_state.execute(clips, query)
assert(find_state.is_active(), "find_state should be active after execute")
assert(find_state.get_match_count() == 3,
    "find_state must report 3 matches")
local prev = find_state.get_previous_selection()
assert(prev and prev[1] == "c4",
    "find_state must record the prior selection for Escape-restore")
print("  PASS: find_state recorded matches + previous selection")

print("\n✅ test_003_find_smoke.lua passed")
