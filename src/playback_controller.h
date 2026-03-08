#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <algorithm>
#include <vector>

// Forward declarations
class GPUVideoSurface;

namespace emp {
class TimelineMediaBuffer;
class Frame;
struct VideoResult;
enum class TrackType;
}

namespace aop {
class AudioOutput;
}

namespace sse {
class ScrubStretchEngine;
enum class QualityMode;
}

// ============================================================================
// Playback diagnostics — zero-I/O ring buffers for per-tick capture
// ============================================================================

struct TickMetric {        // ~88 bytes, written per CVDisplayLink tick
    double elapsed_ms;      // CVDisplayLink interval
    double advance_ms;      // advancePosition() wall time
    double setPlayhead_ms;  // TMB SetPlayhead() wall time
    double deliver_ms;      // deliverFrame() wall time (incl TMB GetVideoFrame)
    double report_ms;       // reportPosition() wall time
    double cadence_ms;      // ms since last NEW frame displayed (0 if repeat)
    double drift_s;         // A/V drift (video - audio)
    double pll_adjust;      // PLL correction applied
    int64_t frame;
    int64_t audio_buf_frames; // AOP BufferedFrames() at tick time
    uint8_t flags;          // TickFlags bitfield
    uint8_t padding[7];
};

struct PumpMetric {        // ~48 bytes, written per pump cycle
    int64_t media_time_us;
    int64_t aop_playhead_us;
    int64_t fetched_frames;
    int64_t rendered_frames;
    int64_t buffered_frames;  // AOP level BEFORE render
    uint8_t flags;            // PumpFlags bitfield
    uint8_t padding[7];
};

namespace TickFlags {
    constexpr uint8_t SKIP       = 1 << 0;
    constexpr uint8_t HOLD       = 1 << 1;
    constexpr uint8_t REPEAT     = 1 << 2;
    constexpr uint8_t PREFETCH   = 1 << 3;
    constexpr uint8_t GAP        = 1 << 4;
    constexpr uint8_t TRANSITION = 1 << 5;
    constexpr uint8_t OFFLINE    = 1 << 6;
    constexpr uint8_t DROPPED   = 1 << 7;
}

namespace PumpFlags {
    constexpr uint8_t UNDERRUN = 1 << 0;
    constexpr uint8_t STALL    = 1 << 1;
    constexpr uint8_t DRY      = 1 << 2;
}

// Fixed-size circular buffer. Single-writer, dump at Stop().
template<typename T, size_t N>
class DiagRing {
public:
    T& next() {
        size_t idx = m_write_pos % N;
        m_buffer[idx] = T{};
        ++m_write_pos;
        return m_buffer[idx];
    }

    template<typename Fn>
    void for_each(Fn&& fn) const {
        if (m_write_pos == 0) return;
        if (m_write_pos <= N) {
            for (size_t i = 0; i < m_write_pos; ++i)
                fn(m_buffer[i]);
        } else {
            size_t start = m_write_pos % N;
            for (size_t i = 0; i < N; ++i)
                fn(m_buffer[(start + i) % N]);
        }
    }

    size_t count() const { return m_write_pos; }
    size_t size() const { return std::min(m_write_pos, N); }

    void reset() { m_write_pos = 0; }

private:
    T m_buffer[N]{};
    size_t m_write_pos{0};
};

static constexpr size_t DIAG_VIDEO_RING_SIZE = 1800;  // ~30s @60Hz, ~154KB
static constexpr size_t DIAG_AUDIO_RING_SIZE = 3000;  // ~30s @~100Hz, ~140KB

// ============================================================================
// PlaybackClock - epoch-based A/V sync
// ============================================================================
// Tracks media time using AOP playhead as master clock.
// Uses epoch-based subtraction: media_anchor + (playhead - epoch) * speed
// This is FLUSH-agnostic (doesn't assume FLUSH resets playhead).
class PlaybackClock {
public:
    // Reanchor at transport event (play, seek, speed change)
    void Reanchor(int64_t media_time_us, float speed, int64_t aop_playhead_us);

    // Get current media time from AOP playhead
    int64_t CurrentTimeUS(int64_t aop_playhead_us) const;

    // Convert media time to frame index
    static int64_t FrameFromTimeUS(int64_t time_us, int32_t fps_num, int32_t fps_den);

