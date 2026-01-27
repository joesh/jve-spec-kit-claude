#pragma once

#include "emp_time.h"
#include <cmath>

namespace emp {

// Rate utilities for canonical snapping and comparison
class RateUtils {
public:
    // Check if two rates are "close" (within 0.2% tolerance)
    // This treats 23.976<->24 and 29.97<->30 as "close"
    static bool are_close(const Rate& a, const Rate& b) {
        double fps_a = a.to_fps();
        double fps_b = b.to_fps();
        if (fps_b == 0.0) return false;
        return std::abs(fps_a - fps_b) / fps_b <= 0.002;
    }

    // Snap rate to nearest canonical rate if within tolerance
    // Returns original rate if no canonical rate is close
    static Rate snap_to_canonical(const Rate& r) {
        using namespace canonical_rates;

        static const Rate canonicals[] = {
            RATE_23_976, RATE_24, RATE_25,
            RATE_29_97, RATE_30, RATE_50,
            RATE_59_94, RATE_60
        };

        for (const auto& canonical : canonicals) {
            if (are_close(r, canonical)) {
                return canonical;
            }
        }
        return r;
    }

    // Select CFR grid rate for source viewer
    // Default to clip's nominal rate, but use sequence rate if "close"
    static Rate select_grid_rate(const Rate& nominal, const Rate& sequence) {
        Rate snapped_nominal = snap_to_canonical(nominal);
        if (are_close(snapped_nominal, sequence)) {
            return sequence;
        }
        return snapped_nominal;
    }
};

} // namespace emp
