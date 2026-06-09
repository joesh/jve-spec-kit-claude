-- Regression: prproj importer must read audio sample rate and channel count
-- from the referenced <AudioStream> element, not hardcode audio_channels=2
-- and not rely on <ConformedAudioRate> (which is project-level, not per-file).
--
-- Domain behavior: a Premiere Media with an <AudioStream ObjectRef="N"/>
-- must resolve that stream to its real metadata:
--   - sample_rate = TICKS_PER_SECOND / AudioStream.FrameRate
--   - channels   = length of AudioStream.AudioChannelLayout
-- A Media without an <AudioStream> must produce audio_channels=0 and
-- audio_sample_rate=nil — claiming channels where none exist forces
-- downstream (ensure_masterclip) to create audio tracks for a silent file.

require("test_env")

local prproj = require("importers.prproj_importer")

print("=== test_prproj_audio_stream.lua ===")

-- Minimal element tree matching what qt_xml_parse produces.
local function elem(tag, attrs, children_or_text)
    local e = { tag = tag, attrs = attrs or {}, children = {} }
    if type(children_or_text) == "string" then
        e.text = children_or_text
    elseif type(children_or_text) == "table" then
        e.children = children_or_text
    end
    return e
end

local function text_child(tag, text)
    return elem(tag, {}, text)
end

-- ─────────────────────────────────────────────────────────────────────
-- Happy path: A/V media at 48kHz stereo. AudioStream carries the
-- authoritative sample rate (via FrameRate = TICKS_PER_SECOND / SR)
-- and channel count (via AudioChannelLayout JSON length).
-- ─────────────────────────────────────────────────────────────────────
local TICKS_PER_SECOND = prproj.TICKS_PER_SECOND
local SR_48K_TICKS = TICKS_PER_SECOND / 48000  -- 5292000
local SR_44K1_TICKS = math.floor(TICKS_PER_SECOND / 44100 + 0.5)

local audio_stream_48k_stereo = elem("AudioStream", { ObjectID = "1001" }, {
    text_child("AudioChannelLayout", '[{"channellabel":100},{"channellabel":101}]'),
    text_child("FrameRate", tostring(SR_48K_TICKS)),
})
local video_stream = elem("VideoStream", { ObjectID = "1002" }, {})

local media_av = elem("Media", { ObjectUID = "uuid-av" }, {
    text_child("FilePath", "/clips/av.mov"),
    text_child("Title", "av.mov"),
    elem("AudioStream", { ObjectRef = "1001" }),
    elem("VideoStream", { ObjectRef = "1002" }),
})

local by_id = { [1001] = audio_stream_48k_stereo, [1002] = video_stream }

local item = prproj._parse_media_element(media_av, by_id)
assert(item, "A/V media should parse")
assert(item.audio_sample_rate == 48000, string.format(
    "A/V: audio_sample_rate must come from AudioStream.FrameRate (48000), got %s",
    tostring(item.audio_sample_rate)))
assert(item.audio_channels == 2, string.format(
    "A/V: audio_channels must come from AudioChannelLayout (2 labels = 2), got %s",
    tostring(item.audio_channels)))
print(string.format("  ✓ A/V @ 48kHz stereo: rate=%d, channels=%d",
    item.audio_sample_rate, item.audio_channels))

-- ─────────────────────────────────────────────────────────────────────
-- 44.1kHz mono: proves the values are read, not hardcoded.
-- ─────────────────────────────────────────────────────────────────────
local audio_stream_441_mono = elem("AudioStream", { ObjectID = "2001" }, {
    text_child("AudioChannelLayout", '[{"channellabel":100}]'),
    text_child("FrameRate", tostring(SR_44K1_TICKS)),
})
local media_av_441 = elem("Media", { ObjectUID = "uuid-av-441" }, {
    text_child("FilePath", "/clips/av_441.wav"),
    elem("AudioStream", { ObjectRef = "2001" }),
})

local item_441 = prproj._parse_media_element(media_av_441, { [2001] = audio_stream_441_mono })
assert(item_441.audio_sample_rate == 44100, string.format(
    "44.1k mono: expected 44100, got %s", tostring(item_441.audio_sample_rate)))
assert(item_441.audio_channels == 1, string.format(
    "44.1k mono: expected 1 channel, got %s", tostring(item_441.audio_channels)))
print(string.format("  ✓ Mono @ 44.1kHz: rate=%d, channels=%d",
    item_441.audio_sample_rate, item_441.audio_channels))

-- ─────────────────────────────────────────────────────────────────────
-- Video-only media: no AudioStream. Must report audio_channels=0 and
-- audio_sample_rate=nil. A silent default of 2 channels would force
-- downstream consumers to create audio tracks for a file with no audio.
-- ─────────────────────────────────────────────────────────────────────
local media_video_only = elem("Media", { ObjectUID = "uuid-vo" }, {
    text_child("FilePath", "/clips/silent.mov"),
    elem("VideoStream", { ObjectRef = "1002" }),
})

local item_vo = prproj._parse_media_element(media_video_only, { [1002] = video_stream })
assert(item_vo.audio_channels == 0, string.format(
    "video-only: audio_channels must be 0 (no AudioStream), got %s",
    tostring(item_vo.audio_channels)))
assert(item_vo.audio_sample_rate == nil, string.format(
    "video-only: audio_sample_rate must be nil, got %s",
    tostring(item_vo.audio_sample_rate)))
print("  ✓ Video-only: no audio channels, no sample rate")

print("\n✅ test_prproj_audio_stream.lua passed")
