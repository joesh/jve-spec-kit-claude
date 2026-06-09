#!/usr/bin/env luajit
-- Unit test T008: majority-schema computation with tiebreak + stability (FR-005a).
-- Derived from spec.md §Acceptance Scenario 9 and clarify session 2026-04-19.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want)))
    end
end

print("=== Inspector: majority-schema tiebreak unit test ===\n")

-- Unanimous clip selection → clip.
check("unanimous clip",
    sb._compute_active_schema(
        {{item_type = "timeline_clip", clip_id = "c1"}},
        {clip = 1}, nil, nil, nil),
    "clip")

-- Clear clip majority over single sequence.
check("3 clips beat 1 sequence",
    sb._compute_active_schema(
        {
            {item_type = "timeline_clip", clip_id = "c1"},
            {item_type = "timeline_clip", clip_id = "c2"},
            {item_type = "timeline_clip", clip_id = "c3"},
            {item_type = "timeline_sequence", sequence_id = "s1"},
        },
        {clip = 3, sequence = 1}, nil, nil, nil),
    "clip")

-- Clear sequence majority.
check("3 sequences beat 1 clip",
    sb._compute_active_schema(
        {
            {item_type = "timeline_sequence", sequence_id = "s1"},
            {item_type = "timeline_sequence", sequence_id = "s2"},
            {item_type = "timeline_sequence", sequence_id = "s3"},
            {item_type = "timeline_clip",     clip_id = "c1"},
        },
        {sequence = 3, clip = 1}, nil, nil, nil),
    "sequence")

-- Tie broken by newly-clicked item.
-- Scenario: prev selection had clip c1; user just added sequence s1. Selection
-- is now {c1, s1}; prev_ids had only c1; newly-clicked is s1 → sequence wins.
check("tie broken by newly-clicked sequence",
    sb._compute_active_schema(
        {
            {item_type = "timeline_clip",     clip_id = "c1"},
            {item_type = "timeline_sequence", sequence_id = "s1"},
        },
        {clip = 1, sequence = 1},
        {clip = true}, "clip",
        {["clip:c1"] = true}),
    "sequence")

-- Stability: set of schemas present unchanged → keep prev active.
-- prev: {c1,s1} active=clip. new: {c2,s1} — still {clip,sequence} — keep clip.
check("stability: schema set unchanged keeps prev active",
    sb._compute_active_schema(
        {
            {item_type = "timeline_clip",     clip_id = "c2"},
            {item_type = "timeline_sequence", sequence_id = "s1"},
        },
        {clip = 1, sequence = 1},
        {clip = true, sequence = true}, "clip",
        {["clip:c1"] = true, ["seq:s1"] = true}),
    "clip")

-- Schema set changed → recompute. prev was {clip}; new is {clip, sequence}
-- with no newly-clicked item (impossible but defensive) → falls back to items[1].
check("schema set changed, newly-clicked sequence wins",
    sb._compute_active_schema(
        {
            {item_type = "timeline_clip",     clip_id = "c1"},
            {item_type = "timeline_sequence", sequence_id = "s1"},
        },
        {clip = 1, sequence = 1},
        {clip = true}, "clip",
        {["clip:c1"] = true}),
    "sequence")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_majority_schema_tiebreak.lua passed")