    // Measure output latency from CoreAudio device properties.
    // Call once when audio session is activated. Falls back to DEFAULT_LATENCY_US on failure.
    void MeasureOutputLatency(uint32_t device_id, int32_t sample_rate);

    // Getters for pump loop
    int64_t MediaAnchorUS() const { return m_media_anchor_us.load(std::memory_order_relaxed); }
    float Speed() const { return m_speed.load(std::memory_order_relaxed); }
    int64_t OutputLatencyUS() const { return m_output_latency_us.load(std::memory_order_relaxed); }

    // Set the QAudioSink buffer latency (call after each AOP Start).
    // Total output latency = CoreAudio device latency + sink buffer.
    void SetSinkBufferLatency(int64_t sink_us);

private:
    std::atomic<int64_t> m_media_anchor_us{0};   // Media time at last reanchor
    std::atomic<int64_t> m_aop_epoch_us{0};      // AOP playhead at last reanchor
    std::atomic<float> m_speed{1.0f};            // Signed speed (negative = reverse)

    // Total audio output latency = device_latency + sink_buffer
    std::atomic<int64_t> m_output_latency_us{DEFAULT_LATENCY_US};
    // CoreAudio device latency (measured once in MeasureOutputLatency)
    int64_t m_device_latency_us{DEFAULT_LATENCY_US};

    // Default fallback (conservative estimate: OS mixer + driver + DAC)
    static constexpr int64_t DEFAULT_LATENCY_US = 150000;  // 150ms
};

// ============================================================================
// AudioPump - dedicated thread for TMB→SSE→AOP
// ============================================================================
class AudioPump {
public:
    AudioPump();
    ~AudioPump();

    // Start pump thread with dependencies
    void Start(emp::TimelineMediaBuffer* tmb, sse::ScrubStretchEngine* sse,
               aop::AudioOutput* aop, PlaybackClock* clock,
               int32_t sample_rate, int32_t channels,
               DiagRing<PumpMetric, DIAG_AUDIO_RING_SIZE>* diag);
    void Stop();
    bool IsRunning() const;

    // Quality mode (computed from speed in SetSpeed)
    void SetQualityMode(int mode);
    int QualityMode() const;

    // Diagnostics (read after Stop)
    int64_t UnderrunCount() const { return m_underrun_count; }

    // Reset incremental push tracking (call at every transport change)
    void ResetPushState();

    // Pump timing constants (match Lua CFG) — public for pre-fill sizing
    static constexpr int TARGET_BUFFER_MS = 200;
    static constexpr int MAX_RENDER_FRAMES = 4096;

private:
    void pumpLoop();

    std::thread m_thread;
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_stop_requested{false};
    std::atomic<int> m_quality_mode{1};  // Q1=1, Q2=2, Q3=3

    // Incremental push tracking: end-time of last pushed audio (μs).
    // -1 = no push yet (next push is full window from SSE time).
    // Each time range is extracted and pushed ONCE — eliminates quantization drift
    // from redundant μs→sample conversions on overlapping windows.
    std::atomic<int64_t> m_last_push_end_us{-1};

    // Dependencies (set by Start, read by pumpLoop)
    emp::TimelineMediaBuffer* m_tmb{nullptr};
    sse::ScrubStretchEngine* m_sse{nullptr};
    aop::AudioOutput* m_aop{nullptr};
    PlaybackClock* m_clock{nullptr};
    int32_t m_sample_rate{48000};
    int32_t m_channels{2};

    // Pump timing constants
    static constexpr int PUMP_INTERVAL_HUNGRY_MS = 2;
    static constexpr int PUMP_INTERVAL_OK_MS = 15;

    // Diagnostics
    DiagRing<PumpMetric, DIAG_AUDIO_RING_SIZE>* m_diag{nullptr};
    int64_t m_underrun_count{0};
};

#ifdef __APPLE__

// PlaybackController - CVDisplayLink-driven playback for VSync-locked frame delivery.
//
// Design:
// - One PlaybackController per SequenceMonitor (independent playback state)
// - CVDisplayLink tick runs on high-priority thread, fetches frames from TMB
// - Position callback fires on main thread (coalesced to reduce FFI overhead)
// - Scrub stays in Lua (this controller handles Play/Shuttle only)
//
// Thread safety:
// - Transport commands (Play/Stop/Seek) called from main thread
// - displayLinkTick() called from CVDisplayLink thread
// - Position callback dispatched to main thread via dispatch_async
class PlaybackController {
public:
    static std::unique_ptr<PlaybackController> Create();
    ~PlaybackController();

