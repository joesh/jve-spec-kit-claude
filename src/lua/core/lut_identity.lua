--- lut_identity — decide whether a baked .cube LUT is a passthrough
--- (identity) transform or carries a real color grade (spec 023 FR-015).
---
--- Why this exists: a spatial Resolve grade (power window, sizing, tracked
--- qualifier) cannot be represented by a 3D LUT — `TimelineItem.ExportLUT`
--- bakes only the non-spatial remainder, which for those clips is neutral,
--- so the cube comes out identity. JVE's renderer faithfully applies that
--- identity LUT and the clip looks ungraded. To report honestly ("grade
--- not shown" rather than silently presenting passthrough as the grade —
--- rule 2.32), the sync path classifies each baked LUT here.
---
--- The .cube format (Adobe/IRIDAS): the i-th data row addresses grid point
--- (r,g,b) with r fastest, then g, then b. An identity LUT maps each grid
--- point to its own normalized coordinate (r/(N-1), g/(N-1), b/(N-1)).
---
--- Performance: real grades are the common case and bail on the FIRST grid
--- point that deviates, so classification is O(a few rows) for graded clips;
--- only a genuinely-identity cube is read in full. A 1199-clip sync reads a
--- handful of rows per graded clip plus the full N^3 for each identity one.

local M = {}

-- Per-channel deviation above which a grid point is "graded". Resolve's
-- measured identity-export noise is ~1.5e-5 (float dust from the 33-point
-- resample); 8-bit display quantization is 1/255 ≈ 3.9e-3. EPSILON sits
-- between: comfortably above export noise (so dust isn't flagged) and below
-- the smallest perceptible grade (so a real correction is never missed).
local EPSILON = 1e-3

--- True when the .cube at `path` is an identity (passthrough) transform.
--- Asserts (rule 1.14) on a missing/unreadable file or a malformed cube
--- (size header absent, non-numeric row, or data-row count != N^3) — those
--- are invariant violations in the bake pipeline, not a "maybe identity".
--- @param path     string  absolute path to a .cube file (a stored lut_ref)
--- @param epsilon  number|nil  optional override of the deviation threshold
--- @return boolean  true = identity/passthrough, false = carries a grade
function M.is_identity(path, epsilon)
    assert(type(path) == "string" and path ~= "",
        "lut_identity.is_identity: path required")
    epsilon = epsilon or EPSILON

    local f = io.open(path, "r")
    assert(f, "lut_identity.is_identity: cannot open cube file: " .. path)

    local size = nil
    local idx = 0            -- 0-based index of the next data row
    for line in f:lines() do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        local size_match = s:match("^LUT_3D_SIZE%s+(%d+)")
        local is_meta = s == "" or s:sub(1, 1) == "#"
            or s:sub(1, 5) == "TITLE" or s:sub(1, 6) == "DOMAIN"
        if size_match then
            size = tonumber(size_match)
            assert(size and size >= 2, string.format(
                "lut_identity: bad LUT_3D_SIZE in %s", path))
        elseif not is_meta then
            assert(size, string.format(
                "lut_identity: data row before LUT_3D_SIZE in %s", path))
            -- Three whitespace-separated tokens; tonumber validates each.
            -- Matching tokens generically (not a number-shaped char class)
            -- is what lets sci-notation rows through — Resolve writes
            -- near-zero values like "6.10361e-05" whose exponent minus sits
            -- INSIDE the token, which a leading-sign-only class rejects.
            local r, g, b = s:match("^(%S+)%s+(%S+)%s+(%S+)$")
            r, g, b = tonumber(r), tonumber(g), tonumber(b)
            assert(r and g and b, string.format(
                "lut_identity: malformed data row %q in %s", s, path))
            local n1 = size - 1
            local ri = idx % size
            local gi = math.floor(idx / size) % size
            local bi = math.floor(idx / (size * size)) % size
            if math.abs(r - ri / n1) > epsilon
                or math.abs(g - gi / n1) > epsilon
                or math.abs(b - bi / n1) > epsilon then
                -- A graded cube is decided on the first deviating point.
                -- (Row-count validation is only meaningful for identity
                -- candidates, which read to the end regardless.)
                f:close()
                return false
            end
            idx = idx + 1
        end
    end
    f:close()

    assert(size, "lut_identity: no LUT_3D_SIZE header in " .. path)
    assert(idx == size * size * size, string.format(
        "lut_identity: %s has %d data rows, expected %d (N=%d)",
        path, idx, size * size * size, size))
    return true
end

return M
