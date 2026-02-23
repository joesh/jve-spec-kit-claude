// PlaybackController - CVDisplayLink-driven playback for VSync-locked frame delivery
//
// This replaces Lua's QTimer-based tick loop with a C++ CVDisplayLink callback
// that runs at VSync rate (~60Hz on most displays). Key benefits:
// - No timer jitter (5-15ms → 0ms)
// - No Lua GC pauses affecting frame timing
// - VSync alignment eliminates tearing
// - Frame repeat logic in C++ for fps mismatch (e.g., 24fps video on 60Hz display)

#include "playback_controller.h"
#include "gpu_video_surface.h"
#include "assert_handler.h"

#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <editor_media_platform/emp_frame.h>

#ifdef __APPLE__

#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <QDebug>

namespace {

// Convert Mach absolute time to seconds
double machTimeToSeconds(uint64_t mach_time) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&timebase);
    });
    return static_cast<double>(mach_time) * timebase.numer / timebase.denom / 1e9;
}

// CVDisplayLink callback (C function, forwards to C++ method)
CVReturn displayLinkCallback(
    CVDisplayLinkRef /*displayLink*/,
    const CVTimeStamp* /*inNow*/,
    const CVTimeStamp* inOutputTime,
    CVOptionFlags /*flagsIn*/,
    CVOptionFlags* /*flagsOut*/,
    void* displayLinkContext)
{
    auto* controller = static_cast<PlaybackController*>(displayLinkContext);
    controller->displayLinkTick(
        mach_absolute_time(),
        inOutputTime->hostTime
    );
    return kCVReturnSuccess;
}

} // anonymous namespace

// ============================================================================
// Factory
// ============================================================================

