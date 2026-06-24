#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>

namespace sse {

// Quality modes
enum class QualityMode {
    Q1 = 1,           // Editor mode: 1x-4x, pitch-corrected (WSOLA time-stretch)
    Q2 = 2,           // Extreme slomo: <0.25x, pitch-corrected (WSOLA time-stretch)
    Q3_DECIMATE = 3   // Varispeed (no pitch correction): >4x "chipmunk" and the
                      // 0.25x-1x "natural pitch drop" band. Pitch scales with speed.
};

// Speed range constants
constexpr float MAX_SPEED_STRETCHED = 4.0f;   // Max speed for pitch-corrected (WSOLA) playback
constexpr float MAX_SPEED_DECIMATE = 32.0f;   // Max varispeed speed (matches 32x shuttle ceiling)

// Snippet-based scrub constants
constexpr int SNIPPET_MS = 40;                // Snippet length for overlap-add scrub

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

// Snippet-based overlap-add scrub engine
// Windowed varispeed for all speeds; 1x passthrough; bidirectional with crossfade
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

    // Lightweight speed-only change for mid-play same-direction shuttle.
    // Updates speed + quality WITHOUT jumping the render position — the
    // engine keeps rendering from where it was, just at the new rate.
    // (SetTarget would re-seat m_current_time_us and bridge an audible
    // glitch into the output stream — wrong for an in-place speed bump.)
    // A reverse-direction speed still triggers the crossfade + snippet
    // reset that set_target does, but no flush / no device restart.
    void SetSpeed(float signed_speed, QualityMode mode);

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

    // ── Owner-thread invariant ────────────────────────────────────────────
    // SSE has no internal mutex on its render state; concurrent calls from
    // two threads corrupt m_current_time_us / m_speed / m_chunks. The
    // owning thread is set once when audio playback engages (AudioPump at
    // Start) and cleared when it disengages (Stop). Every public method
    // asserts the calling thread matches — unset is allowed for cold-start
    // / PlayBurst / shutdown paths where the pump is provably not running.
    //
    // The atomic store/load pair establishes happens-before from
    // SetOwnerThread() on the spawning thread to assert_owner() on the
    // pump thread for its first cycle (acquire on load synchronizes with
    // release on store).
    void SetOwnerThread(std::thread::id owner);
    void ClearOwnerThread();

private:
    void assert_owner_thread() const;

    std::unique_ptr<ScrubStretchEngineImpl> m_impl;
    std::atomic<std::thread::id> m_owner_thread_id{std::thread::id()};
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
