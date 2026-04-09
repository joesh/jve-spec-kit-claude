#!/usr/bin/env luajit
-- Generate a test WAV file with known audio content for waveform alignment tests.
-- Output: tests/fixtures/media/test_tone_48k_stereo.wav
-- Content: 2 seconds of 440Hz sine wave at full scale, stereo, 48kHz, 16-bit PCM.
-- The sine wave creates predictable peak values for each 256-sample bin.

local SAMPLE_RATE = 48000
local CHANNELS = 2
local DURATION_SECS = 2
local FREQ = 440
local BITS_PER_SAMPLE = 16
local TOTAL_SAMPLES = SAMPLE_RATE * DURATION_SECS

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
local output_path = script_dir .. "/test_tone_48k_stereo.wav"

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

-- RIFF header
f:write("RIFF")
write_le32(f, file_size)
f:write("WAVE")

-- fmt chunk
f:write("fmt ")
write_le32(f, 16)  -- chunk size
write_le16(f, 1)   -- PCM format
write_le16(f, CHANNELS)
write_le32(f, SAMPLE_RATE)
write_le32(f, SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8)  -- byte rate
write_le16(f, CHANNELS * BITS_PER_SAMPLE / 8)  -- block align
write_le16(f, BITS_PER_SAMPLE)

-- data chunk
f:write("data")
write_le32(f, data_size)

for s = 0, TOTAL_SAMPLES - 1 do
    local t = s / SAMPLE_RATE
    local val = math.sin(2 * math.pi * FREQ * t)
    local int16 = math.floor(val * 32767 + 0.5)
    if int16 > 32767 then int16 = 32767 end
    if int16 < -32768 then int16 = -32768 end
    -- Write same value for both channels (mono content in stereo container)
    for _ = 1, CHANNELS do
        write_le16(f, int16)
    end
end

f:close()
print("Generated: " .. output_path)
print(string.format("  %d Hz, %d ch, %d samples (%.1fs), %d-bit PCM",
    SAMPLE_RATE, CHANNELS, TOTAL_SAMPLES, DURATION_SECS, BITS_PER_SAMPLE))
