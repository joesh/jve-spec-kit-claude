// emp_cdl.h — ASC CDL primary grade application (EMP color stage).
//
// General-editor primitive (not JVE-specific): apply an ASC CDL
// (slope / offset / power / saturation) to linear-RGB pixels. Used by
// the JVE CPU video surface for park-mode display, by the GPU video
// surface's Metal fragment shaders as a mirrored helper, and exposed
// to Lua via qt_cdl_apply_pixel for regression testing of the math.
//
// The math, per ASC S-2014-009-01 ("Color Decision List"):
//   sop  = max(in_rgb * slope + offset, 0)            -- clamp before pow
//   cdl  = sop ^ power
//   luma = dot(cdl, [0.2126, 0.7152, 0.0722])         -- ITU-R BT.709
//   out  = saturate(luma + (cdl - luma) * saturation) -- clamp to [0,1]
//
// Clamping before pow avoids producing NaN for negative-slope-plus-offset
// results raised to a non-integer power. Final saturate matches the Metal
// shader path (BGRA8 storage cannot represent values outside [0,1]).
//
// CdlParams is intentionally trivial POD: laid out for direct upload to
// a Metal fragment uniform via setFragmentBytes (no marshaling).

#pragma once

#include <cstdint>

namespace emp {

struct CdlParams {
    float slope[3];    // R, G, B
    float offset[3];   // R, G, B
    float power[3];    // R, G, B
    float saturation;
    // 0 = disabled (pass-through), 1 = apply the math. The shader and
    // the CPU code both gate on this flag so callers can keep CdlParams
    // around as a single buffer and just flip enabled.
    int32_t enabled;
};

// Apply CDL to a single linear-RGB triple in place. When `cdl.enabled
// == 0`, returns the inputs unchanged.
void apply_cdl_rgb(float& r, float& g, float& b, const CdlParams& cdl);

// Apply CDL in place over a packed BGRA8 buffer (surface storage
// format). Alpha (byte 3) is preserved verbatim. When `cdl.enabled
// == 0`, this function is a no-op (no scan over the buffer).
//
// No allocation. The 8-bit↔float conversion uses `v / 255.0f` and
// `lround(v * 255.0f)`; values are clamped to [0,1] by the inner
// saturate before the 8-bit round, matching the Metal `saturate(...)`
// followed by 8-bit storage in the shader path.
void apply_cdl_bgra8_inplace(uint8_t* data, int width, int height, int stride,
                              const CdlParams& cdl);

}  // namespace emp
