-- Regression: prproj importer must extract a media's TC origin from
-- <AlternateStart> (ticks) when <UseAlternateStart>true</UseAlternateStart>.
--
-- Domain behavior: Premiere records a file's TC origin (seconds since
-- midnight) on the <Media> element via two children:
--   <AlternateStart>   ticks (1s = 254016000000 ticks)
--   <UseAlternateStart>"true" gate
-- A media item parsed from a Media element with both fields set must
-- carry media_start_time in seconds. The downstream import_pipeline
-- (importer_core.build_media_metadata) converts that to start_tc_value
-- / start_tc_audio_samples, persisted into media.metadata JSON.
--
-- Pre-fix bug: parse_media_element ignored both fields entirely, so
-- Sequence.ensure_master fell through to _ensure_tc_extracted which
-- probed the source file. When source media isn't on disk (any portable
-- test fixture, any re-imported project), the probe asserted with
-- "media <uuid> has no video TC origin". A.035-style camera files with
-- real TC could not import without the source media present.
--
-- Black-box: only inspects parse_media_element's return value. The
-- expected seconds are derived from prproj domain (ticks/sec constant
-- = 254016000000), NOT from tracing the implementation.

require("test_env")

local prproj = require("importers.prproj_importer")

print("=== test_prproj_media_tc_origin.lua ===")

local TICKS_PER_SECOND = prproj.TICKS_PER_SECOND
assert(TICKS_PER_SECOND == 254016000000,
    "prproj domain constant changed — test assumptions invalid")

local function elem(tag, attrs, children_or_text)
    local e = { tag = tag, attrs = attrs or {}, children = {} }
    if type(children_or_text) == "string" then
        e.text = children_or_text
    elseif type(children_or_text) == "table" then
        e.children = children_or_text
    end
    return e
end
local function text_child(tag, text) return elem(tag, {}, text) end

-- Reusable AudioStream stub for media items with audio.
local SR_48K_TICKS = TICKS_PER_SECOND / 48000
local audio_stream = elem("AudioStream", { ObjectID = "9001" }, {
    text_child("AudioChannelLayout", '[{"channellabel":100},{"channellabel":101}]'),
    text_child("FrameRate", tostring(SR_48K_TICKS)),
})
local by_id = { [9001] = audio_stream }

-- ─────────────────────────────────────────────────────────────────────
-- Case 1: AlternateStart + UseAlternateStart=true → media_start_time
-- set in seconds.
-- Anamnesis fixture value 818388748800000 ticks → 3222.165354... s
-- (≈ 00:53:42 wall clock). Derived from domain constant, not impl.
-- ─────────────────────────────────────────────────────────────────────
local FIXTURE_TICKS = 818388748800000
local EXPECTED_SECONDS = FIXTURE_TICKS / TICKS_PER_SECOND

local media_with_tc = elem("Media", { ObjectUID = "uuid-with-tc" }, {
    text_child("FilePath", "/clips/A035_11200053_C050.mov"),
    text_child("Title", "A035_11200053_C050.mov"),
    elem("VideoStream", { ObjectRef = "9999" }),
    elem("AudioStream", { ObjectRef = "9001" }),
    text_child("AlternateStart", tostring(FIXTURE_TICKS)),
    text_child("UseAlternateStart", "true"),
})

local item = prproj._parse_media_element(media_with_tc, by_id)
assert(item, "media with TC must parse")
assert(item.media_start_time ~= nil,
    "Case 1: AlternateStart+UseAlternateStart=true should set media_start_time")
local diff = math.abs(item.media_start_time - EXPECTED_SECONDS)
assert(diff < 1e-6, string.format(
    "Case 1: media_start_time should be %.9f seconds, got %.9f (delta %.9f)",
    EXPECTED_SECONDS, item.media_start_time, diff))
print(string.format("  ✓ Case 1: AlternateStart=%d → media_start_time=%.6f s",
    FIXTURE_TICKS, item.media_start_time))

-- ─────────────────────────────────────────────────────────────────────
-- Case 2: Media with NO AlternateStart (e.g. screen recordings, files
-- imported without camera TC) → media_start_time = nil. Downstream
-- _ensure_tc_extracted will probe the file (or assert if absent).
-- ─────────────────────────────────────────────────────────────────────
local media_no_tc = elem("Media", { ObjectUID = "uuid-no-tc" }, {
    text_child("FilePath", "/clips/screen_recording.mov"),
    text_child("Title", "screen_recording.mov"),
    elem("VideoStream", { ObjectRef = "9999" }),
})

local item2 = prproj._parse_media_element(media_no_tc, by_id)
assert(item2, "media without TC must still parse")
assert(item2.media_start_time == nil, string.format(
    "Case 2: media without AlternateStart should have nil media_start_time, got %s",
    tostring(item2.media_start_time)))
print("  ✓ Case 2: no AlternateStart → media_start_time = nil")

-- ─────────────────────────────────────────────────────────────────────
-- Case 3: AlternateStart present but UseAlternateStart=false → must
-- IGNORE the AlternateStart value (Premiere semantics — the field is
-- present but disabled). media_start_time = nil.
-- ─────────────────────────────────────────────────────────────────────
local media_disabled = elem("Media", { ObjectUID = "uuid-disabled" }, {
    text_child("FilePath", "/clips/disabled.mov"),
    elem("VideoStream", { ObjectRef = "9999" }),
    text_child("AlternateStart", tostring(FIXTURE_TICKS)),
    text_child("UseAlternateStart", "false"),
})

local item3 = prproj._parse_media_element(media_disabled, by_id)
assert(item3, "media with disabled TC must parse")
assert(item3.media_start_time == nil, string.format(
    "Case 3: UseAlternateStart=false must ignore AlternateStart, got %s",
    tostring(item3.media_start_time)))
print("  ✓ Case 3: UseAlternateStart=false → media_start_time = nil")

-- ─────────────────────────────────────────────────────────────────────
-- Case 4: UseAlternateStart=true but AlternateStart=0 → degenerate;
-- treat as no TC (midnight = absent TC). media_start_time = nil.
-- ─────────────────────────────────────────────────────────────────────
local media_zero = elem("Media", { ObjectUID = "uuid-zero" }, {
    text_child("FilePath", "/clips/zero.mov"),
    elem("VideoStream", { ObjectRef = "9999" }),
    text_child("AlternateStart", "0"),
    text_child("UseAlternateStart", "true"),
})

local item4 = prproj._parse_media_element(media_zero, by_id)
assert(item4, "media with zero TC must parse")
assert(item4.media_start_time == nil, string.format(
    "Case 4: AlternateStart=0 should yield nil media_start_time, got %s",
    tostring(item4.media_start_time)))
print("  ✓ Case 4: AlternateStart=0 → media_start_time = nil")

print("\n✅ test_prproj_media_tc_origin.lua passed")
