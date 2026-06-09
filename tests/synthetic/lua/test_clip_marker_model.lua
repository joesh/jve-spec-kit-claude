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

-- Helper: a complete-field constructor call, varied per test.
local function with(overrides)
    local base = {
        clip_id = "clip-1", frame = 30, duration = 1, color = "Red",
        name = "shot 4", note = "", custom_data = "",
    }
    if overrides then
        for k, v in pairs(overrides) do base[k] = v end
    end
    return base
end

-- A valid marker carrying every field (empty note + empty custom_data are
-- legitimate values, not absences — rule 2.13: the model takes no defaults).
local m = ClipMarker.new(with())
assert(m.id and #m.id > 0, "marker must receive a generated id")
assert(m.note == "" and m.custom_data == "",
    "explicit empty note/custom_data must round-trip as ''")

-- Each required field, when absent, fails naming that field.
local function without(field)
    local d = with()
    d[field] = nil
    return d
end
expect_error(function() ClipMarker.new(without("clip_id")) end,
    "clip_id", "missing clip_id")
expect_error(function() ClipMarker.new(without("frame")) end,
    "frame", "missing frame")
expect_error(function() ClipMarker.new(without("duration")) end,
    "duration", "missing duration")
expect_error(function() ClipMarker.new(without("color")) end,
    "color", "missing color")
expect_error(function() ClipMarker.new(without("name")) end,
    "name", "missing name")
expect_error(function() ClipMarker.new(without("note")) end,
    "note", "missing note (must pass '' explicitly, not nil)")
expect_error(function() ClipMarker.new(without("custom_data")) end,
    "custom_data", "missing custom_data (must pass '' explicitly, not nil)")

-- Domain bounds: position can't be negative; a span is at least one frame.
expect_error(function() ClipMarker.new(with{frame = -1}) end,
    "frame", "negative frame")
expect_error(function() ClipMarker.new(with{duration = 0}) end,
    "duration", "zero-width span (point marker is 1)")

-- Color must be one of the 16 Resolve names; anything else is decoded garbage.
expect_error(function() ClipMarker.new(with{color = "Mauve"}) end,
    "color", "unknown color")

-- frame 0 is valid (start-of-clip marker); duration 1 is the point marker; a
-- larger duration is a span.
local at_start = ClipMarker.new(with{frame = 0, color = "Blue", name = "head"})
assert(at_start.frame == 0 and at_start.duration == 1,
    "frame 0 / duration 1 (point marker at clip start) must be accepted")
local span = ClipMarker.new(with{frame = 0, duration = 24, color = "Blue", name = "range"})
assert(span.duration == 24, "span marker must keep its duration")

print("✅ test_clip_marker_model.lua passed (new() validation + domain bounds)")
