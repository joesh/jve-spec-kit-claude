-- test_clip_marker_model.lua — ClipMarker.new() validation (pure, no DB).
--
-- Domain: a clip marker has a position (frame, >= 0), a span (duration, >= 1
-- frame; a point marker is exactly 1), one of Resolve's 16 named colors, and a
-- name. Note and custom data are optional. Constructing a marker that violates
-- any of these is a programming error and must fail loudly with an actionable
-- message (rule 1.14 / 2.32), not produce a half-built marker that later
-- persists garbage.
require("test_env")
local ClipMarker = require("models.clip_marker")

-- Assert `fn` raises, and that the message names the offending field.
local function expect_error(fn, substr, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected an error, got success")
    assert(tostring(err):find(substr, 1, true), string.format(
        "%s: error %q does not mention %q", label, tostring(err), substr))
end

-- A valid marker: only the required fields; note/custom_data default to "".
local m = ClipMarker.new({
    clip_id = "clip-1", frame = 30, duration = 1, color = "Red", name = "shot 4",
})
assert(m.id and #m.id > 0, "marker must receive a generated id")
assert(m.note == "" and m.custom_data == "",
    "absent note/custom_data must default to empty string, not nil")

-- Each required field, when absent, fails naming that field.
expect_error(function() ClipMarker.new({
    frame = 0, duration = 1, color = "Red", name = "x" }) end,
    "clip_id", "missing clip_id")
expect_error(function() ClipMarker.new({
    clip_id = "c", duration = 1, color = "Red", name = "x" }) end,
    "frame", "missing frame")
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = 0, color = "Red", name = "x" }) end,
    "duration", "missing duration")
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = 0, duration = 1, name = "x" }) end,
    "color", "missing color")
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = 0, duration = 1, color = "Red" }) end,
    "name", "missing name")

-- Domain bounds: position can't be negative; a span is at least one frame.
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = -1, duration = 1, color = "Red", name = "x" }) end,
    "frame", "negative frame")
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = 0, duration = 0, color = "Red", name = "x" }) end,
    "duration", "zero-width span (point marker is 1)")

-- Color must be one of the 16 Resolve names; anything else is decoded garbage.
expect_error(function() ClipMarker.new({
    clip_id = "c", frame = 0, duration = 1, color = "Mauve", name = "x" }) end,
    "color", "unknown color")

-- frame 0 is valid (start-of-clip marker); duration 1 is the point marker; a
-- larger duration is a span.
local at_start = ClipMarker.new({
    clip_id = "c", frame = 0, duration = 1, color = "Blue", name = "head" })
assert(at_start.frame == 0 and at_start.duration == 1,
    "frame 0 / duration 1 (point marker at clip start) must be accepted")
local span = ClipMarker.new({
    clip_id = "c", frame = 0, duration = 24, color = "Blue", name = "range" })
assert(span.duration == 24, "span marker must keep its duration")

print("✅ test_clip_marker_model.lua passed (new() validation + domain bounds)")
