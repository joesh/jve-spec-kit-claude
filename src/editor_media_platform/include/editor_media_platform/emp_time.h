#pragma once

#include <cstdint>

namespace emp {

// Internal canonical time unit: microseconds since stream start
using TimeUS = int64_t;

// Frame rate as rational number (fps = num/den)
struct Rate {
    int32_t num;
    int32_t den;

    // Returns fps as double (for display/comparison only)
    double to_fps() const { return static_cast<double>(num) / den; }

    bool operator==(const Rate& other) const {
        return num == other.num && den == other.den;
    }
    bool operator!=(const Rate& other) const { return !(*this == other); }
};

// Frame-first time representation for editor clients
struct FrameTime {
    int64_t frame;
    Rate rate;

    // Convert to microseconds: T(n) = floor(n * 1_000_000 * rate.den / rate.num)
    TimeUS to_us() const {
        return (frame * 1000000LL * rate.den) / rate.num;
    }

    // Create from frame index and rate
    static FrameTime from_frame(int64_t f, Rate r) {
        return FrameTime{f, r};
    }
};

// Common canonical rates (as rationals for exact representation)
namespace canonical_rates {
    constexpr Rate RATE_23_976 = {24000, 1001};
    constexpr Rate RATE_24     = {24, 1};
    constexpr Rate RATE_25     = {25, 1};
    constexpr Rate RATE_29_97  = {30000, 1001};
    constexpr Rate RATE_30     = {30, 1};
    constexpr Rate RATE_50     = {50, 1};
    constexpr Rate RATE_59_94  = {60000, 1001};
    constexpr Rate RATE_60     = {60, 1};
}

} // namespace emp
