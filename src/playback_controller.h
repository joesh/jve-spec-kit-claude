#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Forward declarations
class GPUVideoSurface;

namespace emp {
class TimelineMediaBuffer;
class Frame;
struct VideoResult;
enum class TrackType;
}

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
    void SetVideoTracks(const std::vector<int>& track_indices);
    void SetBounds(int64_t total_frames, int32_t fps_num, int32_t fps_den);

    // Transport (from Lua, main thread)
    void Play(int direction, float speed);
    void Stop();
    void Seek(int64_t frame);

    // Audio-following (from Lua audio tick)
    void SetAudioPosition(int64_t frame);

    // Shuttle mode
    void SetShuttleMode(bool enabled);
    bool HitBoundary() const;

    // Position callback (fires on main thread, coalesced)
    using PositionCallback = std::function<void(int64_t frame, bool stopped)>;
    void SetPositionCallback(PositionCallback cb);

    // NeedClips callback (fires on main thread when approaching clip window edge)
    // Args: frame_idx, direction, track_type
    using NeedClipsCallback = std::function<void(int64_t frame, int direction, emp::TrackType type)>;
    void SetNeedClipsCallback(NeedClipsCallback cb);

    // Clip transition callback (fires on main thread when displayed clip changes)
    // Args: clip_id, rotation, par_num, par_den, is_offline
    using ClipTransitionCallback = std::function<void(const std::string& clip_id,
        int rotation, int par_num, int par_den, bool offline)>;
    void SetClipTransitionCallback(ClipTransitionCallback cb);

    // Clip window management (Lua sets after resolving clips)
    void SetClipWindow(emp::TrackType type, int64_t lo, int64_t hi);
    void InvalidateClipWindows();  // marks both windows stale → next tick fires NeedClips

    // State queries (thread-safe)
    int64_t CurrentFrame() const;
    bool IsPlaying() const;

    // CVDisplayLink callback (runs on display link thread)
    // Public because it's called from C callback function
    void displayLinkTick(uint64_t host_time, uint64_t output_time);

private:
    PlaybackController();

    // Frame delivery (called from displayLinkTick)
    void deliverFrame(int64_t frame);

    // Position reporting (coalesced, main thread)
    void reportPosition(int64_t frame, bool immediate);

    // Advance position based on elapsed time or audio
    int64_t advancePosition(double elapsed_seconds);

    // CVDisplayLink setup/teardown
    void startDisplayLink();
    void stopDisplayLink();

    // ---- Atomics for cross-thread access ----
    std::atomic<int64_t> m_position{0};
    std::atomic<int64_t> m_audio_position{-1};  // -1 = not set
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
    std::string m_current_clip_id;

    // ---- Clip windows ----
    // Track valid frame ranges where TMB has clips loaded.
    // When playhead approaches edge, fire NeedClips callback.
    struct ClipWindow {
        std::atomic<int64_t> lo{0};
        std::atomic<int64_t> hi{0};
        std::atomic<bool> valid{false};
        std::atomic<bool> need_clips_pending{false};  // debounce: request in flight
    };
    ClipWindow m_video_window;
    ClipWindow m_audio_window;
    static constexpr int64_t PREFETCH_MARGIN_FRAMES = 30;  // ~1s at 24fps

    // ---- Dependencies ----
    emp::TimelineMediaBuffer* m_tmb{nullptr};
    GPUVideoSurface* m_surface{nullptr};
    std::vector<int> m_video_track_indices;

    // ---- CVDisplayLink ----
    void* m_displayLink{nullptr};  // CVDisplayLinkRef (opaque for header)
    uint64_t m_last_host_time{0};

    // ---- Position reporting ----
    std::atomic<int64_t> m_last_reported_frame{-1};
    std::chrono::steady_clock::time_point m_last_report_time;
    PositionCallback m_position_callback;
    NeedClipsCallback m_need_clips_callback;
    ClipTransitionCallback m_clip_transition_callback;
    std::mutex m_callback_mutex;

    // Position report interval (100ms coalescing)
    static constexpr int64_t REPORT_INTERVAL_MS = 100;

    // Check clip window and fire NeedClips if approaching edge
    void checkClipWindow(ClipWindow& window, emp::TrackType type, int64_t frame);
};

#else
// Non-Apple: stub implementation
class PlaybackController {
public:
    static std::unique_ptr<PlaybackController> Create() { return nullptr; }
    ~PlaybackController() = default;

    void SetSurface(GPUVideoSurface*) {}
    void SetTMB(emp::TimelineMediaBuffer*) {}
    void SetVideoTracks(const std::vector<int>&) {}
    void SetBounds(int64_t, int32_t, int32_t) {}

    void Play(int, float) {}
    void Stop() {}
    void Seek(int64_t) {}

    void SetAudioPosition(int64_t) {}
    void SetShuttleMode(bool) {}
    bool HitBoundary() const { return false; }

    using PositionCallback = std::function<void(int64_t frame, bool stopped)>;
    void SetPositionCallback(PositionCallback) {}

    using NeedClipsCallback = std::function<void(int64_t frame, int direction, emp::TrackType type)>;
    void SetNeedClipsCallback(NeedClipsCallback) {}

    using ClipTransitionCallback = std::function<void(const std::string& clip_id,
        int rotation, int par_num, int par_den, bool offline)>;
    void SetClipTransitionCallback(ClipTransitionCallback) {}

    void SetClipWindow(emp::TrackType, int64_t, int64_t) {}
    void InvalidateClipWindows() {}

    int64_t CurrentFrame() const { return 0; }
    bool IsPlaying() const { return false; }
};
#endif
