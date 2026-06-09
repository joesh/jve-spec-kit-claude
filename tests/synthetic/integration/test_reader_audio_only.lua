-- Reader::Create(audio_only=true) opens a media file without
-- initializing the video codec context. This avoids unnecessary work
-- (and unnecessary VideoToolbox init contention) for clients that only
-- need audio — chiefly PeakGenerator scanning audio-bearing video files.

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_reader_audio_only ---")

assert(type(EMP.READER_CREATE_AUDIO_ONLY) == "function",
    "READER_CREATE_AUDIO_ONLY binding required")
assert(type(EMP.READER_HAS_VIDEO_CODEC) == "function",
    "READER_HAS_VIDEO_CODEC binding required")

local PATH = env.test_media_path("A005_C052_0925BL_001.mp4")
local mf = assert(EMP.MEDIA_FILE_OPEN(PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_video, "test fixture must have video")
assert(info.has_audio, "test fixture must have audio")

-- Standard reader: video codec is initialized.
local std_reader = assert(EMP.READER_CREATE(mf))
assert(EMP.READER_HAS_VIDEO_CODEC(std_reader),
    "standard Reader::Create must initialize video codec for a video file")
EMP.READER_CLOSE(std_reader)

-- Audio-only reader: video codec is NOT initialized even though the
-- file contains video.
local mf2 = assert(EMP.MEDIA_FILE_OPEN(PATH))
local audio_reader = assert(EMP.READER_CREATE_AUDIO_ONLY(mf2))
assert(not EMP.READER_HAS_VIDEO_CODEC(audio_reader),
    "audio-only Reader must skip video codec initialization")

-- Audio decode must still work through the audio-only reader.
local SR = info.audio_sample_rate
local pcm = assert(EMP.READER_DECODE_AUDIO_RANGE(audio_reader,
    0, SR,         -- frame0..frame1 (1 second of audio)
    SR, 1,         -- frame rate (samples per second / 1)
    SR, info.audio_channels))
local pcm_info = EMP.PCM_INFO(pcm)
assert(pcm_info.frames > 0,
    "audio-only reader must decode audio frames; got " .. tostring(pcm_info.frames))

EMP.READER_CLOSE(audio_reader)

print(string.format("  decoded %d audio frames via audio-only reader", pcm_info.frames))
print("✅ test_reader_audio_only passed")
