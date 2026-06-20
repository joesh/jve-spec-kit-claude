-- test_find_reproduction.lua — the Find filter can target grade reproduction
-- (spec 023 FR-015): an editor wants to find every shot whose Resolve grade
-- JVE can't fully show (the 'not_shown' spatial grades). Behavior is the
-- user contract: a clip matches a reproduction value iff its grade carries
-- that value; ungraded clips match nothing.

require("test_env")

local query_engine = require("core.query_engine")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end
end

-- reproduction is an offered, searchable field.
local has_field = false
for _, f in ipairs(query_engine.get_searchable_fields()) do
    if f.name == "reproduction" then has_field = true end
end
check("reproduction is a searchable field", has_field)

local function matches(reproduction, value)
    return query_engine.match(
        { id = "c", reproduction = reproduction },
        { column = "reproduction", operator = "matches_exactly", value = value })
end

check("not_shown clip matches 'not_shown'", matches("not_shown", "not_shown"))
check("approximate clip matches 'approximate'",
    matches("approximate", "approximate"))
check("not_shown clip does NOT match 'full'", not matches("not_shown", "full"))
check("full clip does NOT match 'not_shown'", not matches("full", "not_shown"))

-- ungraded clip (no reproduction value) matches nothing.
check("ungraded clip matches no reproduction value",
    not query_engine.match({ id = "c" },
        { column = "reproduction", operator = "matches_exactly",
          value = "not_shown" }))

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_find_reproduction.lua had failures")
print("✅ test_find_reproduction.lua passed")
