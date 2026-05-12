#!/usr/bin/env luajit
--- Sequence model audio_sample_rate / frame_rate fail-fast contract.
-- Schema permits NULL audio_sample_rate ONLY on kind='master' (where the
-- master happens to source video-only media). Everywhere else a positive
-- rate is required. The constructor and writer must enforce both rules.
require("test_env")

print("=== test_ensure_stream_clips_asserts.lua ===")

local Sequence = require("models.sequence")

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected error, got success")
    assert(tostring(err):match(pattern),
        string.format("%s: error %q must match %q", label, tostring(err), pattern))
    print(string.format("  ✓ %s", label))
end

local FR = { fps_numerator = 24, fps_denominator = 1 }

-- ensure_stream_clips on a master fake without frame_rate must fail loud.
local function fake_master(opts)
    local self = {
        id = "fake-master",
        kind = "master",
        frame_rate = opts.frame_rate,
        audio_sample_rate = opts.audio_sample_rate,
    }
    return setmetatable(self, { __index = Sequence })
end

expect_error("missing frame_rate fails loud", function()
    local s = fake_master({ audio_sample_rate = 48000 })
    s:video_stream()
end, "missing frame_rate")

-- Sequence.create: nested timelines REQUIRE audio_sample_rate.
expect_error("nested sequence without audio_sample_rate refused", function()
    Sequence.create("e", "p1", FR, 1920, 1080,
        { id = "e", kind = "sequence" })
end, "audio_sample_rate is required for non%-master")

-- Sequence.create: zero/negative audio_sample_rate is rejected even on master.
expect_error("master with zero audio_sample_rate refused", function()
    Sequence.create("m", "p1", FR, 1920, 1080,
        { id = "m", kind = "master", audio_sample_rate = 0 })
end, "audio_sample_rate must be a positive number")

-- Sequence.create: master may carry NULL audio_sample_rate (video-only).
do
    local s = Sequence.create("m", "p1", FR, 1920, 1080,
        { id = "m", kind = "master" })  -- audio_sample_rate omitted (nil)
    assert(s, "master without audio_sample_rate constructed (video-only allowed)")
    assert(s.audio_sample_rate == nil,
        "video-only master keeps NULL rate; got " .. tostring(s.audio_sample_rate))
    print("  ✓ video-only master accepts NULL audio_sample_rate")
end

print("\n✅ test_ensure_stream_clips_asserts.lua passed")