    // Configuration (call from main thread before Play)
    void SetSurface(GPUVideoSurface* surface);
    void SetTMB(emp::TimelineMediaBuffer* tmb);
    void SetBounds(int64_t total_frames, int32_t fps_num, int32_t fps_den);

    // Transport (from Lua, main thread)
    void Play(int direction, float speed);
    void Stop();
    void Park(int64_t frame);   // Position + TMB prime only (no display)
    void Seek(int64_t frame);   // Park + deliverFrame (C++ push)

    // Audio pump control (Phase 3)
    void ActivateAudio(aop::AudioOutput* aop, sse::ScrubStretchEngine* sse,
                       int32_t sample_rate, int32_t channels);
    void DeactivateAudio();
    void SetSpeed(float signed_speed);  // mid-playback speed change with reanchor
    void PlayBurst(int64_t frame_idx, int direction, int duration_ms);
    bool HasAudio() const;

    // Shuttle mode
    void SetShuttleMode(bool enabled);
    bool HitBoundary() const;

    // Position callback (fires on main thread, coalesced)
    using PositionCallback = std::function<void(int64_t frame, bool stopped)>;
    void SetPositionCallback(PositionCallback cb);

    // Clip data provider: host (Lua) queries DB for clips in [from, to), adds to TMB.
    using ClipProviderCallback = std::function<void(int64_t from, int64_t to, emp::TrackType type)>;
    void SetClipProvider(ClipProviderCallback cb);

    // Clip transition callback (fires on main thread when displayed clip changes)
    // Args: clip_id, rotation, par_num, par_den, is_offline, media_path, frame
    using ClipTransitionCallback = std::function<void(const std::string& clip_id,
        int rotation, int par_num, int par_den, bool offline,
        const std::string& media_path, int64_t frame)>;
    void SetClipTransitionCallback(ClipTransitionCallback cb);

    // Clip prefetch: clear TMB + reset + re-prefetch after timeline edits.
    void reloadAllClips();

    // State queries (thread-safe)
    int64_t CurrentFrame() const;
    bool IsPlaying() const;

    // CVDisplayLink callback (runs on display link thread)
    // Public because it's called from C callback function
    void displayLinkTick(uint64_t host_time, uint64_t output_time);

    // Manual tick for integration tests when CVDisplayLink is unavailable (headless/CLI).
    // Calls displayLinkTick with current mach_absolute_time. Caller must drain the
    // GCD main queue afterwards (CONTROL.PROCESS_EVENTS) for frame delivery.
    void Tick();

    // Diagnostic summary — read after Stop() returns (rings preserved until next Play).
    struct DiagSummary {
        size_t tick_count;
        double cadence_p50_ms;
        double cadence_p95_ms;
        double cadence_p99_ms;
        double drift_p50_s;
        double drift_p95_s;
        double drift_p99_s;
        int64_t skip_count;
        int64_t hold_count;
        int64_t repeat_count;
        int64_t gap_count;
        int64_t dropped_count;
        int64_t backward_jumps;       // frame[i] < frame[i-1] for non-REPEAT forward ticks
        bool audio_master_engaged;    // true if audio-master was active at Stop()
    };
    DiagSummary GetDiagSummary() const;

private:
    PlaybackController();

    // Pre-roll: wait for REFILL workers to populate video cache (called from Play())
    void waitForVideoCache(int64_t pos, int timeout_ms);
    void prefillAudio(int64_t pos, int direction, float speed);

    // Pre-roll timing constants
    static constexpr int PREROLL_POLL_MS = 5;        // cache poll interval
    static constexpr int PREROLL_TIMEOUT_MS = 3000;  // give up after 3s

    // Frame delivery.
    // synchronous=true: Seek (main thread) — direct setFrame + callback calls.
    // synchronous=false: displayLinkTick (CVDisplayLink thread) — dispatch_async to main.
    void deliverFrame(int64_t frame, bool synchronous);

    // Position reporting (coalesced, main thread)
    void reportPosition(int64_t frame, bool immediate);

    // Advance position based on elapsed time or audio
    int64_t advancePosition(double elapsed_seconds);

