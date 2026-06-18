#!/usr/bin/env luajit
-- Black-box test: DRP SampleOffset is a SIGNED int64.
--
-- Domain / ground truth: a dual-system audio SampleOffset is the WAV sample
-- that plays under the camera's first video frame. When the field recorder
-- started AFTER the camera (free-run TC), the sync point lands before the
-- WAV's first sample, so the value is NEGATIVE. In big-endian two's-complement
-- a negative int64 has its high bit set; reading it as UNSIGNED yields a value
-- near 2^64 (e.g. the anamnesis fixture's -1,425,408 reads as
-- 18,446,744,073,708,126,208), which corrupts every downstream sync/extent
-- computation.
--
-- read_be64 stays UNSIGNED (it also decodes positive counts like Duration);
-- read_be64_signed is the signed reader used on the SampleOffset path.

require("test_env")

local drp = require("importers.drp_binary")

-- Encode an unsigned 64-bit value (given as hi/lo 32-bit halves) big-endian.
local function be64(hi, lo)
    local function be32(n)
        return string.char(
            math.floor(n / 16777216) % 256,
            math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256,
            n % 256)
    end
    return be32(hi) .. be32(lo)
end

-- The exact anamnesis case: SampleOffset = -1,425,408 samples (recorder started
-- ~29.7s before the camera). Two's-complement 64-bit = 2^64 - 1425408, i.e.
-- hi = 0xFFFFFFFF, lo = 2^32 - 1425408.
local N = 1425408
local neg_bytes = be64(0xFFFFFFFF, 4294967296 - N)

-- Unsigned reader: contract preserved — high bit set reads as ~2^64.
local u = drp.read_be64(neg_bytes, 1)
assert(u > 2 ^ 63, string.format(
    "read_be64 must stay unsigned: high-bit value should read >= 2^63, got %s",
    tostring(u)))

-- Signed reader: the same bytes are the negative offset -1,425,408 EXACTLY.
-- (Exactness matters: a sample offset off by even a few hundred samples is an
-- audible sync error. Sign-extending the high word keeps |result| < 2^53 so
-- the result is exact, unlike subtracting 2^64 from an already-rounded ~2^64.)
local s = drp.read_be64_signed(neg_bytes, 1)
assert(s == -N, string.format(
    "read_be64_signed must decode the negative offset exactly: expected %d, got %s",
    -N, tostring(s)))
print("  PASS: negative SampleOffset decodes to the exact signed value")

-- A non-negative offset (recorder started before the camera, or TC-aligned)
-- decodes identically under both readers.
local pos_bytes = be64(0, 96000)  -- +2 s @ 48k
assert(drp.read_be64(pos_bytes, 1) == 96000, "read_be64 positive mismatch")
assert(drp.read_be64_signed(pos_bytes, 1) == 96000,
    "read_be64_signed must agree with read_be64 on non-negative values")
print("  PASS: non-negative offset identical under both readers")

-- Out-of-bounds returns nil (decode failure, never asserts — caller decides).
assert(drp.read_be64_signed("\1\2\3", 1) == nil,
    "read_be64_signed must return nil when the value runs past the buffer")
print("  PASS: short buffer returns nil")

print("✅ test_drp_binary_signed_offset.lua passed")
