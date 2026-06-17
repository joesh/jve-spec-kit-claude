-- test_rename_track_target.lua
-- Black-box: which track does the RenameTrack starter open the editor on?
-- Domain rules (NLE convention for an F2 / double-click rename accelerator):
--   * Double-click a track name -> rename THAT track (explicit target wins).
--   * F2 with a track header explicitly focused -> rename the focused track.
--   * F2 with no focused track but a clip selection on a single track ->
--     rename that track (discoverable: select a clip, press F2).
--   * F2 with selection spanning multiple tracks -> ambiguous, no target.
--   * F2 with nothing focused and nothing selected -> no target.
require('test_env')

local rename_track = require("core.commands.rename_track")
local resolve = rename_track.resolve_target
assert(type(resolve) == "function",
    "rename_track must expose a pure resolve_target(arg, focused, selected_clips)")

local function clip_on(track) return { clip_id = "c-" .. track, track_id = track } end

-- Explicit target (double-click) wins over everything else.
assert(resolve("track-A", "track-FOCUS", { clip_on("track-B") }) == "track-A",
    "explicit arg track_id must win")

-- Focused header beats selection.
assert(resolve(nil, "track-FOCUS", { clip_on("track-B") }) == "track-FOCUS",
    "focused track must win over selection when no explicit arg")
assert(resolve("", "track-FOCUS", {}) == "track-FOCUS",
    "empty-string arg is treated as absent")

-- No focus: single-track selection resolves to that track.
assert(resolve(nil, nil, { clip_on("track-B") }) == "track-B",
    "single-track selection must resolve to that track")
assert(resolve(nil, nil, { clip_on("track-B"), clip_on("track-B") }) == "track-B",
    "multiple clips on ONE track still resolve to that track")

-- Ambiguous / empty -> nil (caller asserts).
assert(resolve(nil, nil, { clip_on("track-B"), clip_on("track-C") }) == nil,
    "selection spanning multiple tracks is ambiguous -> nil")
assert(resolve(nil, nil, {}) == nil, "no focus + no selection -> nil")
assert(resolve(nil, nil, nil) == nil, "nil selection -> nil")

print("✅ test_rename_track_target.lua passed")
