#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
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
// Video-track visibility filter (mute/solo) — pure, header-only so it is unit
// testable without the Objective-C++ controller.
// ============================================================================
//
// `candidate_tracks` is the TMB's set of video tracks that have clips, already
// ordered top-to-bottom for compositing. `effective` is the visible set resolved
// by Lua (mute/solo applied). Returns the candidates that are visible, order
// preserved. When `effective_valid` is false (Lua hasn't pushed a set yet, e.g.
// at boot) every candidate is visible. An empty valid `effective` set means all
// video tracks are muted → nothing composites.
inline std::vector<int> filterVisibleVideoTracks(
        const std::vector<int>& candidate_tracks,
        const std::vector<int>& effective,
        bool effective_valid) {
    if (!effective_valid) return candidate_tracks;
    std::vector<int> visible;
    visible.reserve(candidate_tracks.size());
    for (int idx : candidate_tracks) {
        for (int e : effective) {
            if (e == idx) { visible.push_back(idx); break; }
        }
    }
    return visible;
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
// PlaybackClock - rate-envelope A/V sync
// ============================================================================
// Tracks media time using AOP playhead as master clock. Holds a sorted
// rate envelope: each segment is a piecewise-linear projection
//   media = start_media_us + (aop - start_aop_us) * speed
// SetSpeed during play APPENDS a segment scheduled to take effect when
// the QAudioSink+ring drain catches up to it (~75-150ms ahead). Audio
// device drains the prior segment's queued output at the prior rate;
// the clock returns that prior projection until aop crosses the new
// segment's start_aop. This matches what the user actually hears
// across a key-repeat speed ramp.
//
// Reanchor is the hard-reset primitive (cold start, direction flip,
// mix-flush, seek): it clears the deque and pushes a single segment.
class PlaybackClock {
public:
    // Reanchor at hard transport event: clears the rate envelope and
    // installs one segment. Used for Play, seek, direction flip,
    // mix-change flush — anywhere the audio device gets re-anchored.
    void Reanchor(int64_t media_time_us, float speed, int64_t aop_playhead_us);

    // Append a future speed transition at aop_at_us. Coalesces any
    // pending segments scheduled AFTER aop_at_us (a press faster than
    // the prior press's drain trims the prior pending transition).
    // No-op if there is no prior segment — caller must Reanchor first.
    void ScheduleSpeedChange(float new_speed, int64_t aop_at_us);

    // Get current media time from AOP playhead. Walks the rate
    // envelope to find the segment active at (aop - output_latency).
    int64_t CurrentTimeUS(int64_t aop_playhead_us) const;

    // Convert media time to frame index
    static int64_t FrameFromTimeUS(int64_t time_us, int32_t fps_num, int32_t fps_den);

    // Measure output latency from CoreAudio device properties.
    // Call once when audio session is activated. Falls back to DEFAULT_LATENCY_US on failure.
    void MeasureOutputLatency(uint32_t device_id, int32_t sample_rate);

    // Getters for pump loop. Speed() returns the LATEST scheduled
    // segment's speed (the target the SSE renders new samples at).
    float Speed() const;

    // The CURRENTLY-AUDIBLE rate (the active segment at heard_aop).
    // Use this when video must track the rate the user is actually
    // hearing — e.g., advancePosition's frame stride during a
    // shuttle-ladder keypress, where m_speed has staged the new
    // target but the audio device is still draining the prior rate.
    float ActiveSpeed(int64_t aop_playhead_us) const;
    int64_t OutputLatencyUS() const { return m_output_latency_us.load(std::memory_order_relaxed); }

    // Set the QAudioSink buffer latency (call after each AOP Start).
    // Total output latency = CoreAudio device latency + sink buffer.
    // This is ALSO the drain duration used by ScheduleSpeedChange's
    // default scheduling offset (see PlaybackController::SetSpeed).
    void SetSinkBufferLatency(int64_t sink_us);

public:
    struct Segment {
        int64_t start_aop_us;    // aop_playhead at which this rate takes effect
        int64_t start_media_us;  // media-time projection at start_aop_us
        float   speed;           // signed rate (negative = reverse)
    };
private:
    // Segments sorted by start_aop_us ascending. Stored as an immutable
    // vector swapped via std::atomic_store(shared_ptr) — read path is
    // lock-free: atomic_load the snapshot, walk it. Write path (Reanchor,
    // ScheduleSpeedChange) builds a new vector and swaps the pointer.
    // Only main thread writes; pump + CVDisplayLink tick read concurrently.
    using SegmentVec = std::vector<Segment>;
    std::shared_ptr<SegmentVec> m_segments;
    // Serializes the read-modify-write in ScheduleSpeedChange (load current,
    // append, store new). Held only during pointer manipulation, never
    // touched by the read path. Negligible — single-writer in practice.
    mutable std::mutex m_write_mu;

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

    // Set push end after prefill so pump starts after prefilled range
    void SetLastPushEnd(int64_t us);

    // Set sequence end time so pump can push remaining audio near the end
    void SetEndTimeUS(int64_t us);

    // Per-cycle render cap (independent of buffer sizing).
    static constexpr int MAX_RENDER_FRAMES = 4096;

    // Target buffer duration the pump fills the AOP ring up to. Derived from
    // the AOP at Start() (single source of truth lives in AOP — sized 3× this
    // value). Read for pre-fill sizing in PlaybackController::Play before the
    // pump thread spins up.
    int32_t TargetBufferMs() const { return m_target_buffer_ms; }

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
    std::atomic<int64_t> m_end_time_us{INT64_MAX};

    // Dependencies (set by Start, read by pumpLoop)
    emp::TimelineMediaBuffer* m_tmb{nullptr};
    sse::ScrubStretchEngine* m_sse{nullptr};
    aop::AudioOutput* m_aop{nullptr};
    PlaybackClock* m_clock{nullptr};
    int32_t m_sample_rate{48000};
    int32_t m_channels{2};
    int32_t m_target_buffer_ms{0};  // Set in Start() from m_aop->TargetBufferMs()

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
    void SetMirrorSurface(GPUVideoSurface* surface);  // fullscreen mirror (nullable)
    void ClearMirrorSurface();
    void SetTMB(emp::TimelineMediaBuffer* tmb);
    void SetBounds(int64_t start_frame, int64_t end_frame, int32_t fps_num, int32_t fps_den);

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
    // Drop the already-mixed PCM queued downstream of TMB (SSE lookahead + AOP
    // ring, ~2.6s) so a solo/mute change is heard at the playhead instead of
    // after that stale tail drains. TMB::SetAudioMixParams already cleared the
    // mix cache; this reanchors at the current clock position (same speed) to
    // refill. No-op when not playing with audio. Brief audible discontinuity.
    void FlushAudioForMixChange();
    void PlayBurst(int64_t frame_idx, int direction, int duration_ms);
    bool HasAudio() const;

    // 017 / FR-022: per-engine log tag. Lua engine pushes "<role>:<8-of-seq-id>"
    // on every load(); JVE_LOG_*(Ticks, ...) call sites inside
    // playback_controller.mm can prefix messages with this tag so source /
    // record streams are distinguishable in mixed logs.
    void SetLogTag(const std::string& tag) { m_log_tag = tag; }
    const std::string& LogTag() const { return m_log_tag; }

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

    // Video mute/solo: the set of video track indices that composite into the
    // output, resolved by Lua (renderer.compute_effective_video_indices). Only
    // the COMPOSITE step (deliverFrame) honors this — prefetch/decode keeps all
    // tracks warm so unmuting is instant (no re-decode). Push on every mute/solo
    // change. An empty set means "no video tracks visible" (everything muted).
    void setEffectiveVideoTracks(const std::vector<int>& indices);

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
        double cadence_max_ms;        // single worst gap between successful setFrame calls
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
    void prefillBackwardCache(int64_t pos);
    void prefillAudio(int64_t pos, int direction, float speed);
    // Canonical audio flush-and-resume primitive: drop queued PCM, reanchor at
    // time_us/speed, refill the ring, and RESTART the output device. Shared by
    // prefillAudio, SetSpeed, and FlushAudioForMixChange.
    void prefillAudioAtTime(int64_t time_us, int direction, float abs_speed);

    // Pre-roll timing constants
    static constexpr int PREROLL_POLL_MS = 5;        // cache poll interval
    static constexpr int PREROLL_TIMEOUT_MS = 3000;  // give up after 3s

    // Backward pre-fill: decode this many frames below playhead via forward
    // sequential access. ~2s at 24fps. Warms both video and audio TMB caches.
    static constexpr int64_t BACKWARD_PREFILL_FRAMES = 48;

    // Frame delivery.
    // synchronous=true: Seek (main thread) — direct setFrame + callback calls.
    // synchronous=false: displayLinkTick (CVDisplayLink thread) — dispatch_async to main.
    void deliverFrame(int64_t frame, bool synchronous);

    // Position reporting (coalesced, main thread)
    void reportPosition(int64_t frame, bool immediate);

    // Advance position based on elapsed time or audio
    int64_t advancePosition(double elapsed_seconds);
    void assertNoTeleport(int64_t current, int64_t new_pos, double speed, const char* context);

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
    int64_t m_start_frame{0};
    int64_t m_total_frames{0};  // absolute end frame (exclusive)
    int32_t m_fps_num{24};
    int32_t m_fps_den{1};
    double m_fps{24.0};  // precomputed fps_num/fps_den
    int64_t m_last_displayed_frame{-1};
    uint64_t m_last_new_frame_time{0};  // mach_absolute_time of last new frame delivery
    double m_fractional_frames{0.0};   // video clock accumulator (CVDisplayLink elapsed → frames)
    std::string m_current_clip_id;
    // Offline state of the currently-displayed clip. Tracked alongside
    // m_current_clip_id so deliverFrame fires the clip_transition
    // callback on offline-state changes WITHIN the same clip — a
    // partial-coverage clip transitions online→offline at the coverage
    // boundary; Lua needs that callback to swap the rendered frame for
    // the "Not enough media" offline panel. Without this, the surface
    // would stay frozen on the last decoded frame.
    bool m_current_offline{false};

    int64_t m_repeat_streak{0};         // consecutive frame repeats (deliverFrame early-return logic)

    // ---- Audio-master: bypass PLL when audio clock stalls ----
    bool m_audio_master_position{false};      // true when PLL should be bypassed

    // Audio stall detection — engage audio-master when AOP buffer empties
    int m_consecutive_audio_dry{0};
    int m_consecutive_audio_healthy{0};
    static constexpr int AUDIO_DRY_CONSECUTIVE = 3;       // 3 ticks of buf=0 → audio-master
    static constexpr int AUDIO_HEALTHY_CONSECUTIVE = 10;  // 10 ticks of buf>0 → back to PLL

    // ---- Shuttle free-run mode ----
    // Above this absolute speed, video must NEVER be pinned to the audio
    // clock — SSE can't sustain decimation at extreme rates, the audio
    // device runs dry, and pinning video to the dry audio clock produces
    // multi-frame stalls (~1s gaps between displayed frames at 32×).
    // Shuttle boundary lives at emp::TimelineMediaBuffer::SHUTTLE_FREE_RUN_SPEED
    // (canonical single owner in the lower layer).
    bool m_was_shuttle_mode{false};  // detect transitions back to normal play

    // ---- A/V sync PLL (phase-locked loop) ----
    // Gently steers video frame accumulator toward audio clock each tick.
    // Eliminates visible skip/hold artifacts while maintaining tight sync.
    static constexpr double PLL_GAIN = 0.03;              // 3% of drift corrected per tick
    static constexpr double PLL_MAX_CORRECTION = 0.15;    // max accumulator nudge per tick (in frames)

    // ---- Clip prefetch ----
    // Tracks how far we've supplied TMB with clip data in each direction.
    // displayLinkTick dispatches prefetchClips() when the playhead approaches
    // the prefetch frontier.
    std::atomic<int64_t> m_prefetched_forward{0};   // TMB has clips verified up to here
    std::atomic<int64_t> m_prefetched_backward{0};  // TMB has clips verified back to here
    std::atomic<bool> m_prefetch_pending{false};     // true while a prefetch dispatch is queued

    static constexpr int64_t PREFETCH_LOOKAHEAD = 150;  // ~6s at 25fps @1×
    static constexpr int64_t PREFETCH_MARGIN = 120;      // dispatch this many frames before frontier @1×

    void prefetchClips();            // the prefetch algorithm — runs on main thread
    void resetPrefetchFrontiers();   // direction changed — restart tracking from current pos

    // Speed-scaled horizons. Without scaling, at 32× the 150-frame lookahead
    // is only ~187ms of wall-time lead — far less than the 1–3s a fresh clip's
    // first decode (file open + VT init + first GOP) needs, so the upcoming
    // clip isn't even submitted for READER_WARM until the playhead is already
    // 187ms away. Multiplying by |speed| keeps lead time constant in WALL TIME
    // regardless of shuttle speed. This MUST be paired with proximity-priority
    // READER_WARM picking in `process_next_decode_prep_job` — without (2), the
    // expanded warm queue at high speed overloads the single prep_worker and
    // the imminent clip waits at the queue tail (LIFO over Lua's sequence-
    // ordered insertions), making the freeze WORSE (live-confirmed: 9.8s vs
    // 6.9s pre-scaling).
    int64_t speedScaledLookahead() const {
        float spd = std::max(1.0f, std::abs(m_speed.load(std::memory_order_relaxed)));
        return static_cast<int64_t>(PREFETCH_LOOKAHEAD * spd);
    }
    int64_t speedScaledMargin() const {
        float spd = std::max(1.0f, std::abs(m_speed.load(std::memory_order_relaxed)));
        return static_cast<int64_t>(PREFETCH_MARGIN * spd);
    }

    // ---- Dependencies ----
    emp::TimelineMediaBuffer* m_tmb{nullptr};
    GPUVideoSurface* m_surface{nullptr};
    GPUVideoSurface* m_mirror_surface{nullptr};  // fullscreen mirror (non-owning, nullable)

    // ---- Audio pump (Phase 3) ----
    PlaybackClock m_clock;
    std::unique_ptr<AudioPump> m_audio_pump;
    aop::AudioOutput* m_aop{nullptr};
    sse::ScrubStretchEngine* m_sse{nullptr};
    std::atomic<bool> m_has_audio{false};
    int32_t m_audio_sample_rate{48000};
    int32_t m_audio_channels{2};

    // 017 / FR-022: per-engine log tag set via Lua engine:load().
    std::string m_log_tag;

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
    uint64_t m_tick_start{0};        // mach_absolute_time at displayLinkTick entry
    uint64_t m_tick_end{0};          // mach_absolute_time at displayLinkTick exit

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

    // Effective (visible) video tracks for compositing — written from the main
    // thread (setEffectiveVideoTracks), read on the tick thread (deliverFrame).
    // m_effective_video_tracks_valid is false until Lua first pushes the set;
    // while false deliverFrame composites every track (boot-time default).
    std::vector<int> m_effective_video_tracks;
    bool m_effective_video_tracks_valid{false};
    std::mutex m_effective_video_mutex;

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
    void SetBounds(int64_t, int64_t, int32_t, int32_t) {}

    void Play(int, float) {}
    void Stop() {}
    void Park(int64_t) {}
    void Seek(int64_t) {}

    void FlushAudioForMixChange() {}
    void ActivateAudio(aop::AudioOutput*, sse::ScrubStretchEngine*, int32_t, int32_t) {}
    void DeactivateAudio() {}
    void SetSpeed(float) {}
    void PlayBurst(int64_t, int, int) {}
    bool HasAudio() const { return false; }
    // 017: per-engine log tag — stub variant carries the string for parity.
    void SetLogTag(const std::string&) {}
    const std::string& LogTag() const { static const std::string e; return e; }
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
    void setEffectiveVideoTracks(const std::vector<int>&) {}

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
