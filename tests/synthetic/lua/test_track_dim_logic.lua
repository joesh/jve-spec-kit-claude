require('test_env')

local dim = require("ui.timeline.track_dim_logic")

-- helpers
local function audio(soloed, muted)
    return { track_type = "AUDIO", soloed = soloed or 0, muted = muted or 0 }
end
local function video(soloed, muted)
    return { track_type = "VIDEO", soloed = soloed or 0, muted = muted or 0 }
end

-- ── any_solo_for_type ────────────────────────────────────────────────────────

local tracks = { audio(0), audio(1), video(0), video(0) }
assert(dim.any_solo_for_type(tracks, "AUDIO"),  "audio solo detected when A2 soloed")
assert(not dim.any_solo_for_type(tracks, "VIDEO"), "video solo NOT detected when only audio is soloed")

local tracks2 = { audio(0), video(1), video(0) }
assert(dim.any_solo_for_type(tracks2, "VIDEO"), "video solo detected when V1 soloed")
assert(not dim.any_solo_for_type(tracks2, "AUDIO"), "audio solo NOT detected when only video is soloed")

assert(not dim.any_solo_for_type({}, "AUDIO"), "no solo in empty track list")

-- boolean soloed field also works (Track.load normalises to bool)
assert(dim.any_solo_for_type({ audio(true) }, "AUDIO"), "boolean true soloed recognised")

-- ── should_dim ───────────────────────────────────────────────────────────────

-- muted track is always dim regardless of solo context
assert(dim.should_dim(audio(0, 1), false), "muted, no-solo context → dim")
assert(dim.should_dim(audio(0, 1), true),  "muted, any-solo context  → dim")

-- unmuted, non-soloed, no active solo → not dim
assert(not dim.should_dim(audio(0, 0), false), "unmuted non-soloed no solo → not dim")

-- solo context: non-soloed track dims, soloed track does not
assert(    dim.should_dim(audio(0, 0), true),  "non-soloed in solo context → dim")
assert(not dim.should_dim(audio(1, 0), true),  "soloed in solo context → not dim")

-- soloed AND muted → still dim (mute wins)
assert(dim.should_dim(audio(1, 1), true), "soloed+muted → dim (mute wins)")

-- boolean muted field also works
assert(dim.should_dim(audio(0, true), false), "boolean true muted recognised")

-- ── A/V isolation — the key invariant ────────────────────────────────────────

-- Soloing an audio track must NOT dim video tracks.
local mixed = { audio(1), audio(0), video(0), video(0) }
local any_a = dim.any_solo_for_type(mixed, "AUDIO")
local any_v = dim.any_solo_for_type(mixed, "VIDEO")
assert(any_a,     "audio solo active in mixed list")
assert(not any_v, "video solo NOT active when only audio is soloed")
-- video tracks pass their own any_solo context (any_v = false) → not dim
assert(not dim.should_dim(video(0), any_v),
    "video track not dimmed when only an audio track is soloed")
-- non-soloed audio track in same list IS dim
assert(dim.should_dim(audio(0), any_a),
    "non-soloed audio dims when another audio track is soloed")

-- Symmetric: soloing a video track must NOT dim audio tracks.
local mixed2 = { video(1), video(0), audio(0), audio(0) }
local any_a2 = dim.any_solo_for_type(mixed2, "AUDIO")
local any_v2 = dim.any_solo_for_type(mixed2, "VIDEO")
assert(any_v2,     "video solo active in mixed list")
assert(not any_a2, "audio solo NOT active when only video is soloed")
assert(not dim.should_dim(audio(0), any_a2),
    "audio track not dimmed when only a video track is soloed")
assert(dim.should_dim(video(0), any_v2),
    "non-soloed video dims when another video track is soloed")

print("✅ test_track_dim_logic.lua passed")
