-- test_lut_identity.lua — black-box coverage for the .cube identity checker
-- (spec 023 FR-015 reproduction classification).
--
-- Domain behavior under test: given a baked .cube LUT file, decide whether
-- it is a passthrough (identity) transform or carries a real color grade.
-- A spatial Resolve grade (power window / sizing) bakes to an identity 3D
-- LUT — JVE must recognize that so it can report the grade as "not shown"
-- rather than silently presenting a passthrough as if it were the grade.
--
-- Expected values come from the .cube domain (Adobe/IRIDAS spec): the i-th
-- data row addresses grid point (r,g,b) with r fastest; an identity LUT maps
-- each grid point to its own normalized coordinate (r/(N-1), g/(N-1),
-- b/(N-1)). These are derived from the format, never from the implementation.

require("test_env")

local lut_identity = require("core.lut_identity")

local TMP = "/tmp/jve/lut_identity"
os.execute("mkdir -p " .. TMP)

-- Write a 3D .cube. `xform(r,g,b)` maps integer grid indices (0..N-1) to an
-- output RGB triple; default is identity. Returns the file path.
local function write_cube(name, n, xform)
    xform = xform or function(r, g, b)
        return r / (n - 1), g / (n - 1), b / (n - 1)
    end
    local path = TMP .. "/" .. name .. ".cube"
    local f = assert(io.open(path, "w"))
    f:write('TITLE "test"\n')
    f:write("LUT_3D_SIZE " .. n .. "\n\n")
    -- r fastest, then g, then b (canonical .cube ordering).
    for b = 0, n - 1 do
        for g = 0, n - 1 do
            for r = 0, n - 1 do
                local or_, og, ob = xform(r, g, b)
                f:write(string.format("%.6f %.6f %.6f\n", or_, og, ob))
            end
        end
    end
    f:close()
    return path
end

-- 1. A perfect identity cube is identity.
do
    local p = write_cube("identity_small", 2)
    assert(lut_identity.is_identity(p) == true,
        "perfect 2^3 identity must classify as identity")
end

-- 2. A larger identity cube (Resolve bakes 33-point) is identity.
do
    local p = write_cube("identity_33", 33)
    assert(lut_identity.is_identity(p) == true,
        "33^3 identity must classify as identity")
end

-- 3. Sub-perceptual export noise (1.48e-05 was Resolve's measured identity
--    noise) stays identity — the checker must not flag float-precision dust.
do
    local p = write_cube("identity_noisy", 17, function(r, g, b)
        local n = 17
        return r / (n - 1) + 1.5e-5, g / (n - 1), b / (n - 1) - 1.0e-5
    end)
    assert(lut_identity.is_identity(p) == true,
        "export-noise-level deviation must remain identity")
end

-- 4. A real grade (a single grid point pushed far off identity) is NOT
--    identity — even one shifted node means the LUT carries color.
do
    local p = write_cube("graded_spot", 17, function(r, g, b)
        local n = 17
        if r == 8 and g == 8 and b == 8 then
            return 0.0, 0.0, 0.0  -- mid-grey crushed to black
        end
        return r / (n - 1), g / (n - 1), b / (n - 1)
    end)
    assert(lut_identity.is_identity(p) == false,
        "a grade that crushes mid-grey must classify as NOT identity")
end

-- 5. A strong global grade (everything to black) is NOT identity.
do
    local p = write_cube("graded_strong", 9, function() return 0, 0, 0 end)
    assert(lut_identity.is_identity(p) == false,
        "all-black transform must classify as NOT identity")
end

-- 6. A truncated cube whose rows all look identity (so the checker reads to
--    the end) is an invariant violation — assert on the row-count mismatch,
--    never silently treat as identity (rule 1.14 / 2.32). (A truncated cube
--    that DEVIATES early is honestly decided "not identity" before the count
--    check — that verdict is correct, so only the identity-prefix case can
--    exercise the row-count invariant under the early-out design.)
do
    local path = TMP .. "/truncated_identity.cube"
    local f = assert(io.open(path, "w"))
    -- N=4 wants 64 rows; write only the first 3 valid identity rows.
    f:write("LUT_3D_SIZE 4\n0 0 0\n0.333333 0 0\n0.666667 0 0\n")
    f:close()
    local ok = pcall(lut_identity.is_identity, path)
    assert(ok == false,
        "truncated identity cube (wrong row count) must assert, not return a verdict")
end

-- 7. A missing file is an invariant violation (a stored lut_ref must exist).
do
    local ok = pcall(lut_identity.is_identity, TMP .. "/does_not_exist.cube")
    assert(ok == false, "missing cube file must assert")
end

-- 8. Resolve writes near-zero LUT values in SCIENTIFIC NOTATION (a real baked
--    row observed in the wild: "1 0.125017 6.10361e-05"). The exponent's minus
--    sign sits INSIDE the token, so a reader that only allows a leading sign
--    rejects it as malformed and aborts the whole sync. A row whose values are
--    identity-to-tolerance, written in sci-notation, must classify as identity.
do
    local path = TMP .. "/sci_notation_identity.cube"
    local f = assert(io.open(path, "w"))
    f:write("LUT_3D_SIZE 2\n")
    -- 2^3 identity grid (r fastest), near-zero coords as sci-notation dust:
    f:write("6.10361e-05 6.10361e-05 6.10361e-05\n")  -- (0,0,0)
    f:write("1 6.10361e-05 6.10361e-05\n")            -- (1,0,0) — the wild shape
    f:write("6.10361e-05 1 6.10361e-05\n")            -- (0,1,0)
    f:write("1 1 6.10361e-05\n")                      -- (1,1,0)
    f:write("6.10361e-05 6.10361e-05 1\n")            -- (0,0,1)
    f:write("1 6.10361e-05 1\n")                      -- (1,0,1)
    f:write("6.10361e-05 1 1\n")                      -- (0,1,1)
    f:write("1 1 1\n")                                -- (1,1,1)
    f:close()
    assert(lut_identity.is_identity(path) == true,
        "sci-notation identity rows must parse and classify as identity")
end

print("✅ test_lut_identity.lua passed")
