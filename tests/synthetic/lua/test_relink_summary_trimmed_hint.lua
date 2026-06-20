#!/usr/bin/env luajit
-- Test: media_relink_dialog._format_results_summary surfaces an action-oriented
-- prompt — "N items will relink if you enable Accept Trimmed Media" — directly
-- after the one-line summary, when failed[] rejections carry
-- relinkable_if_trimmed (name-matched files turned down ONLY because the
-- Accept Trimmed Media rule is off). The escape hatch must be discoverable at
-- the top, not buried in the per-file rejected list.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

_G.qt_create_single_shot_timer = _G.qt_create_single_shot_timer or function() end

local dialog = require("ui.media_relink_dialog")

print("=== relink summary: Accept Trimmed Media hint ===")

local media_infos = {
    ["t1"] = { name = "A015.mov", path = "/Cam/A015.mov" },
    ["t2"] = { name = "A016.mov", path = "/Cam/A016.mov" },
    ["r1"] = { name = "A017.mov", path = "/Cam/A017.mov" },
}

-- Two rejections that WOULD relink if Accept Trimmed Media were enabled, one
-- plain rejection that would not.
local results = {
    relinked = {},
    ambiguous = {},
    failed = {
        { media_id = "t1", kind = "rejected",
          reason = "found A015.mov: timecode 14:45 does not match stored 14:44",
          relinkable_if_trimmed = true },
        { media_id = "t2", kind = "rejected",
          reason = "found A016.mov: timecode 10:13 does not match stored 10:12",
          relinkable_if_trimmed = true },
        { media_id = "r1", kind = "rejected",
          reason = "found A017.mov: resolution 1920x1080 does not match stored 4096x2160" },
    },
}

local html = dialog._format_results_summary(results, media_infos)

-- 1. The hint names the correct count (2 of the 3 rejections).
assert(html:find("2 items will relink if you enable"), string.format(
    "expected '2 items will relink if you enable …' in summary; got:\n%s", html))

-- 2. It appears right after the one-line summary — before the per-file
--    "Found, but didn't match" rejected list.
local hint_pos = html:find("will relink if you enable")
local rejected_pos = html:find("Found, but didn't match")
assert(hint_pos and rejected_pos and hint_pos < rejected_pos, string.format(
    "hint (pos %s) must precede the rejected list (pos %s)",
    tostring(hint_pos), tostring(rejected_pos)))

-- 3. Singular form when exactly one.
local one = {
    relinked = {}, ambiguous = {},
    failed = {
        { media_id = "t1", kind = "rejected", reason = "tc mismatch",
          relinkable_if_trimmed = true },
    },
}
assert(dialog._format_results_summary(one, media_infos):find("1 item will relink"),
    "expected singular '1 item will relink'")

-- 4. No hint when no rejection is trim-relinkable.
local none = {
    relinked = {}, ambiguous = {},
    failed = {
        { media_id = "r1", kind = "rejected", reason = "resolution mismatch" },
        { media_id = "x",  kind = "not_found" },
    },
}
assert(not dialog._format_results_summary(none, media_infos):find("will relink if you enable"),
    "must NOT show the hint when no rejection is relinkable-if-trimmed")

print("✅ test_relink_summary_trimmed_hint.lua passed")
