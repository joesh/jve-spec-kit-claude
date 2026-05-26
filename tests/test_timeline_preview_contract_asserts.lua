#!/usr/bin/env luajit

-- Contract pinning for the timeline_view_renderer's preview-data boundary.
--
-- Producers of preview-data (BatchRippleEdit, Nudge, and any future
-- preview-emitting command) MUST satisfy these invariants on every
-- affected_clips entry: a clip_id, a numeric new_start_value, and a
-- numeric new_duration. The track clip index MUST contain only entries
-- with numeric sequence_start. When ANY of these is violated the
-- renderer must assert loudly — never silently substitute a default.
--
-- This test calls the renderer's named contract functions directly
-- (M.assert_affected_clip_entry, M.lower_bound_start_frames) so it pins
-- the contract independent of the dispatch path. ensure_edge_preview
-- rebuilds preview_data on every render(), which would clobber any test
-- fixture inserted into drag_state — naming the contract on M decouples
-- the predicate from the render flow.

require("test_env")

local renderer = require("ui.timeline.view.timeline_view_renderer")

local function expect_assert(label, fn, needle)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected an assertion failure, but call succeeded")
    assert(tostring(err):find(needle, 1, true),
        label .. ": assert must mention '" .. needle .. "'. Got: " .. tostring(err))
end

-- assert_affected_clip_entry: well-formed entry passes silently.
do
    renderer.assert_affected_clip_entry({
        clip_id = "c1", new_start_value = 100, new_duration = 50,
    })
end

-- assert_affected_clip_entry: each missing/wrong-typed field surfaces a
-- distinct, field-named assert.
expect_assert("missing new_start_value",
    function() renderer.assert_affected_clip_entry({clip_id = "c1", new_duration = 50}) end,
    "new_start_value")

expect_assert("missing new_duration",
    function() renderer.assert_affected_clip_entry({clip_id = "c1", new_start_value = 100}) end,
    "new_duration")

expect_assert("missing clip_id",
    function() renderer.assert_affected_clip_entry({new_start_value = 100, new_duration = 50}) end,
    "clip_id")

expect_assert("entry not a table",
    function() renderer.assert_affected_clip_entry("oops") end,
    "must be a table")

expect_assert("new_start_value wrong type",
    function() renderer.assert_affected_clip_entry({clip_id = "c1", new_start_value = "100", new_duration = 50}) end,
    "new_start_value")

expect_assert("new_duration wrong type",
    function() renderer.assert_affected_clip_entry({clip_id = "c1", new_start_value = 100, new_duration = false}) end,
    "new_duration")

-- lower_bound_start_frames: well-formed sorted clip index returns the
-- index of the first entry whose sequence_start >= the query.
do
    local clips = {
        {id = "a", sequence_start = 0},
        {id = "b", sequence_start = 100},
        {id = "c", sequence_start = 250},
        {id = "d", sequence_start = 400},
    }
    assert(renderer.lower_bound_start_frames(clips, 0)   == 1)
    assert(renderer.lower_bound_start_frames(clips, 50)  == 2)
    assert(renderer.lower_bound_start_frames(clips, 100) == 2)
    assert(renderer.lower_bound_start_frames(clips, 300) == 4)
    assert(renderer.lower_bound_start_frames(clips, 999) == 5)  -- past end
    assert(renderer.lower_bound_start_frames({}, 0) == 1)        -- empty
end

-- lower_bound_start_frames: a corrupt entry (non-number sequence_start)
-- must assert with the offending field named — NOT silently scan from
-- the front (which was the prior "defensive" fallback).
expect_assert("corrupt sequence_start (string)",
    function()
        renderer.lower_bound_start_frames({
            {id = "a", sequence_start = 0},
            {id = "b", sequence_start = "not-a-number"},
            {id = "c", sequence_start = 250},
        }, 100)
    end,
    "sequence_start")

expect_assert("corrupt sequence_start (nil)",
    function()
        renderer.lower_bound_start_frames({
            {id = "a", sequence_start = 0},
            {id = "b"},
            {id = "c", sequence_start = 250},
        }, 100)
    end,
    "sequence_start")

print("✅ Preview-data contract asserts pin every NSF-violating shape")
