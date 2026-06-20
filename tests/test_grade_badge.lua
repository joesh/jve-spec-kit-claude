-- test_grade_badge.lua — pure reproduction→badge mapping (spec 023 FR-015).
-- The monitor overlay and the timeline clip indicator both render the SAME
-- badge meaning, so the text/short-label/colour/visibility live in one pure
-- module. Behavior is derived from the user-facing contract:
--   full / no-grade → no badge (JVE shows the real thing).
--   approximate     → NO badge: JVE shows part of the grade, the look is
--                     mostly right, and it sits on nearly every clip — a flag
--                     there is noise, not signal (Joe 2026-06-19).
--   not_shown       → a badge: JVE shows passthrough (spatial grade).

require("test_env")

local grade_badge = require("ui.grade_badge")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end
end
local function expect_assert(label, fn)
    if pcall(fn) then fail = fail + 1; print("FAIL (expected assert): " .. label)
    else pass = pass + 1 end
end

-- full and ungraded carry NO badge.
check("full → not visible", grade_badge.for_reproduction("full").visible == false)
check("nil (ungraded) → not visible",
    grade_badge.for_reproduction(nil).visible == false)

-- approximate: a valid recorded state, but NOT flagged — no visible badge.
local a = grade_badge.for_reproduction("approximate")
check("approximate → not visible", a.visible == false)

-- not_shown: the one flagged state — visible, plain-language, points at Resolve.
local n = grade_badge.for_reproduction("not_shown")
check("not_shown → visible", n.visible == true)
check("not_shown text points at Resolve",
    type(n.text) == "string" and n.text:lower():find("resolve", 1, true) ~= nil)
check("not_shown has a hex colour",
    type(n.color_hex) == "string" and n.color_hex:sub(1, 1) == "#")

-- a bogus reproduction value is a programming bug.
expect_assert("bad reproduction asserts",
    function() return grade_badge.for_reproduction("bogus") end)

-- Hover tooltip is a SEPARATE affordance from the stripe: it describes EVERY
-- graded clip (incl. approximate, which earns no stripe), and is empty only
-- for an ungraded clip. A deliberate hover is never noise.
check("full → tooltip present",
    type(grade_badge.tooltip_for_reproduction("full")) == "string")
check("approximate → tooltip present (despite no stripe)",
    type(grade_badge.tooltip_for_reproduction("approximate")) == "string")
local nt = grade_badge.tooltip_for_reproduction("not_shown")
check("not_shown tooltip points at Resolve",
    type(nt) == "string" and nt:lower():find("resolve", 1, true) ~= nil)
check("nil (ungraded) → no tooltip",
    grade_badge.tooltip_for_reproduction(nil) == nil)
expect_assert("bad reproduction tooltip asserts",
    function() return grade_badge.tooltip_for_reproduction("bogus") end)

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_grade_badge.lua had failures")
print("✅ test_grade_badge.lua passed")
