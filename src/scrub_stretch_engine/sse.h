#pragma once

#include <memory>
#include <cstdint>

namespace sse {

// Quality modes
enum class QualityMode {
    Q1 = 1,           // Editor mode: ≤60ms latency, 0.25x-4x range
    Q2 = 2,           // Extreme slomo: ≤150ms latency, down to 0.10x
    Q3_DECIMATE = 3   // High-speed mode: >4x up to 16x, no pitch correction (decimation)
};

// Speed range constants
constexpr float MAX_SPEED_STRETCHED = 4.0f;   // Max speed for pitch-corrected playback
constexpr float MAX_SPEED_DECIMATE = 16.0f;   // Max speed for decimate mode

// Configuration for SSE
struct SseConfig {
    int32_t sample_rate;       // Device rate (default 48000)
    int32_t channels;          // Channel count (default 2, stereo)
    int32_t block_frames;      // Output block size (default 512)
    int32_t lookahead_ms_q1;   // Q1 lookahead (default 60)
    int32_t lookahead_ms_q2;   // Q2 lookahead (default 150)
    float min_speed_q1;        // Q1 min speed (default 0.25)
    float min_speed_q2;        // Q2 min speed (default 0.10)
    float max_speed;           // Max speed (default 4.0)
    int32_t xfade_ms;          // Direction change crossfade (default 15)
};

// Forward declaration
class ScrubStretchEngineImpl;

// WSOLA-based pitch-preserving time stretcher
// Supports bidirectional playback with seamless direction changes
class ScrubStretchEngine {
public:
    ~ScrubStretchEngine();

    // Create a new SSE instance
    static std::unique_ptr<ScrubStretchEngine> Create(const SseConfig& config);

    // Reset internal state (e.g., on clip change)
    void Reset();

    // Set transport parameters
    // t_us: media time in microseconds
    // speed: playback rate (negative = reverse)
    // mode: quality mode (Q1 or Q2)
    void SetTarget(int64_t t_us, float speed, QualityMode mode);

    // Provide source PCM from EMP
    // start_time_us: media time of first sample
    void PushSourcePcm(const float* interleaved, int64_t frames, int64_t start_time_us);

    // Produce output audio
    // Returns frames actually produced (may be less than requested if starved)
    int64_t Render(float* out_interleaved, int64_t out_frames);

    // Check if engine is starved (not enough source data)
    bool Starved() const;
    void ClearStarvedFlag();

    // Get current output time position (media time in us)
    int64_t CurrentTimeUS() const;

    // Internal constructor
    explicit ScrubStretchEngine(std::unique_ptr<ScrubStretchEngineImpl> impl);

private:
    std::unique_ptr<ScrubStretchEngineImpl> m_impl;
};

// Create default config
inline SseConfig default_config() {
    SseConfig cfg;
    cfg.sample_rate = 48000;
    cfg.channels = 2;
    cfg.block_frames = 512;
    cfg.lookahead_ms_q1 = 60;
    cfg.lookahead_ms_q2 = 150;
    cfg.min_speed_q1 = 0.25f;
    cfg.min_speed_q2 = 0.10f;
    cfg.max_speed = 4.0f;
    cfg.xfade_ms = 15;
    return cfg;
}

} // namespace sse
