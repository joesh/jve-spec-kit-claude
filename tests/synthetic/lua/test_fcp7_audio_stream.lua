-- Regression: FCP7 XML importer must extract the audio sample rate from
-- the <file> element's <audio><samplecharacteristics><samplerate> tag,
-- not leave it unset. Downstream consumers (waveform peak cache,
-- ensure_masterclip) need a real rate on every audio-bearing media.
--
-- Domain behavior (per FCP7 XMEML format):
--   <file>
--     <media>
--       <audio>
--         <samplecharacteristics>
--           <samplerate>48000</samplerate>
--           <depth>16</depth>
--         </samplecharacteristics>
--         <channelcount>2</channelcount>
--       </audio>
--     </media>
--   </file>
-- must produce media_info.audio_sample_rate = 48000, audio_channels = 2.
-- A <file> without an <audio> block must produce audio_channels = 0 and
-- audio_sample_rate = nil (no audio → no claim of one).

require("test_env")

local fcp7 = require("importers.fcp7_xml_importer")

print("=== test_fcp7_audio_stream.lua ===")

local function elem(tag, attrs, children_or_text)
    local e = { tag = tag, attrs = attrs or {}, children = {} }
    if type(children_or_text) == "string" then
        e.text = children_or_text
    elseif type(children_or_text) == "table" then
        e.children = children_or_text
    end
    return e
end
local function text(tag, t) return elem(tag, {}, t) end

-- ─────────────────────────────────────────────────────────────────────
-- A/V file at 48kHz stereo — the authoritative samplerate is inside the
-- audio stream's <samplecharacteristics>, and channel count from
-- <channelcount>.
-- ─────────────────────────────────────────────────────────────────────
local av_file = elem("file", { id = "f1" }, {
    text("name", "av.mov"),
    text("pathurl", "file:///clips/av.mov"),
    text("duration", "240"),
    elem("media", {}, {
        elem("video", {}, {
            elem("samplecharacteristics", {}, {
                text("width", "1920"),
                text("height", "1080"),
            }),
        }),
        elem("audio", {}, {
            elem("samplecharacteristics", {}, {
                text("samplerate", "48000"),
                text("depth", "16"),
            }),
            text("channelcount", "2"),
        }),
    }),
})

local info = fcp7._parse_file(av_file, 24)
assert(info, "parse_file should return info")
assert(info.audio_sample_rate == 48000, string.format(
    "A/V: audio_sample_rate must be 48000 from samplecharacteristics, got %s",
    tostring(info.audio_sample_rate)))
assert(info.audio_channels == 2, string.format(
    "A/V: audio_channels must be 2, got %s", tostring(info.audio_channels)))
print(string.format("  ✓ A/V @ 48k stereo: rate=%d, channels=%d",
    info.audio_sample_rate, info.audio_channels))

-- ─────────────────────────────────────────────────────────────────────
-- 44.1k mono proves values come from the XML, not hardcoded defaults.
-- ─────────────────────────────────────────────────────────────────────
local av_441_file = elem("file", { id = "f2" }, {
    text("name", "av_441.mov"),
    text("pathurl", "file:///clips/av_441.mov"),
    text("duration", "240"),
    elem("media", {}, {
        elem("audio", {}, {
            elem("samplecharacteristics", {}, {
                text("samplerate", "44100"),
            }),
            text("channelcount", "1"),
        }),
    }),
})
local info_441 = fcp7._parse_file(av_441_file, 24)
assert(info_441.audio_sample_rate == 44100 and info_441.audio_channels == 1,
    string.format("44.1k mono: got rate=%s channels=%s",
        tostring(info_441.audio_sample_rate), tostring(info_441.audio_channels)))
print(string.format("  ✓ Mono @ 44.1k: rate=%d, channels=%d",
    info_441.audio_sample_rate, info_441.audio_channels))

-- ─────────────────────────────────────────────────────────────────────
-- Video-only file: no <audio> block. Must report audio_channels=0 and
-- audio_sample_rate=nil, not fabricate an audio stream.
-- ─────────────────────────────────────────────────────────────────────
local vo_file = elem("file", { id = "f3" }, {
    text("name", "silent.mov"),
    text("pathurl", "file:///clips/silent.mov"),
    text("duration", "100"),
    elem("media", {}, {
        elem("video", {}, {
            elem("samplecharacteristics", {}, {
                text("width", "1920"),
                text("height", "1080"),
            }),
        }),
    }),
})
local info_vo = fcp7._parse_file(vo_file, 24)
assert(info_vo.audio_channels == 0, string.format(
    "video-only: audio_channels must be 0, got %s", tostring(info_vo.audio_channels)))
assert(info_vo.audio_sample_rate == nil, string.format(
    "video-only: audio_sample_rate must be nil, got %s",
    tostring(info_vo.audio_sample_rate)))
print("  ✓ Video-only: no audio channels, no sample rate")

-- ─────────────────────────────────────────────────────────────────────
-- Audio-only file (WAV, AIFF): no <video> block. Must report
-- width=0 and height=0 so downstream `has_video = width > 0` treats
-- it correctly. A defaulted 1920x1080 would fabricate a video stream.
-- ─────────────────────────────────────────────────────────────────────
local ao_file = elem("file", { id = "f4" }, {
    text("name", "music.wav"),
    text("pathurl", "file:///clips/music.wav"),
    text("duration", "48000"),
    elem("media", {}, {
        elem("audio", {}, {
            elem("samplecharacteristics", {}, {
                text("samplerate", "48000"),
            }),
            text("channelcount", "2"),
        }),
    }),
})
local info_ao = fcp7._parse_file(ao_file, 24)
assert(info_ao.width == 0, string.format(
    "audio-only: width must be 0 (no <video>), got %s", tostring(info_ao.width)))
assert(info_ao.height == 0, string.format(
    "audio-only: height must be 0, got %s", tostring(info_ao.height)))
assert(info_ao.audio_channels == 2 and info_ao.audio_sample_rate == 48000,
    "audio-only: audio fields still populated")
print("  ✓ Audio-only: width=0, height=0 (no video fabricated)")

-- ─────────────────────────────────────────────────────────────────────
-- extract_frame_rate: a <rate> element with no <timebase> child, or
-- with un-parseable timebase text, must NOT silently default to 30.0.
-- A fabricated frame rate would corrupt every subsequent tick→frame
-- conversion for this file/clip.
-- ─────────────────────────────────────────────────────────────────────
local rate_missing_timebase = elem("rate", {}, {
    text("ntsc", "FALSE"),
})
local ok, err = pcall(fcp7._extract_frame_rate, rate_missing_timebase)
assert(not ok, "extract_frame_rate must fail when <timebase> is missing")
assert(tostring(err):match("timebase"),
    "assert message must identify the missing timebase: " .. tostring(err))
print("  ✓ <rate> missing <timebase> → assert (no silent 30.0)")

local rate_bad_timebase = elem("rate", {}, {
    text("timebase", "not a number"),
})
local ok2, err2 = pcall(fcp7._extract_frame_rate, rate_bad_timebase)
assert(not ok2, "extract_frame_rate must fail on malformed timebase text")
assert(tostring(err2):match("timebase"),
    "assert message should identify the bad timebase: " .. tostring(err2))
print("  ✓ <timebase> un-parseable → assert")

print("\n✅ test_fcp7_audio_stream.lua passed")
