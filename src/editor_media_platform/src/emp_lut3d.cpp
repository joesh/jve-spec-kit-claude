// emp_lut3d.cpp — Adobe .cube parser + trilinear apply (EMP color stage).
//
// Mirrored by the Metal fragment shader in src/gpu_video_surface.mm
// (3D RGBA16F texture + MTLSamplerStateLinear gives hardware trilinear
// equivalent to the software implementation here). Reference vectors
// in tests/synthetic/binding/test_lut3d_apply.lua are the shared regression
// target — derived from the Adobe Cube spec, not from this code.

#include "editor_media_platform/emp_lut3d.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

namespace emp {
namespace {

constexpr int kMinSize = 2;
constexpr int kMaxSize = 256;

inline float saturate01(float v) {
    return std::min(std::max(v, 0.0f), 1.0f);
}

// Strip leading whitespace. We don't trim trailing — std::istringstream
// handles whitespace-terminated tokens for us.
inline const char* skip_ws(const char* s) {
    while (*s == ' ' || *s == '\t' || *s == '\r') ++s;
    return s;
}

inline bool is_blank_or_comment(const char* s) {
    s = skip_ws(s);
    return *s == '\0' || *s == '\n' || *s == '#';
}

// Parse three whitespace-separated floats from `line` into out[3].
// Returns true iff exactly three floats parsed and no trailing junk
// (besides whitespace/comment). On failure leaves out unspecified.
bool parse_three_floats(const std::string& line, float out[3]) {
    std::istringstream iss(line);
    if (!(iss >> out[0] >> out[1] >> out[2])) return false;
    // Allow trailing whitespace + comment, nothing else.
    std::string rest;
    if (iss >> rest) {
        if (!rest.empty() && rest[0] != '#') return false;
    }
    return true;
}

}  // namespace

bool parse_cube(const std::string& content, Lut3d& out, std::string& err) {
    // Two-pass parse: first scan headers (LUT_3D_SIZE, DOMAIN_MIN/MAX),
    // then read N^3 sample lines. Headers may appear in any order before
    // sample data starts; per Adobe spec the first non-header non-blank
    // line that doesn't match a known keyword is the start of the LUT
    // body, so we transition by trying-keywords-first.

    Lut3d parsed;
    int size = 0;
    int line_no = 0;
    bool in_body = false;
    std::vector<float> samples;
    size_t expected_samples = 0;

    std::istringstream stream(content);
    std::string line;
    while (std::getline(stream, line)) {
        ++line_no;
        if (is_blank_or_comment(line.c_str())) continue;

        if (!in_body) {
            // Detect known headers by keyword prefix.
            // istringstream over a temp string so peek is non-destructive.
            std::istringstream iss(line);
            std::string keyword;
            iss >> keyword;
            if (keyword == "TITLE") {
                // No semantic effect — Resolve emits this; we accept and
                // skip. (Per Adobe spec the value is a quoted string;
                // we don't need it.)
                continue;
            }
            if (keyword == "LUT_3D_SIZE") {
                int n = 0;
                if (!(iss >> n)) {
                    err = "emp_lut3d: LUT_3D_SIZE missing integer at line "
                          + std::to_string(line_no);
                    return false;
                }
                if (n < kMinSize || n > kMaxSize) {
                    err = "emp_lut3d: LUT_3D_SIZE " + std::to_string(n)
                          + " out of range [" + std::to_string(kMinSize)
                          + ", " + std::to_string(kMaxSize) + "] at line "
                          + std::to_string(line_no);
                    return false;
                }
                size = n;
                continue;
            }
            if (keyword == "LUT_1D_SIZE") {
                // Hard-fail rather than silently treating as 3D. Caller
                // passed a 1D LUT file to a 3D loader — bug, surface it
                // (rule 2.32).
                err = "emp_lut3d: LUT_1D_SIZE not supported (1D LUT file "
                      "passed to 3D loader) at line "
                      + std::to_string(line_no);
                return false;
            }
            if (keyword == "DOMAIN_MIN") {
                float tmp[3];
                std::string rest = line.substr(keyword.size());
                if (!parse_three_floats(rest, tmp)) {
                    err = "emp_lut3d: DOMAIN_MIN expects 3 floats at line "
                          + std::to_string(line_no);
                    return false;
                }
                parsed.domain_min[0] = tmp[0];
                parsed.domain_min[1] = tmp[1];
                parsed.domain_min[2] = tmp[2];
                continue;
            }
            if (keyword == "DOMAIN_MAX") {
                float tmp[3];
                std::string rest = line.substr(keyword.size());
                if (!parse_three_floats(rest, tmp)) {
                    err = "emp_lut3d: DOMAIN_MAX expects 3 floats at line "
                          + std::to_string(line_no);
                    return false;
                }
                parsed.domain_max[0] = tmp[0];
                parsed.domain_max[1] = tmp[1];
                parsed.domain_max[2] = tmp[2];
                continue;
            }
            // Not a known keyword — this line must be the first sample
            // line. Body requires LUT_3D_SIZE to have already been seen.
            if (size == 0) {
                err = "emp_lut3d: sample data before LUT_3D_SIZE at line "
                      + std::to_string(line_no);
                return false;
            }
            in_body = true;
            expected_samples =
                static_cast<size_t>(size) * size * size * 3;
            samples.reserve(expected_samples);
            // fall through to sample-parse for THIS line
        }

        // In-body: parse one RGB triple.
        float rgb[3];
        if (!parse_three_floats(line, rgb)) {
            err = "emp_lut3d: malformed sample at line "
                  + std::to_string(line_no);
            return false;
        }
        samples.push_back(rgb[0]);
        samples.push_back(rgb[1]);
        samples.push_back(rgb[2]);
        if (samples.size() > expected_samples) {
            err = "emp_lut3d: too many sample lines (expected "
                  + std::to_string(expected_samples / 3)
                  + " triples) at line " + std::to_string(line_no);
            return false;
        }
    }

    if (size == 0) {
        err = "emp_lut3d: file has no LUT_3D_SIZE directive";
        return false;
    }
    if (samples.size() != expected_samples) {
        err = "emp_lut3d: truncated LUT — got "
              + std::to_string(samples.size() / 3) + " triples, expected "
              + std::to_string(expected_samples / 3);
        return false;
    }
    // Domain sanity — equal/inverted axes would divide by zero in
    // apply. Surface this rather than producing NaN pixels (rule 2.32).
    for (int i = 0; i < 3; ++i) {
        if (!(parsed.domain_max[i] > parsed.domain_min[i])) {
            err = "emp_lut3d: domain_max[" + std::to_string(i)
                  + "] must exceed domain_min["
                  + std::to_string(i) + "]";
            return false;
        }
    }
    parsed.size = size;
    parsed.data = std::move(samples);
    parsed.enabled = 1;
    out = std::move(parsed);
    return true;
}

bool load_cube_file(const std::string& path, Lut3d& out, std::string& err) {
    std::ifstream f(path);
    if (!f.is_open()) {
        err = "emp_lut3d: cannot open " + path;
        return false;
    }
    std::ostringstream buf;
    buf << f.rdbuf();
    return parse_cube(buf.str(), out, err);
}

void apply_lut3d_rgb(float& r, float& g, float& b, const Lut3d& lut) {
    if (lut.enabled == 0) return;
    assert(lut.size >= kMinSize && "apply_lut3d_rgb: lut not loaded");
    assert(static_cast<size_t>(lut.size) * lut.size * lut.size * 3
            == lut.data.size()
           && "apply_lut3d_rgb: data size mismatches grid");

    // Normalize input from [domain_min, domain_max] to [0, 1], clamp.
    const float nx = saturate01(
        (r - lut.domain_min[0]) / (lut.domain_max[0] - lut.domain_min[0]));
    const float ny = saturate01(
        (g - lut.domain_min[1]) / (lut.domain_max[1] - lut.domain_min[1]));
    const float nz = saturate01(
        (b - lut.domain_min[2]) / (lut.domain_max[2] - lut.domain_min[2]));

    const int N = lut.size;
    const float fx = nx * (N - 1);
    const float fy = ny * (N - 1);
    const float fz = nz * (N - 1);

    const int x0 = std::min(static_cast<int>(std::floor(fx)), N - 1);
    const int y0 = std::min(static_cast<int>(std::floor(fy)), N - 1);
    const int z0 = std::min(static_cast<int>(std::floor(fz)), N - 1);
    const int x1 = std::min(x0 + 1, N - 1);
    const int y1 = std::min(y0 + 1, N - 1);
    const int z1 = std::min(z0 + 1, N - 1);

    const float tx = fx - x0;
    const float ty = fy - y0;
    const float tz = fz - z0;

    auto idx = [N](int x, int y, int z) {
        // R varies fastest, then G, then B (Adobe spec).
        return ((z * N + y) * N + x) * 3;
    };
    const float* d = lut.data.data();

    // 8 corner samples.
    const float* c000 = d + idx(x0, y0, z0);
    const float* c100 = d + idx(x1, y0, z0);
    const float* c010 = d + idx(x0, y1, z0);
    const float* c110 = d + idx(x1, y1, z0);
    const float* c001 = d + idx(x0, y0, z1);
    const float* c101 = d + idx(x1, y0, z1);
    const float* c011 = d + idx(x0, y1, z1);
    const float* c111 = d + idx(x1, y1, z1);

    float out_rgb[3];
    for (int ch = 0; ch < 3; ++ch) {
        const float c00 = c000[ch] * (1 - tx) + c100[ch] * tx;
        const float c10 = c010[ch] * (1 - tx) + c110[ch] * tx;
        const float c01 = c001[ch] * (1 - tx) + c101[ch] * tx;
        const float c11 = c011[ch] * (1 - tx) + c111[ch] * tx;
        const float c0  = c00 * (1 - ty) + c10 * ty;
        const float c1  = c01 * (1 - ty) + c11 * ty;
        out_rgb[ch]     = c0 * (1 - tz) + c1 * tz;
    }
    r = out_rgb[0];
    g = out_rgb[1];
    b = out_rgb[2];
}

void apply_lut3d_bgra8_inplace(uint8_t* data, int width, int height, int stride,
                                const Lut3d& lut) {
    assert(data != nullptr && "apply_lut3d_bgra8_inplace: null data");
    assert(width  > 0 && "apply_lut3d_bgra8_inplace: width must be positive");
    assert(height > 0 && "apply_lut3d_bgra8_inplace: height must be positive");
    assert(stride >= width * 4 &&
           "apply_lut3d_bgra8_inplace: stride < width*4 (row overflow)");

    if (lut.enabled == 0) return;

    const float kInv255 = 1.0f / 255.0f;
    for (int y = 0; y < height; ++y) {
        uint8_t* row = data + y * stride;
        for (int x = 0; x < width; ++x) {
            uint8_t* p = row + x * 4;
            float bf = p[0] * kInv255;
            float gf = p[1] * kInv255;
            float rf = p[2] * kInv255;
            apply_lut3d_rgb(rf, gf, bf, lut);
            p[0] = static_cast<uint8_t>(std::lround(saturate01(bf) * 255.0f));
            p[1] = static_cast<uint8_t>(std::lround(saturate01(gf) * 255.0f));
            p[2] = static_cast<uint8_t>(std::lround(saturate01(rf) * 255.0f));
        }
    }
}

}  // namespace emp
