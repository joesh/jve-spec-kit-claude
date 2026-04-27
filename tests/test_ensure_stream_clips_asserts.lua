#!/usr/bin/env luajit
--- ensure_stream_clips must fail loud on malformed master sequences.
-- Hardening from the project_browser orphan-master crash class:
-- previously, a master sequence missing frame_rate or audio_sample_rate
-- silently produced stub-with-nil-fields rate tables that crashed
-- consumers later. Now the constructor asserts at the source.
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

-- Build a master-sequence-shaped object directly (bypassing DB) so we can
-- omit fields that the schema would normally require.
local function fake_master(opts)
    local self = {
        id = "fake-master",
        kind = "master",
        frame_rate = opts.frame_rate,
        fps_numerator = opts.fps_numerator,
        fps_denominator = opts.fps_denominator,
        audio_sample_rate = opts.audio_sample_rate,
    }
    return setmetatable(self, { __index = Sequence })
end

expect_error("missing frame_rate fails loud", function()
    local s = fake_master({ audio_sample_rate = 48000 })
    s:video_stream()
end, "missing frame_rate")

expect_error("missing audio_sample_rate fails loud", function()
    local s = fake_master({
        frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    })
    s:audio_streams()
end, "missing audio_sample_rate")

expect_error("zero audio_sample_rate fails loud", function()
    local s = fake_master({
        frame_rate = { fps_numerator = 24, fps_denominator = 1 },
        audio_sample_rate = 0,
    })
    s:audio_streams()
end, "missing audio_sample_rate")

print("\n✅ test_ensure_stream_clips_asserts.lua passed")