std::unique_ptr<PlaybackController> PlaybackController::Create() {
    return std::unique_ptr<PlaybackController>(new PlaybackController());
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

PlaybackController::PlaybackController() {
    qWarning() << "PlaybackController: created";
}

PlaybackController::~PlaybackController() {
    Stop();
    qWarning() << "PlaybackController: destroyed";
}

// ============================================================================
// Configuration
// ============================================================================

void PlaybackController::SetSurface(GPUVideoSurface* surface) {
    m_surface = surface;
}

void PlaybackController::SetTMB(emp::TimelineMediaBuffer* tmb) {
    m_tmb = tmb;
}

void PlaybackController::SetVideoTracks(const std::vector<int>& track_indices) {
    m_video_track_indices = track_indices;
}

void PlaybackController::SetBounds(int64_t total_frames, int32_t fps_num, int32_t fps_den) {
    JVE_ASSERT(fps_num > 0 && fps_den > 0,
        "PlaybackController::SetBounds: fps must be positive");
    JVE_ASSERT(total_frames > 0,
        "PlaybackController::SetBounds: total_frames must be positive");

    m_total_frames = total_frames;
    m_fps_num = fps_num;
    m_fps_den = fps_den;
    m_fps = static_cast<double>(fps_num) / fps_den;

    qWarning() << "PlaybackController: SetBounds" << total_frames << "frames @"
               << fps_num << "/" << fps_den << "fps";
}

// ============================================================================
// Transport
// ============================================================================

void PlaybackController::Play(int direction, float speed) {
    // Preconditions: must have bounds set (fps > 0, total_frames > 0)
    JVE_ASSERT(m_fps > 0,
        "PlaybackController::Play: SetBounds must be called before Play");
    JVE_ASSERT(m_total_frames > 0,
        "PlaybackController::Play: total_frames not set (call SetBounds first)");
    // Note: TMB and surface may be null for audio-only playback or testing.
    // Video tracks may be empty for audio-only sequences.
    // These are valid configurations, not errors.
    JVE_ASSERT(direction == 1 || direction == -1,
        "PlaybackController::Play: direction must be 1 or -1");
    JVE_ASSERT(speed > 0,
        "PlaybackController::Play: speed must be positive");

    m_direction.store(direction, std::memory_order_relaxed);
    m_speed.store(speed, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_audio_position.store(-1, std::memory_order_relaxed);
    m_last_displayed_frame = -1;

    if (!m_playing.load(std::memory_order_relaxed)) {
        m_playing.store(true, std::memory_order_relaxed);
        startDisplayLink();
    }

    qWarning() << "PlaybackController: Play dir=" << direction << "speed=" << speed;
}

void PlaybackController::Stop() {
    if (!m_playing.load(std::memory_order_relaxed)) {
        return;
    }

    m_playing.store(false, std::memory_order_relaxed);
    stopDisplayLink();

    // Immediate position report on stop
    int64_t pos = m_position.load(std::memory_order_relaxed);
    reportPosition(pos, true);

    qWarning() << "PlaybackController: Stop at frame" << pos;
}

void PlaybackController::Seek(int64_t frame) {
    JVE_ASSERT(frame >= 0,
        "PlaybackController::Seek: frame must be >= 0");

    m_position.store(frame, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_last_displayed_frame = -1;

    // Display the seeked frame immediately (if we have surface/TMB)
    if (m_surface && m_tmb) {
        deliverFrame(frame);
    }
}

// ============================================================================
// Audio-following
// ============================================================================

void PlaybackController::SetAudioPosition(int64_t frame) {
    m_audio_position.store(frame, std::memory_order_relaxed);
}

// ============================================================================
// Shuttle mode
// ============================================================================

void PlaybackController::SetShuttleMode(bool enabled) {
    m_shuttle_mode.store(enabled, std::memory_order_relaxed);
}

bool PlaybackController::HitBoundary() const {
    return m_hit_boundary.load(std::memory_order_relaxed);
}

// ============================================================================
// Callbacks
// ============================================================================

void PlaybackController::SetPositionCallback(PositionCallback cb) {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_position_callback = std::move(cb);
}

void PlaybackController::SetNeedClipsCallback(NeedClipsCallback cb) {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_need_clips_callback = std::move(cb);
}

void PlaybackController::SetClipTransitionCallback(ClipTransitionCallback cb) {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_clip_transition_callback = std::move(cb);
}

// ============================================================================
// Clip window management
// ============================================================================

void PlaybackController::SetClipWindow(emp::TrackType type, int64_t lo, int64_t hi) {
    ClipWindow& window = (type == emp::TrackType::Video) ? m_video_window : m_audio_window;
    window.lo.store(lo, std::memory_order_relaxed);
    window.hi.store(hi, std::memory_order_relaxed);
    window.valid.store(true, std::memory_order_relaxed);
    window.need_clips_pending.store(false, std::memory_order_relaxed);

    qWarning() << "PlaybackController: SetClipWindow"
               << (type == emp::TrackType::Video ? "video" : "audio")
               << "lo=" << lo << "hi=" << hi;
}

void PlaybackController::InvalidateClipWindows() {
    m_video_window.valid.store(false, std::memory_order_relaxed);
    m_video_window.need_clips_pending.store(false, std::memory_order_relaxed);
    m_audio_window.valid.store(false, std::memory_order_relaxed);
    m_audio_window.need_clips_pending.store(false, std::memory_order_relaxed);
    qWarning() << "PlaybackController: InvalidateClipWindows";
}

void PlaybackController::checkClipWindow(ClipWindow& window, emp::TrackType type, int64_t frame) {
    // Skip if already have a pending request (debounce)
    if (window.need_clips_pending.load(std::memory_order_relaxed)) {
        return;
    }

    int dir = m_direction.load(std::memory_order_relaxed);
    bool need_clips = false;

    if (!window.valid.load(std::memory_order_relaxed)) {
        // Window invalid (never set or invalidated) → need clips
        need_clips = true;
    } else {
        // Check if approaching window edge
        int64_t lo = window.lo.load(std::memory_order_relaxed);
        int64_t hi = window.hi.load(std::memory_order_relaxed);

        if (dir > 0 && frame >= hi - PREFETCH_MARGIN_FRAMES) {
            need_clips = true;  // approaching end of window
        } else if (dir < 0 && frame <= lo + PREFETCH_MARGIN_FRAMES) {
            need_clips = true;  // approaching start of window
        } else if (frame < lo || frame >= hi) {
            need_clips = true;  // outside window entirely
        }
    }

    if (need_clips) {
        // Mark pending to debounce
        window.need_clips_pending.store(true, std::memory_order_relaxed);

        // Copy callback under lock
        NeedClipsCallback cb;
        {
            std::lock_guard<std::mutex> lock(m_callback_mutex);
            cb = m_need_clips_callback;
        }

        if (cb) {
            // Dispatch to main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(frame, dir, type);
            });
        }
    }
}

// ============================================================================
// State queries
// ============================================================================

int64_t PlaybackController::CurrentFrame() const {
    return m_position.load(std::memory_order_relaxed);
}

bool PlaybackController::IsPlaying() const {
    return m_playing.load(std::memory_order_relaxed);
}

// ============================================================================
// CVDisplayLink lifecycle
// ============================================================================

void PlaybackController::startDisplayLink() {
    if (m_displayLink) {
        return;  // Already running
    }

    CVDisplayLinkRef displayLink;
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (result != kCVReturnSuccess) {
        // Headless mode (no display) — can't use CVDisplayLink.
        // This happens in test environments without a GUI.
        qWarning() << "PlaybackController: CVDisplayLink not available (headless mode)";
        return;
    }

    result = CVDisplayLinkSetOutputCallback(displayLink, &displayLinkCallback, this);
    JVE_ASSERT(result == kCVReturnSuccess,
        "PlaybackController: CVDisplayLinkSetOutputCallback failed");

    m_displayLink = displayLink;
    m_last_host_time = mach_absolute_time();

    result = CVDisplayLinkStart(displayLink);
    JVE_ASSERT(result == kCVReturnSuccess,
        "PlaybackController: CVDisplayLinkStart failed");

    qWarning() << "PlaybackController: CVDisplayLink started";
}

void PlaybackController::stopDisplayLink() {
    if (!m_displayLink) {
        return;
    }

    CVDisplayLinkRef displayLink = static_cast<CVDisplayLinkRef>(m_displayLink);
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
    m_displayLink = nullptr;

    qWarning() << "PlaybackController: CVDisplayLink stopped";
}

// ============================================================================
// Display link tick (runs on CVDisplayLink thread)
// ============================================================================

void PlaybackController::displayLinkTick(uint64_t host_time, uint64_t /*output_time*/) {
    if (!m_playing.load(std::memory_order_relaxed)) {
        return;
    }

    // Calculate elapsed time since last tick
    double elapsed = machTimeToSeconds(host_time - m_last_host_time);
    m_last_host_time = host_time;

    // Advance position
    int64_t new_pos = advancePosition(elapsed);
    m_position.store(new_pos, std::memory_order_relaxed);

    // Boundary detection
    int dir = m_direction.load(std::memory_order_relaxed);
    bool hit_start = (dir < 0 && new_pos <= 0);
    bool hit_end = (dir > 0 && new_pos >= m_total_frames - 1);

    if (hit_start || hit_end) {
        int64_t boundary_frame = hit_start ? 0 : (m_total_frames - 1);
        m_position.store(boundary_frame, std::memory_order_relaxed);
        m_hit_boundary.store(true, std::memory_order_relaxed);

        if (!m_shuttle_mode.load(std::memory_order_relaxed)) {
            // Play mode: stop at boundary
            m_playing.store(false, std::memory_order_relaxed);
            // Stop display link on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                stopDisplayLink();
                reportPosition(boundary_frame, true);
            });
            return;
        }
        // Shuttle mode: keep ticking, latched state handled in Lua
    }

    // Check clip windows and fire NeedClips if approaching edge
    checkClipWindow(m_video_window, emp::TrackType::Video, new_pos);
    checkClipWindow(m_audio_window, emp::TrackType::Audio, new_pos);

    // Deliver frame (if it changed)
    deliverFrame(new_pos);

    // Coalesced position report
    reportPosition(new_pos, false);
}

