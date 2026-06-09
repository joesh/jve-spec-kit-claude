-- Piece 3.1 LUT3D math regression — qt_lut3d_parse_string + apply_pixel
-- (run via `jve --test`). Pure black-box: every expected value is
-- derived from the Adobe Cube LUT v1.0 spec and the standard
-- trilinear-interpolation formula, NOT by tracing the implementation.
--
-- The Adobe spec fixes:
--   • R varies fastest in the body, then G, then B
--   • domain defaults [0,1] when DOMAIN_MIN/MAX absent
--   • out-of-domain input is clamped to the domain (consensus across
--     OCIO, ffmpeg lut3d; the spec leaves it implicit)
--
-- Trilinear interp of a 3D LUT at normalized (nx,ny,nz) ∈ [0,1]^3 with
-- grid size N is the standard convex combination of the 8 surrounding
-- grid samples weighted by (1-tx,tx) × (1-ty,ty) × (1-tz,tz) where
-- t* = N*n* - floor(N*n*).
--
-- The cube fixtures here are constructed so that the expected outputs
-- fall out analytically (identity, channel-swap, half-scale, R-invert),
-- not by reading the C++.

assert(type(qt_lut3d_parse_string) == "function",
    "qt_lut3d_parse_string binding not registered")
assert(type(qt_lut3d_apply_pixel) == "function",
    "qt_lut3d_apply_pixel binding not registered")
assert(type(qt_lut3d_free) == "function",
    "qt_lut3d_free binding not registered")

local function approx(a, b, eps)
    eps = eps or 1e-5
    return math.abs(a - b) <= eps
end

local function assert_pixel(label, h, r, g, b, ex_r, ex_g, ex_b)
    local or_, og, ob = qt_lut3d_apply_pixel(h, r, g, b)
    assert(approx(or_, ex_r) and approx(og, ex_g) and approx(ob, ex_b),
        string.format(
            "%s: expected (%.4f, %.4f, %.4f), got (%.4f, %.4f, %.4f)",
            label, ex_r, ex_g, ex_b, or_, og, ob))
end

local pass, fail = 0, 0
local function ok(label, cond, msg)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label .. (msg and (" — " .. msg) or "")) end
end

print("\n=== LUT3D apply (Piece 3.1) ===")

