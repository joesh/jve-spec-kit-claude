#!/usr/bin/env luajit
-- Contract: edge_picker requires clip bounds in canonical integer-frame form.
-- Producers (db.load_clip_entry + clip_geometry.normalize_clip_integers,
-- apply_mutations) normalize to integers; any non-integer bound on a clip
-- handed to edge_picker is a producer bug and must crash (rule 1.14 / 2.13).
-- Previous version of this test fed Rational tables and asserted graceful
-- silent-skip — that was a fallback hiding the contract violation.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local edge_picker = require("ui.timeline.edge_picker")

local function time_to_pixel(t, _w) return t end

-- Happy path: integer-frame bounds — pick_edges returns a valid result shape.
local valid_clip = {
    id = "c1", track_id = "v1",
    sequence_start = 0, duration = 24,
}
local result = edge_picker.pick_edges({valid_clip}, 0, 1000, {
    edge_zone = 8, roll_zone = 6, time_to_pixel = time_to_pixel,
})
assert(result and type(result.selection) == "table",
    "pick_edges with valid integer-bound clip must return a result with selection table")

-- Error path: Rational-table bounds — producer bug, must crash with clip_id context.
local rational_clip = {
    id = "c_bad", track_id = "v1",
    sequence_start = {frames = 0, fps_numerator = 24, fps_denominator = 1},
    duration = {frames = 24, fps_numerator = 24, fps_denominator = 1},
}
local ok, err = pcall(function()
    edge_picker.pick_edges({rational_clip}, 0, 1000, {
        edge_zone = 8, roll_zone = 6, time_to_pixel = time_to_pixel,
    })
end)
assert(not ok, "pick_edges must reject non-integer sequence_start (producer-bug surface)")
assert(tostring(err):find("c_bad", 1, true),
    "rejection error must cite the offending clip_id, got: " .. tostring(err))

print("✅ edge_picker enforces integer-frame clip-bound contract (happy + producer-bug path)")
