// emp_cdl.cpp — ASC CDL math implementation (EMP color stage).
//
// Mirrored by the Metal fragment shader in src/gpu_video_surface.mm
// — any change here MUST also land in the shader source. The
// reference expected values in tests/binding/test_cdl_apply_pixel.lua
// are the shared regression target (derived from the ASC standard,
// not from this implementation).

#include "editor_media_platform/emp_cdl.h"

#include <algorithm>
#include <cmath>

namespace emp {
namespace {

// ITU-R BT.709 luminance weights.
constexpr float kLumaR = 0.2126f;
constexpr float kLumaG = 0.7152f;
constexpr float kLumaB = 0.0722f;

inline float saturate01(float v) {
    return std::min(std::max(v, 0.0f), 1.0f);
}

}  // namespace

void apply_cdl_rgb(float& r, float& g, float& b, const CdlParams& cdl) {
    if (cdl.enabled == 0) return;

    // Slope-Offset, negative-clamp BEFORE pow. pow(negative, non-int)
    // returns NaN — the clamp is the explicit ASC-defined behavior.
    float sop_r = std::max(r * cdl.slope[0] + cdl.offset[0], 0.0f);
    float sop_g = std::max(g * cdl.slope[1] + cdl.offset[1], 0.0f);
    float sop_b = std::max(b * cdl.slope[2] + cdl.offset[2], 0.0f);

    float cdl_r = std::pow(sop_r, cdl.power[0]);
    float cdl_g = std::pow(sop_g, cdl.power[1]);
    float cdl_b = std::pow(sop_b, cdl.power[2]);

    // BT.709 luma; saturation interpolates from luma (gray) toward the
    // CDL'd color.
    float luma = kLumaR * cdl_r + kLumaG * cdl_g + kLumaB * cdl_b;
    float sat  = cdl.saturation;

    r = saturate01(luma + (cdl_r - luma) * sat);
    g = saturate01(luma + (cdl_g - luma) * sat);
    b = saturate01(luma + (cdl_b - luma) * sat);
}

void apply_cdl_bgra8_inplace(uint8_t* data, int width, int height, int stride,
                              const CdlParams& cdl) {
    if (cdl.enabled == 0) return;
    if (!data || width <= 0 || height <= 0) return;

    const float kInv255 = 1.0f / 255.0f;

    for (int y = 0; y < height; ++y) {
        uint8_t* row = data + y * stride;
        for (int x = 0; x < width; ++x) {
            uint8_t* p = row + x * 4;
            // BGRA8 storage; alpha (p[3]) is preserved.
            float b = p[0] * kInv255;
            float g = p[1] * kInv255;
            float r = p[2] * kInv255;
            apply_cdl_rgb(r, g, b, cdl);
            p[0] = static_cast<uint8_t>(std::lround(b * 255.0f));
            p[1] = static_cast<uint8_t>(std::lround(g * 255.0f));
            p[2] = static_cast<uint8_t>(std::lround(r * 255.0f));
        }
    }
}

}  // namespace emp