// ============================================================================
// Position advancement
// ============================================================================

int64_t PlaybackController::advancePosition(double elapsed_seconds) {
    int64_t current = m_position.load(std::memory_order_relaxed);

    // Check for audio-driven position
    int64_t audio_pos = m_audio_position.load(std::memory_order_relaxed);
    if (audio_pos >= 0) {
        // Audio is driving — use its position directly
        return audio_pos;
    }

    // Frame-based advancement
    int dir = m_direction.load(std::memory_order_relaxed);
    float speed = m_speed.load(std::memory_order_relaxed);
    double frames_elapsed = elapsed_seconds * m_fps * speed;

    int64_t new_pos = current + static_cast<int64_t>(dir * frames_elapsed);

    // Clamp to valid range
    new_pos = std::max<int64_t>(0, std::min(new_pos, m_total_frames - 1));

    return new_pos;
}

// ============================================================================
// Frame delivery
// ============================================================================

void PlaybackController::deliverFrame(int64_t frame) {
    // Note: TMB and surface may be null during testing or when surface not yet set.
    // This is intentional — Seek() calls deliverFrame() which should be a no-op
    // if display isn't configured yet. Play() is the entry point that requires
    // full configuration; deliverFrame during play tick must have valid deps.
    if (!m_tmb || !m_surface) {
        // During playback, this would be a bug. But we allow it for Seek()
        // when called before full setup.
        return;
    }

    // Frame repeat: only fetch new frame when video time advances
    // (handles 24fps video on 60Hz display — repeats frames 2-3x)
    if (frame == m_last_displayed_frame) {
        return;
    }
    m_last_displayed_frame = frame;

    // Get frame from TMB using first video track (topmost layer)
    // Empty tracks is valid (no video tracks in sequence) — just skip display
    if (m_video_track_indices.empty()) {
        return;
    }

    int track_idx = m_video_track_indices[0];
    emp::TrackId track{emp::TrackType::Video, track_idx};
    emp::VideoResult result = m_tmb->GetVideoFrame(track, frame);

    // Detect clip transition → fire callback with metadata for rotation/PAR
    if (result.clip_id != m_current_clip_id) {
        m_current_clip_id = result.clip_id;

        ClipTransitionCallback cb;
        {
            std::lock_guard<std::mutex> lock(m_callback_mutex);
            cb = m_clip_transition_callback;
        }

        if (cb) {
            std::string clip_id = result.clip_id;
            int rotation = result.rotation;
            int par_num = result.par_num;
            int par_den = result.par_den;
            bool offline = result.offline;

            dispatch_async(dispatch_get_main_queue(), ^{
                cb(clip_id, rotation, par_num, par_den, offline);
            });
        }
    }

    if (result.frame) {
        // Dispatch to main thread for Metal rendering
        std::shared_ptr<emp::Frame> frame_ptr = result.frame;
        GPUVideoSurface* surface = m_surface;

        dispatch_async(dispatch_get_main_queue(), ^{
            surface->setFrame(frame_ptr);
        });
    }
}

// ============================================================================
// Position reporting (coalesced to reduce FFI overhead)
// ============================================================================

void PlaybackController::reportPosition(int64_t frame, bool immediate) {
    auto now = std::chrono::steady_clock::now();

    if (!immediate) {
        // Coalescing: skip if reported recently
        int64_t last_reported = m_last_reported_frame.load(std::memory_order_relaxed);
        if (frame == last_reported) {
            return;
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - m_last_report_time);
        if (elapsed.count() < REPORT_INTERVAL_MS) {
            return;
        }
    }

    m_last_reported_frame.store(frame, std::memory_order_relaxed);
    m_last_report_time = now;

    // Copy callback under lock, then dispatch
    PositionCallback cb;
    {
        std::lock_guard<std::mutex> lock(m_callback_mutex);
        cb = m_position_callback;
    }

    if (cb) {
        bool stopped = !m_playing.load(std::memory_order_relaxed);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(frame, stopped);
        });
    }
}

#endif // __APPLE__
