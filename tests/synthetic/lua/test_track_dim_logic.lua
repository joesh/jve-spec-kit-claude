require('test_env')

local dim = require("ui.timeline.track_dim_logic")

-- helpers — model layer always produces booleans; use false/true only
local function audio(soloed, muted)
    return { track_type = "AUDIO", soloed = soloed or false, muted = muted or false }
end
local function video(soloed, muted)
    return { track_type = "VIDEO", soloed = soloed or false, muted = muted or false }
end

-- ── any_solo_for_type ────────────────────────────────────────────────────────

local tracks = { audio(false), audio(true), video(false), video(false) }
assert(dim.any_solo_for_type(tracks, "AUDIO"),      "audio solo detected when A2 soloed")
assert(not dim.any_solo_for_type(tracks, "VIDEO"),  "video solo NOT detected when only audio is soloed")

local tracks2 = { audio(false), video(true), video(false) }
assert(dim.any_solo_for_type(tracks2, "VIDEO"),     "video solo detected when V1 soloed")
assert(not dim.any_solo_for_type(tracks2, "AUDIO"), "audio solo NOT detected when only video is soloed")

assert(not dim.any_solo_for_type({}, "AUDIO"), "no solo in empty track list")

-- ── should_dim ───────────────────────────────────────────────────────────────

-- muted track is always dim regardless of solo context
assert(    dim.should_dim(audio(false, true),  false), "muted, no-solo context  → dim")
assert(    dim.should_dim(audio(false, true),  true),  "muted, any-solo context → dim")

-- unmuted, non-soloed, no active solo → not dim
assert(not dim.should_dim(audio(false, false), false), "unmuted non-soloed no solo → not dim")

-- solo context: non-soloed track dims, soloed track does not
assert(    dim.should_dim(audio(false, false), true),  "non-soloed in solo context → dim")
assert(not dim.should_dim(audio(true,  false), true),  "soloed in solo context → not dim")

-- soloed AND muted → NOT dim (solo trumps mute: the track is heard, so it is lit)
assert(not dim.should_dim(audio(true, true), true), "soloed+muted → not dim (solo trumps mute)")

-- ── A/V isolation — the key invariant ────────────────────────────────────────

local mixed = { audio(true), audio(false), video(false), video(false) }
local any_a = dim.any_solo_for_type(mixed, "AUDIO")
local any_v = dim.any_solo_for_type(mixed, "VIDEO")
assert(any_a,     "audio solo active in mixed list")
assert(not any_v, "video solo NOT active when only audio is soloed")
assert(not dim.should_dim(video(false), any_v),
    "video track not dimmed when only an audio track is soloed")
assert(dim.should_dim(audio(false), any_a),
    "non-soloed audio dims when another audio track is soloed")

local mixed2 = { video(true), video(false), audio(false), audio(false) }
local any_a2 = dim.any_solo_for_type(mixed2, "AUDIO")
local any_v2 = dim.any_solo_for_type(mixed2, "VIDEO")
assert(any_v2,     "video solo active in mixed list")
assert(not any_a2, "audio solo NOT active when only video is soloed")
assert(not dim.should_dim(audio(false), any_a2),
    "audio track not dimmed when only a video track is soloed")
assert(dim.should_dim(video(false), any_v2),
    "non-soloed video dims when another video track is soloed")

-- ── failure paths (rule 1.14 — asserts must fire) ───────────────────────────

local ok, err

ok, err = pcall(dim.should_dim, nil, false)
assert(not ok, "should_dim(nil) must assert")
assert(err:find("track is nil"), "wrong error: " .. tostring(err))

ok, err = pcall(dim.any_solo_for_type, nil, "AUDIO")
assert(not ok, "any_solo_for_type(nil) must assert")
assert(err:find("tracks is nil"), "wrong error: " .. tostring(err))

ok, err = pcall(dim.any_solo_for_type, {}, "MIDI")
assert(not ok, "any_solo_for_type unknown type must assert")
assert(err:find("unknown track_type"), "wrong error: " .. tostring(err))

print("✅ test_track_dim_logic.lua passed")
