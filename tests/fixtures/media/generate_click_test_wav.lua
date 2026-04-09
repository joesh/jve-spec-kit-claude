#!/usr/bin/env luajit
-- Generate a test WAV with silence + click + silence pattern.
-- The click is at a known sample position so we can verify waveform alignment.
--
-- Layout (48kHz stereo, 3 seconds):
--   Samples 0..47999:       silence (1 second)
--   Samples 48000..48255:   LOUD CLICK (full-scale square pulse, 256 samples = 1 bin)
--   Samples 48256..143999:  silence (remaining ~2 seconds)

local SAMPLE_RATE = 48000
local CHANNELS = 2
local DURATION_SECS = 3
local BITS_PER_SAMPLE = 16
local TOTAL_SAMPLES = SAMPLE_RATE * DURATION_SECS

-- Click at exactly 1 second (sample 48000), lasting 256 samples (one peak bin)
local CLICK_START = 48000
local CLICK_END = 48000 + 256

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
local output_path = script_dir .. "/test_click_48k_stereo.wav"

local function write_le16(f, v)
    v = math.floor(v) % 65536
    f:write(string.char(v % 256, math.floor(v / 256) % 256))
end

local function write_le32(f, v)
    v = math.floor(v)
    f:write(string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256))
end

local data_size = TOTAL_SAMPLES * CHANNELS * (BITS_PER_SAMPLE / 8)
local file_size = 36 + data_size

local f = assert(io.open(output_path, "wb"))

f:write("RIFF")
write_le32(f, file_size)
f:write("WAVE")
f:write("fmt ")
write_le32(f, 16)
write_le16(f, 1)
write_le16(f, CHANNELS)
write_le32(f, SAMPLE_RATE)
write_le32(f, SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8)
write_le16(f, CHANNELS * BITS_PER_SAMPLE / 8)
write_le16(f, BITS_PER_SAMPLE)
f:write("data")
write_le32(f, data_size)

for s = 0, TOTAL_SAMPLES - 1 do
    local val = 0
    if s >= CLICK_START and s < CLICK_END then
        val = 32767  -- full-scale positive
    end
    for _ = 1, CHANNELS do
        write_le16(f, val)
    end
end

f:close()
print("Generated: " .. output_path)
print(string.format("  Click at samples %d..%d (%.3fs..%.3fs)",
    CLICK_START, CLICK_END, CLICK_START / SAMPLE_RATE, CLICK_END / SAMPLE_RATE))
