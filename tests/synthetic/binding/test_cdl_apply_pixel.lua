-- T032 CDL math regression — qt_cdl_apply_pixel binding (run via `jve --test`).
--
-- Black-box: feeds a known linear RGB pixel + a known CDL primary through
-- the CPU-side CDL function (the same code path the CPU video surface uses,
-- and the math the Metal shader mirrors). Expected outputs are derived from
-- the ASC CDL standard S-2014-009-01:
--
--   sop  = max(in_rgb * slope + offset, 0)
--   cdl  = sop ^ power
--   luma = dot(cdl, [0.2126, 0.7152, 0.0722])           -- BT.709
--   out  = saturate(luma + (cdl - luma) * saturation)   -- clamp to [0,1]
--
-- Reference values are computed from that math against the non-trivial CDL
-- in specs/023-resolve-color-bridge/data-model.md §107
--   slope  (1.05, 0.98, 0.92)
--   offset (0.01, 0.00, -0.02)
--   power  (1.10, 1.00,  0.95)
--   sat    0.85
-- and a couple of corner cases (identity grade, negative-clamp pre-pow,
-- saturate clamp on top end). NOT derived by tracing the implementation.

assert(type(qt_cdl_apply_pixel) == "function",
    "qt_cdl_apply_pixel binding not registered")

-- The data-model CDL.
local CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r = 1.10, power_g = 1.00, power_b = 0.95,
    saturation = 0.85,
}

local function approx(a, b, eps)
    eps = eps or 1e-4
    return math.abs(a - b) <= eps
end

local function assert_pixel(label, r, g, b, ex_r, ex_g, ex_b)
    local or_, og, ob = qt_cdl_apply_pixel(r, g, b,
        CDL.slope_r, CDL.slope_g, CDL.slope_b,
        CDL.offset_r, CDL.offset_g, CDL.offset_b,
        CDL.power_r, CDL.power_g, CDL.power_b,
        CDL.saturation)
    assert(approx(or_, ex_r) and approx(og, ex_g) and approx(ob, ex_b),
        string.format("%s: got (%.6f, %.6f, %.6f), want (%.6f, %.6f, %.6f)",
            label, or_, og, ob, ex_r, ex_g, ex_b))
    print(string.format("  ✓ %s — (%.3f,%.3f,%.3f) → (%.4f,%.4f,%.4f)",
        label, r, g, b, or_, og, ob))
end

-- Expected values are produced by evaluating the ASC formula above in
-- double-precision Python (not by running the implementation). The
-- comments show the math; the numeric expected is the formula's
-- output. If the impl drifts from the formula, the comparison fails;
-- if the formula here is wrong, the numeric and the comment disagree.

-- Case 1: mid-gray input (0.5, 0.5, 0.5)
--   sop   = (0.5*1.05+0.01,         0.5*0.98+0.0,    0.5*0.92-0.02)
--         = (0.535,                 0.49,            0.44)
--   cdl   = (0.535^1.10,            0.49^1.00,       0.44^0.95)
--   luma  = 0.2126*cdl_r + 0.7152*cdl_g + 0.0722*cdl_b
--   out   = saturate(luma + (cdl - luma) * 0.85)
assert_pixel("mid-gray data-model CDL", 0.5, 0.5, 0.5,
    0.500736, 0.490059, 0.463231)

-- Case 2: full white input (1.0, 1.0, 1.0) — exercises saturate top-clamp
--   sop   = (1.06, 0.98, 0.90)
--   cdl   = (1.06^1.10 > 1, 0.98, 0.90^0.95)
--   out_r before saturate is > 1.0; saturate clamps to exactly 1.0.
assert_pixel("full-white data-model CDL", 1.0, 1.0, 1.0,
    1.0, 0.981934, 0.917975)

-- Case 3: black input (0,0,0) — exercises offset + negative-clamp before pow
--   sop   = (0.01, 0.0, max(-0.02, 0) = 0.0)        ← NEGATIVE-CLAMP gate
--   cdl   = (0.01^1.10, 0.0, 0.0)
--   tiny luma; out_g and out_b nearly zero but not negative.
assert_pixel("black + negative-clamp", 0.0, 0.0, 0.0,
    0.005564, 0.000201, 0.000201)

-- Case 4: identity CDL (slope=1, offset=0, power=1, sat=1) → passthrough.
local IDENTITY = {
    slope_r = 1, slope_g = 1, slope_b = 1,
    offset_r = 0, offset_g = 0, offset_b = 0,
    power_r = 1, power_g = 1, power_b = 1,
    saturation = 1,
}
local r, g, b = qt_cdl_apply_pixel(0.3, 0.6, 0.9,
    IDENTITY.slope_r, IDENTITY.slope_g, IDENTITY.slope_b,
    IDENTITY.offset_r, IDENTITY.offset_g, IDENTITY.offset_b,
    IDENTITY.power_r, IDENTITY.power_g, IDENTITY.power_b,
    IDENTITY.saturation)
assert(approx(r, 0.3) and approx(g, 0.6) and approx(b, 0.9),
    string.format("identity CDL must passthrough: got (%.6f,%.6f,%.6f)", r, g, b))
print("  ✓ identity CDL passes through unchanged")

-- Case 5: sat=0 collapses to luma on all channels.
local r2, g2, b2 = qt_cdl_apply_pixel(0.2, 0.5, 0.8,
    1, 1, 1, 0, 0, 0, 1, 1, 1, 0.0)
--   luma = 0.2126*0.2 + 0.7152*0.5 + 0.0722*0.8 = 0.04252 + 0.3576 + 0.05776 = 0.45788
assert(approx(r2, 0.45788) and approx(g2, 0.45788) and approx(b2, 0.45788),
    string.format("sat=0 must collapse to luma: got (%.6f,%.6f,%.6f)", r2, g2, b2))
print("  ✓ saturation=0 collapses RGB to BT.709 luma")

print("✅ test_cdl_apply_pixel.lua passed")