-- Helpers to build .cube text bodies. R fastest, then G, then B.
local function build_cube(size, gen)
    local lines = { "LUT_3D_SIZE " .. tostring(size) }
    for bi = 0, size - 1 do
        for gi = 0, size - 1 do
            for ri = 0, size - 1 do
                local r, g, b = gen(ri / (size - 1),
                                    gi / (size - 1),
                                    bi / (size - 1))
                lines[#lines + 1] = string.format("%.6f %.6f %.6f", r, g, b)
            end
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

-- ── Fixture 1: identity LUT, size 2 ─────────────────────────────────
-- Every output equals its input. Trilinear of corners 0/1 at any
-- (r,g,b) yields (r,g,b) exactly.
local id_cube = build_cube(2, function(r, g, b) return r, g, b end)
local h_id, err = qt_lut3d_parse_string(id_cube)
ok("identity parse", h_id ~= nil and err == nil,
    err and ("err=" .. err) or nil)
if h_id then
    assert_pixel("identity (0,0,0)",       h_id, 0, 0, 0, 0, 0, 0); pass = pass + 1
    assert_pixel("identity (1,1,1)",       h_id, 1, 1, 1, 1, 1, 1); pass = pass + 1
    assert_pixel("identity midpoint",      h_id, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5); pass = pass + 1
    assert_pixel("identity (0.27, 0.81, 0.13)",
        h_id, 0.27, 0.81, 0.13, 0.27, 0.81, 0.13); pass = pass + 1
    qt_lut3d_free(h_id)
end

-- ── Fixture 2: R↔B channel swap, size 2 ─────────────────────────────
-- Each grid sample emits (b, g, r). Trilinear should preserve the
-- swap at any input since the transform is per-axis affine.
local swap_cube = build_cube(2, function(r, g, b) return b, g, r end)
local h_swap = qt_lut3d_parse_string(swap_cube)
ok("R<->B parse", h_swap ~= nil)
if h_swap then
    assert_pixel("R<->B (0.25, 0.5, 0.75)", h_swap,
        0.25, 0.5, 0.75, 0.75, 0.5, 0.25); pass = pass + 1
    assert_pixel("R<->B (0.1, 0.2, 0.9)",   h_swap,
        0.1, 0.2, 0.9, 0.9, 0.2, 0.1); pass = pass + 1
    qt_lut3d_free(h_swap)
end

-- ── Fixture 3: invert R, size 2 ────────────────────────────────────
-- Transform: out = (1-r, g, b). Trilinear at (0.3, 0.7, 0.2):
--   out.r = (1-0)*(1-0.3) + (1-1)*0.3 = 0.7
--   out.g = 0*(1-0.7) + 1*0.7 = 0.7
--   out.b = 0*(1-0.2) + 1*0.2 = 0.2
local inv_r_cube = build_cube(2, function(r, g, b) return 1 - r, g, b end)
local h_inv = qt_lut3d_parse_string(inv_r_cube)
ok("invert-R parse", h_inv ~= nil)
if h_inv then
    assert_pixel("invert-R (0.3, 0.7, 0.2)",
        h_inv, 0.3, 0.7, 0.2, 0.7, 0.7, 0.2); pass = pass + 1
    assert_pixel("invert-R (0, 0, 0)",
        h_inv, 0, 0, 0, 1, 0, 0); pass = pass + 1
    assert_pixel("invert-R (1, 1, 1)",
        h_inv, 1, 1, 1, 0, 1, 1); pass = pass + 1
    qt_lut3d_free(h_inv)
end

-- ── Fixture 4: half-scale, size 2 ──────────────────────────────────
-- Transform: out = 0.5*input. At input (0.4, 0.6, 0.8) → (0.2, 0.3, 0.4).
local half_cube = build_cube(2, function(r, g, b) return 0.5 * r, 0.5 * g, 0.5 * b end)
local h_half = qt_lut3d_parse_string(half_cube)
ok("half-scale parse", h_half ~= nil)
if h_half then
    assert_pixel("half-scale (0.4, 0.6, 0.8)",
        h_half, 0.4, 0.6, 0.8, 0.2, 0.3, 0.4); pass = pass + 1
    qt_lut3d_free(h_half)
end

-- ── Fixture 5: size 3 identity, with comments + TITLE + DOMAIN ─────
-- Validates parser robustness on Resolve-style headers.
local sz3_cube = table.concat({
    "# JVE binding test — size-3 identity",
    "TITLE \"identity-3\"",
    "DOMAIN_MIN 0.0 0.0 0.0",
    "DOMAIN_MAX 1.0 1.0 1.0",
    "LUT_3D_SIZE 3",
}, "\n") .. "\n"
for bi = 0, 2 do
    for gi = 0, 2 do
        for ri = 0, 2 do
            sz3_cube = sz3_cube .. string.format("%.6f %.6f %.6f\n",
                ri / 2, gi / 2, bi / 2)
        end
    end
end
local h_sz3 = qt_lut3d_parse_string(sz3_cube)
ok("size-3 with headers parse", h_sz3 ~= nil)
if h_sz3 then
    -- Falls between grid points: (0.25, 0.75, 0.5)
    assert_pixel("size-3 identity midgrid",
        h_sz3, 0.25, 0.75, 0.5, 0.25, 0.75, 0.5); pass = pass + 1
    -- Exact grid sample.
    assert_pixel("size-3 identity at grid",
        h_sz3, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5); pass = pass + 1
    qt_lut3d_free(h_sz3)
end

-- ── Parse error cases (rule 2.32 — surface, don't swallow) ─────────
local h_bad, err_bad = qt_lut3d_parse_string("# no size directive\n0 0 0\n")
ok("missing LUT_3D_SIZE → nil + err", h_bad == nil and type(err_bad) == "string")

local h_short, err_short = qt_lut3d_parse_string("LUT_3D_SIZE 2\n0 0 0\n")
ok("truncated body → nil + err",
    h_short == nil and type(err_short) == "string"
    and err_short:find("truncated") ~= nil)

local h_one_d, err_one_d = qt_lut3d_parse_string("LUT_1D_SIZE 32\n")
ok("1D LUT in 3D loader → nil + err",
    h_one_d == nil and type(err_one_d) == "string"
    and err_one_d:find("LUT_1D_SIZE") ~= nil)

-- Out-of-range size.
local h_bigsize = qt_lut3d_parse_string("LUT_3D_SIZE 9999\n")
ok("too-large size rejected", h_bigsize == nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_lut3d_apply.lua: failures present")
print("✅ test_lut3d_apply.lua passed")