    // CVDisplayLink setup/teardown
    bool startDisplayLink();  // returns false if display unavailable (headless)
    void stopDisplayLink();

    // ---- Atomics for cross-thread access ----
    std::atomic<int64_t> m_position{0};
    std::atomic<int> m_direction{0};
    std::atomic<float> m_speed{1.0f};
    std::atomic<bool> m_playing{false};
    std::atomic<bool> m_shuttle_mode{false};
    std::atomic<bool> m_hit_boundary{false};

    // ---- Configuration (set from main thread before Play) ----
    int64_t m_total_frames{0};
    int32_t m_fps_num{24};
    int32_t m_fps_den{1};
    double m_fps{24.0};  // precomputed fps_num/fps_den
    int64_t m_last_displayed_frame{-1};
    uint64_t m_last_new_frame_time{0};  // mach_absolute_time of last new frame delivery
    double m_fractional_frames{0.0};   // video clock accumulator (CVDisplayLink elapsed → frames)
    std::string m_current_clip_id;

    int64_t m_repeat_streak{0};         // consecutive frame repeats (deliverFrame early-return logic)

    // ---- Adaptive frame stride for slow-decode codecs ----
    // When decode takes >2x frame_period, skip video decode on intermediate frames.
    // Audio continues at full rate; position derived from audio clock (no drift).
    int m_frame_stride{1};                    // 1 = normal, N = decode every Nth content frame
    int64_t m_next_decode_frame{-1};          // next content frame to decode
    int m_consecutive_slow_decodes{0};
    int m_consecutive_fast_decodes{0};
    bool m_audio_master_position{false};      // true when PLL should be bypassed
    int64_t m_stride_dropped_count{0};        // diagnostics

    // Audio stall detection — engage audio-master when AOP buffer empties
    int m_consecutive_audio_dry{0};
    int m_consecutive_audio_healthy{0};

    // ---- Predictive stride: deferred until clip transition ----
    // When approaching a clip boundary, query TMB for the next clip's decode
    // speed. If it's slow, record the stride but DON'T apply yet — the current
    // clip is fast and shouldn't stutter. Apply at actual transition.
    int64_t m_current_clip_end_frame{-1};         // timeline end of current clip
    std::string m_current_clip_media_path;         // media path of current clip
    bool m_stride_pre_engaged{false};              // true when stride was set predictively
    int m_pending_stride{0};                       // deferred stride, applied at transition
    static constexpr int64_t STRIDE_LOOKAHEAD = 72;  // ~3s at 25fps (needs margin for prefetch latency)

    static constexpr int SLOW_DECODE_CONSECUTIVE = 3;
    static constexpr int FAST_DECODE_CONSECUTIVE = 10;
    static constexpr double SLOW_DECODE_RATIO = 2.0;     // deliver_ms > 2x frame_period = slow
    static constexpr int MAX_STRIDE = 8;                  // cap at ~3fps for 24fps content
    static constexpr int AUDIO_DRY_CONSECUTIVE = 3;       // 3 ticks of buf=0 → audio-master
    static constexpr int AUDIO_HEALTHY_CONSECUTIVE = 10;  // 10 ticks of buf>0 → back to PLL

    bool shouldDecode(int64_t frame) const;
    void updateStrideDetection(double deliver_ms);

    // ---- A/V sync PLL (phase-locked loop) ----
    // Gently steers video frame accumulator toward audio clock each tick.
    // Eliminates visible skip/hold artifacts while maintaining tight sync.
    static constexpr double PLL_GAIN = 0.03;              // 3% of drift corrected per tick
    static constexpr double PLL_MAX_CORRECTION = 0.15;    // max accumulator nudge per tick (in frames)
    static constexpr double PLL_EMERGENCY_THRESHOLD = 0.2; // 200ms — hard skip/hold as last resort

    // ---- Clip prefetch ----
    // Tracks how far we've supplied TMB with clip data in each direction.
    // displayLinkTick dispatches prefetchClips() when the playhead approaches
    // the prefetch frontier.
    std::atomic<int64_t> m_prefetched_forward{0};   // TMB has clips verified up to here
    std::atomic<int64_t> m_prefetched_backward{0};  // TMB has clips verified back to here
    std::atomic<bool> m_prefetch_pending{false};     // true while a prefetch dispatch is queued

    static constexpr int64_t PREFETCH_LOOKAHEAD = 150;  // ~6s at 25fps
    static constexpr int64_t PREFETCH_MARGIN = 120;      // dispatch this many frames before frontier

