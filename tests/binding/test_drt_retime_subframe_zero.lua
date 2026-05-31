#!/usr/bin/env luajit

-- Regression: Resolve writes retime-curve first keyframes with sub-frame
-- negative Y values (observed: Y = -0.0016s, -0.0032s with zero bezier
-- tangents — Resolve's literal encoding, not float noise). Resolve's
-- Inspector shows Source In = media frame 0 for these clips; no frame
-- before the file exists. Our parser must match that interpretation
-- (snap sub-frame negatives to frame 0) rather than asserting on them.
--
-- Verified against Resolve's Inspector on 2026-04-19: clip
-- A026_11060320_C040.mov at record 01:51:37:09 on the gold timeline shows
-- Source In = 03:21:26:18 (media frame 0 for that file), matching our
-- post-fix source_in value of 302168.

local test_env = require('test_env')

local drp_importer = require("importers.drp_importer")

local function fail(msg)
    error(msg, 2)
end

local fixture = test_env.require_fixture(
    "tests/fixtures/media/anamnesis/2026-02-28-anamnesis joe edit-mm/"
    .. "2026-02-28-anamnesis-GOLD-MASTER-CANDIDATE.drt")

-- Black-box: the fixture is a real Resolve timeline export with retimed
-- clips whose bezier-curve first keyframes carry sub-frame negative Y.
-- Parsing it must succeed — this matches what Resolve itself displays
-- (source in-point at media frame 0 for those clips).
local r = drp_importer.parse_drp_file(fixture)
if not r.success then
    fail("parse_drp_file failed: " .. tostring(r.error))
end

-- Domain-level assertions on every clip:
--   (1) source_in must be non-negative. A negative source frame doesn't
--       exist in Resolve's model.
--   (2) If a clip is marked reverse (source_out < source_in), the magnitude
--       must be at least one frame at the clip's native rate. Sub-frame
--       "reverses" are float noise in Resolve's piecewise-linear bezier
--       sample, not real reversed playback.
local inspected = 0
for _, tl in ipairs(r.timelines or {}) do
    for _, track in ipairs(tl.tracks or {}) do
        for _, clip in ipairs(track.clips or {}) do
            if clip.source_in ~= nil and clip.source_out ~= nil then
                inspected = inspected + 1
                if clip.source_in < 0 then
                    fail(string.format(
                        "clip '%s' has source_in=%d (must be >= 0); timeline '%s'",
                        tostring(clip.name), clip.source_in, tostring(tl.name)))
                end
                local span = clip.source_out - clip.source_in
                if span < 0 and -span < 1 then
                    fail(string.format(
                        "clip '%s' has sub-frame reverse span=%d (noise, not a real reverse); "
                        .. "native_rate=%s timeline '%s'",
                        tostring(clip.name), span,
                        tostring(clip.native_rate), tostring(tl.name)))
                end
            end
        end
    end
end

if inspected == 0 then
    fail("no clips inspected — fixture likely did not parse any tracks")
end

print(string.format("✅ test_drt_retime_subframe_zero.lua passed (%d clips)", inspected))
