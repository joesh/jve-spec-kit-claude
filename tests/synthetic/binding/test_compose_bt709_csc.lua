-- BT.709 YCbCr→RGB matrix regression — qt_compose_bt709_csc binding
-- (run via `jve --test`).
--
-- Black-box: feeds well-documented CVPixelBuffer FourCC pixel formats
-- into the matrix composer and asserts each row matches the BT.709
-- standard math. Expected values are derived from ITU-R BT.709-6
-- §3 (RGB-to-YCbCr conversion) inverted to YCbCr-to-RGB:
--
--   Full-range (chroma centered at 0.5, Y in [0,1]):
--     R = Y                + 1.5748·(Cr - 0.5)
--     G = Y - 0.1873·(Cb-0.5) - 0.4681·(Cr-0.5)
--     B = Y + 1.8556·(Cb-0.5)
--
--   Limited-range (Y in [16,235]/255, C centered at 128/255 with
--   extents [16,240]/255):
--     pre-scale  Y' = (Y - 16/255) · 255/219    -- Y_scale = 1.16438
--                C' = (C - 128/255) · 255/224   -- C_scale = 1.13839
--     then apply the full-range formulas to (Y', Cb', Cr')
--
-- Both reduce to a 3x4 affine matrix (Y, Cb, Cr, constant). Reference
-- coefficients below are computed from the standard, NOT read out of
-- src/gpu_video_surface.mm — derived-from-the-implementation would
-- only verify that the code does what the code does.
--
-- Format/range coverage (one well-documented FourCC per range family):
--   '420v' biplanar 4:2:0 8-bit video range   → limited
--   '420f' biplanar 4:2:0 8-bit full range    → full
--   'x422' biplanar 4:2:2 10-bit video range  → limited
--   'y416' packed 4444AYpCbCr16               → full (per Apple spec)
-- Formats without a publicly-documented FourCC (e.g. sv44 16-bit
-- biplanar 4:4:4) are exercised by real-media integration tests,
-- not here — coverage is by range family, which is what the matrix
-- branches on.

assert(type(qt_compose_bt709_csc) == "function",
    "qt_compose_bt709_csc binding not registered")

-- Compose a CVPixelBuffer FourCC integer from a 4-char ASCII string.
-- Matches Apple's convention: byte 0 is the MSB.
local function fourcc(s)
    assert(#s == 4, "fourcc: need exactly 4 chars, got " .. tostring(#s))
    return s:byte(1) * 0x1000000
         + s:byte(2) * 0x10000
         + s:byte(3) * 0x100
         + s:byte(4)
end

-- BT.709 derivation. Sourced from the standard, not the .mm file.
local KrR_full = 1.5748
local KgB_full = 0.1873
local KgR_full = 0.4681
local KbB_full = 1.8556
local Y_scale_lim = 255 / 219                                -- ≈ 1.16438
local C_scale_lim = 255 / 224                                -- ≈ 1.13839
local Y_offset    = 16 / 255                                 -- ≈ 0.06275
local C_offset    = 128 / 255                                -- ≈ 0.50196

-- Full-range BT.709 affine (Y, Cb, Cr, const).
local function expected_full()
    return {
        {1.0,  0.0,         KrR_full, -KrR_full * 0.5},
        {1.0, -KgB_full,   -KgR_full,  (KgB_full + KgR_full) * 0.5},
        {1.0,  KbB_full,    0.0,      -KbB_full * 0.5},
    }
end

-- Limited-range BT.709 affine. Pre-scaling Y and C folds into the
-- linear coefficients; the chroma -128/255 offsets and Y -16/255
-- offset fold into the constant column.
local function expected_limited()
    local Cb_g = -KgB_full * C_scale_lim
    local Cr_g = -KgR_full * C_scale_lim
    local Cb_b =  KbB_full * C_scale_lim
    local Cr_r =  KrR_full * C_scale_lim
    return {
        {Y_scale_lim, 0.0,  Cr_r,
            -Y_scale_lim * Y_offset - Cr_r * C_offset},
        {Y_scale_lim, Cb_g, Cr_g,
            -Y_scale_lim * Y_offset - (Cb_g + Cr_g) * C_offset},
        {Y_scale_lim, Cb_b, 0.0,
            -Y_scale_lim * Y_offset - Cb_b * C_offset},
    }
end

local TOL = 1e-3  -- per-coefficient. Implementation rounds 5 sig fig;
                  -- standard derivation rounds 4. Engineering tolerance.

local function check_matrix(label, fmt_fourcc, expected)
    local r0, r1, r2, r3,
          g0, g1, g2, g3,
          b0, b1, b2, b3 = qt_compose_bt709_csc(fourcc(fmt_fourcc))
    local got = {
        {r0, r1, r2, r3},
        {g0, g1, g2, g3},
        {b0, b1, b2, b3},
    }
    for row = 1, 3 do
        for col = 1, 4 do
            local diff = math.abs(got[row][col] - expected[row][col])
            assert(diff < TOL, string.format(
                "%s row %d col %d: got %.6f, expected %.6f (diff %.6f > %g)",
                label, row, col, got[row][col], expected[row][col], diff, TOL))
        end
    end
end

-- Format → range mapping per the BT.709 affine selected by
-- composeBt709Csc's switch:
check_matrix("420v (4:2:0 8-bit video range)",     "420v", expected_limited())
check_matrix("420f (4:2:0 8-bit full range)",      "420f", expected_full())
check_matrix("x422 (4:2:2 10-bit video range)",    "x422", expected_limited())
check_matrix("y416 (packed 4444AYpCbCr16 full)",   "y416", expected_full())

print("test_compose_bt709_csc.lua passed")
