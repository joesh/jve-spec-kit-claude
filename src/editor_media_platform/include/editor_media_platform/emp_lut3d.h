// emp_lut3d.h — 3D LUT (Adobe .cube) load + trilinear apply (EMP color
// stage).
//
// General-editor primitive (not JVE-specific): parse Adobe Cube LUT
// (.cube) files emitted by DaVinci Resolve's ExportLUT, and apply the
// resulting 3D LUT to linear-RGB pixels via trilinear interpolation.
// Used by the JVE CPU video surface for park-mode display when a clip's
// grade fidelity is `partial` or `unrepresentable` (the bake path —
// CDL math is used for `primary`; the two are mutually exclusive per
// clip per FR-015's closed-set discriminator).
//
// Mirrored by the Metal fragment shader in src/gpu_video_surface.mm —
// the GPU path uploads `Lut3d::data` as an RGBA16F 3D texture and uses
// MTLSamplerStateLinear for hardware trilinear; the CPU path here
// implements the same trilinear in software for symmetry. Reference
// vectors in tests/synthetic/binding/test_lut3d_apply.lua are the shared
// regression target.
//
// .cube format (Adobe Cube LUT Specification v1.0):
//   # comments / blank lines OK
//   TITLE "..."                  (optional)
//   LUT_3D_SIZE N                (required — N ∈ [2, 256]; Resolve
//                                 33PTCUBE → N=33)
//   DOMAIN_MIN r g b             (optional, defaults to 0 0 0)
//   DOMAIN_MAX r g b             (optional, defaults to 1 1 1)
//   <N^3 lines of "r g b" floats — R varies fastest, then G, then B>
//
// Spec scope: display-space input assumed (Rec.709 here, matching what
// Resolve sees on its color page for display-bound LUTs). Out-of-gamut
// management (log/raw inputs, ACES) is a later concern — the renderer
// today feeds BGRA8 in display space to both CDL and LUT stages.

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace emp {

// Parsed 3D LUT data + minimal metadata. Layout: R varies fastest, then
// G, then B (Adobe spec) — sample index = ((b * size + g) * size + r) * 3.
// `data.size() == size * size * size * 3`.
struct Lut3d {
    int size = 0;                // grid edge length (e.g. 33 for 33PTCUBE)
    float domain_min[3] = {0.0f, 0.0f, 0.0f};
    float domain_max[3] = {1.0f, 1.0f, 1.0f};
    std::vector<float> data;     // row-major, R-fastest, RGB triples
    // 0 = disabled (pass-through), 1 = apply. Mirrors CdlParams.enabled so
    // surface code can keep a single Lut3d around and flip the gate.
    int32_t enabled = 0;
};

// Load a .cube file from disk. Returns true on success and populates
// `out` (size, domain, data, enabled=1). On failure populates `err`
// with a human-actionable message and returns false; `out` is left
// untouched. Failures: file unreadable, missing LUT_3D_SIZE, bad size
// (< 2 or > 256), wrong number of sample lines, malformed floats.
// Comments (`#…`) and blank lines are skipped.
bool load_cube_file(const std::string& path, Lut3d& out, std::string& err);

// Parse .cube content already in memory. Same semantics as
// load_cube_file — separated so tests can feed inline content without
// touching disk.
bool parse_cube(const std::string& content, Lut3d& out, std::string& err);

// Apply a 3D LUT to a single linear-RGB triple in place via trilinear
// interpolation against `lut`. When `lut.enabled == 0`, returns the
// inputs unchanged. When `lut.size == 0`, asserts (the lut wasn't
// loaded — calling this is a bug, not a graceful fallback).
void apply_lut3d_rgb(float& r, float& g, float& b, const Lut3d& lut);

// Apply a 3D LUT in place over a packed BGRA8 buffer (surface storage
// format). Alpha (byte 3) is preserved verbatim. When `lut.enabled
// == 0`, no-op (no scan over the buffer). 8-bit↔float conversion uses
// `v / 255.0f` and `lround(v * 255.0f)`; trilinear output is clamped
// to [0,1] before 8-bit round, matching the Metal `saturate(...)`
// stored in BGRA8.
void apply_lut3d_bgra8_inplace(uint8_t* data, int width, int height, int stride,
                                const Lut3d& lut);

}  // namespace emp
