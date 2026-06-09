-- Diagnostic: where does the decoded audio actually place the click?
-- Decodes small ranges around sample 48000 and prints actual values.

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

local MEDIA_PATH = env.test_media_path("test_click_48k_stereo.wav")
local mf = assert(EMP.MEDIA_FILE_OPEN(MEDIA_PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
local SR = info.audio_sample_rate
local CH = info.audio_channels

print(string.format("sr=%d ch=%d duration=%dus", SR, CH, info.duration_us))

-- Decode the ENTIRE file in one call — same as peak generator does
local reader = assert(EMP.READER_CREATE(mf))
local pcm = assert(EMP.READER_DECODE_AUDIO_RANGE(reader, 0, SR * 3, SR, 1, SR, CH))
local pi = EMP.PCM_INFO(pcm)
print(string.format("decoded %d frames, start_time_us=%d", pi.frames, pi.start_time_us))

local samples = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))

-- Print samples around the expected click boundary (sample 48000)
print("\nSamples around expected click at 48000:")
for s = 47990, 48010 do
    if s >= 0 and s < pi.frames then
        print(string.format("  sample[%d] ch0=%.6f ch1=%.6f", s,
            samples[s * CH], samples[s * CH + 1]))
    end
end

-- Print samples around expected click end (48256)
print("\nSamples around expected click end at 48256:")
for s = 48250, 48265 do
    if s >= 0 and s < pi.frames then
        print(string.format("  sample[%d] ch0=%.6f ch1=%.6f", s,
            samples[s * CH], samples[s * CH + 1]))
    end
end

-- Find actual first non-zero sample
local first_nonzero = nil
for s = 0, pi.frames - 1 do
    if math.abs(samples[s * CH]) > 0.001 then
        first_nonzero = s
        break
    end
end
print(string.format("\nFirst non-zero sample: %d (expected 48000)", first_nonzero or -1))

-- Find actual last non-zero sample
local last_nonzero = nil
for s = pi.frames - 1, 0, -1 do
    if math.abs(samples[s * CH]) > 0.001 then
        last_nonzero = s
        break
    end
end
print(string.format("Last non-zero sample: %d (expected 48255)", last_nonzero or -1))
print(string.format("Click duration: %d samples (expected 256)", (last_nonzero or 0) - (first_nonzero or 0) + 1))

EMP.PCM_RELEASE(pcm)
EMP.READER_CLOSE(reader)
EMP.MEDIA_FILE_CLOSE(mf)