    void prefetchClips();            // the prefetch algorithm — runs on main thread
    void resetPrefetchFrontiers();   // direction changed — restart tracking from current pos

    // ---- Dependencies ----
    emp::TimelineMediaBuffer* m_tmb{nullptr};
    GPUVideoSurface* m_surface{nullptr};

    // ---- Audio pump (Phase 3) ----
    PlaybackClock m_clock;
    std::unique_ptr<AudioPump> m_audio_pump;
    aop::AudioOutput* m_aop{nullptr};
    sse::ScrubStretchEngine* m_sse{nullptr};
    std::atomic<bool> m_has_audio{false};
    int32_t m_audio_sample_rate{48000};
    int32_t m_audio_channels{2};

    // ---- Playback diagnostics ring buffers ----
    DiagRing<TickMetric, DIAG_VIDEO_RING_SIZE> m_video_diag;
    DiagRing<PumpMetric, DIAG_AUDIO_RING_SIZE> m_audio_diag;
    TickMetric* m_current_tick{nullptr};

    // Clip transition log — recorded during playback, dumped in diagnostics.
    // Small vector (typically <10 transitions per play session).
    struct ClipTransition {
        size_t tick_index;           // index into m_video_diag
        int64_t frame;               // timeline frame of transition
        std::string clip_id;
        std::string media_path;
    };
    std::vector<ClipTransition> m_clip_transitions;
    size_t m_diag_tick_index{0};     // running tick counter for transition log

    void dumpDiagnostics();

    // ---- CVDisplayLink ----
    void* m_displayLink{nullptr};  // CVDisplayLinkRef (opaque for header)
    uint64_t m_last_host_time{0};

    // ---- Position reporting ----
    std::atomic<int64_t> m_last_reported_frame{-1};
    std::chrono::steady_clock::time_point m_last_report_time;
    PositionCallback m_position_callback;
    ClipProviderCallback m_clip_provider;
    ClipTransitionCallback m_clip_transition_callback;
    std::mutex m_callback_mutex;

    // Position report interval (100ms coalescing)
    static constexpr int64_t REPORT_INTERVAL_MS = 100;
};

#else
// Non-Apple: stub implementation
class PlaybackController {
public:
    static std::unique_ptr<PlaybackController> Create() { return nullptr; }
    ~PlaybackController() = default;

    void SetSurface(GPUVideoSurface*) {}
    void SetTMB(emp::TimelineMediaBuffer*) {}
    void SetBounds(int64_t, int32_t, int32_t) {}

    void Play(int, float) {}
    void Stop() {}
    void Park(int64_t) {}
    void Seek(int64_t) {}

    void ActivateAudio(aop::AudioOutput*, sse::ScrubStretchEngine*, int32_t, int32_t) {}
    void DeactivateAudio() {}
    void SetSpeed(float) {}
    void PlayBurst(int64_t, int, int) {}
    bool HasAudio() const { return false; }
    void SetShuttleMode(bool) {}
    bool HitBoundary() const { return false; }

    using PositionCallback = std::function<void(int64_t frame, bool stopped)>;
    void SetPositionCallback(PositionCallback) {}

    using ClipProviderCallback = std::function<void(int64_t from, int64_t to, emp::TrackType type)>;
    void SetClipProvider(ClipProviderCallback) {}

    using ClipTransitionCallback = std::function<void(const std::string& clip_id,
        int rotation, int par_num, int par_den, bool offline,
        const std::string& media_path, int64_t frame)>;
    void SetClipTransitionCallback(ClipTransitionCallback) {}

    void reloadAllClips() {}

    int64_t CurrentFrame() const { return 0; }
    bool IsPlaying() const { return false; }

    struct DiagSummary {
        size_t tick_count{0};
        double cadence_p50_ms{0}; double cadence_p95_ms{0}; double cadence_p99_ms{0};
        double drift_p50_s{0}; double drift_p95_s{0}; double drift_p99_s{0};
        int64_t skip_count{0}; int64_t hold_count{0}; int64_t repeat_count{0};
        int64_t gap_count{0}; int64_t dropped_count{0}; int64_t backward_jumps{0};
        bool audio_master_engaged{false};
    };
    DiagSummary GetDiagSummary() const { return {}; }
};
#endif
