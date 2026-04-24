#!/usr/bin/env luajit
-- Unit test T007: schema filter matching (FR-019, FR-020, FR-021).
-- Black-box: uses a synthetic section record — no Qt widgets.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local schema = require("ui.inspector.schema")

local pass, fail = 0, 0
local function check(label, got, want) if got == want then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. string.format(" — got %s want %s", tostring(got), tostring(want))) end end

print("=== Inspector: schema filter matching unit test ===\n")

local audio = { name = "Audio", field_labels = { "Volume", "Pan", "Mute" } }
local source = { name = "Source Range", field_labels = {
    "Timeline Start", "Duration", "Source In", "Source Out",
    "Mark In", "Mark Out", "Source Playhead"
}}
local project = { name = "Project", field_labels = {
    "Timeline Name", "Frame Rate", "Width", "Height",
    "Audio Sample Rate", "Start Timecode"
}}

-- Empty query matches everything (FR-020).
check("empty query → audio matches",  schema._section_matches_filter(audio, ""),  true)
check("nil query → audio matches",    schema._section_matches_filter(audio, nil), true)

-- Match on section name (case-insensitive substring).
check("query 'audio' matches Audio",       schema._section_matches_filter(audio, "audio"), true)
check("query 'AUDIO' matches Audio",       schema._section_matches_filter(audio, "AUDIO"), true)
check("query 'range' matches Source Range",schema._section_matches_filter(source, "range"), true)

-- Match on any field label (case-insensitive substring).
check("query 'mute' matches Audio via label 'Mute'",
    schema._section_matches_filter(audio, "mute"), true)
check("query 'TIMECODE' matches Project via 'Start Timecode'",
    schema._section_matches_filter(project, "TIMECODE"), true)
check("query 'mark' matches Source Range",
    schema._section_matches_filter(source, "mark"), true)

-- No match.
check("query 'xyz' does not match Audio",  schema._section_matches_filter(audio, "xyz"),  false)
check("query 'banana' does not match Project", schema._section_matches_filter(project, "banana"), false)

-- Partial substring match.
check("query 'rat' matches Project (Frame Rate / Audio Sample Rate)",
    schema._section_matches_filter(project, "rat"), true)

-- Persistent-key format (stability test).
check("persistent key format",
    schema._persisted_key("clip", "Source Range"),
    "inspector.section.clip.Source Range.expanded")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_filter_matching.lua passed")
