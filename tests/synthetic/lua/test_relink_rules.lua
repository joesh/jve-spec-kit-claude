#!/usr/bin/env luajit
-- relink_rules: defaults + the "at least one anchor" validity constraint that
-- the relink dialog enforces live as the user toggles checkboxes.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local relink_rules = require("ui.relink_rules")

print("=== test_relink_rules.lua ===")

-- Defaults: filename + timecode on, the rest off.
local d = relink_rules.default_rules()
assert(d.match_filename == true and d.match_timecode == true,
    "defaults: filename + timecode must be on")
assert(d.match_resolution == false and d.match_frame_rate == false
    and d.accept_trimmed_media == false and d.accept_filename_suffixes == false,
    "defaults: all non-anchor rules must be off")

-- Every descriptor key must be present in default_rules (no orphan checkbox).
for _, rule in ipairs(relink_rules.RULES) do
    assert(d[rule.key] ~= nil, "default_rules missing key " .. rule.key)
end

-- Validity: at least one of filename/timecode.
assert(relink_rules.validate({ match_filename = true, match_timecode = false }),
    "filename-only must validate")
assert(relink_rules.validate({ match_filename = false, match_timecode = true }),
    "timecode-only must validate")
local ok, err = relink_rules.validate({ match_filename = false, match_timecode = false })
assert(not ok and type(err) == "string" and err ~= "",
    "no anchor must be invalid with a message")

print("✅ test_relink_rules.lua passed")
