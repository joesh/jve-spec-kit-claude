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
#include <audio_output_platform/aop.h>
#include <scrub_stretch_engine/sse.h>

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
// PlaybackClock implementation
// ============================================================================

void PlaybackClock::Reanchor(int64_t media_time_us, float speed, int64_t aop_playhead_us) {
    m_media_anchor_us.store(media_time_us, std::memory_order_relaxed);
    m_aop_epoch_us.store(aop_playhead_us, std::memory_order_relaxed);
    m_speed.store(speed, std::memory_order_relaxed);
}

int64_t PlaybackClock::CurrentTimeUS(int64_t aop_playhead_us) const {
    int64_t anchor = m_media_anchor_us.load(std::memory_order_relaxed);
    int64_t epoch = m_aop_epoch_us.load(std::memory_order_relaxed);
    float speed = m_speed.load(std::memory_order_relaxed);

    int64_t elapsed_us = aop_playhead_us - epoch;

    // Compensate for audio output latency (OS mixer + driver + DAC)
    // The playhead reports audio consumed by OS, but there's additional delay
    // before it reaches the speakers. Subtract this to sync video with heard audio.
    int64_t compensated_elapsed_us = std::max<int64_t>(0, elapsed_us - OUTPUT_LATENCY_US);

    // Apply speed scaling
    double delta = static_cast<double>(compensated_elapsed_us) * speed;

    // Symmetric rounding: floor for positive speed, ceil for negative
    int64_t result;
    if (speed >= 0) {
        result = anchor + static_cast<int64_t>(std::floor(delta));
    } else {
        result = anchor + static_cast<int64_t>(std::ceil(delta));
    }

    return result;
}

int64_t PlaybackClock::FrameFromTimeUS(int64_t time_us, int32_t fps_num, int32_t fps_den) {
    // frame = time_us * fps_num / (1000000 * fps_den)
    // Use integer math to avoid floating point precision issues
    return (time_us * fps_num) / (1000000LL * fps_den);
}

// ============================================================================
// AudioPump implementation
// ============================================================================

AudioPump::AudioPump() = default;

AudioPump::~AudioPump() {
    Stop();
}

void AudioPump::Start(emp::TimelineMediaBuffer* tmb, sse::ScrubStretchEngine* sse,
                      aop::AudioOutput* aop, PlaybackClock* clock,
                      int32_t sample_rate, int32_t channels) {
    JVE_ASSERT(tmb, "AudioPump::Start: tmb is null");
    JVE_ASSERT(sse, "AudioPump::Start: sse is null");
    JVE_ASSERT(aop, "AudioPump::Start: aop is null");
    JVE_ASSERT(clock, "AudioPump::Start: clock is null");

    if (m_running.load(std::memory_order_relaxed)) {
        return;  // Already running
    }

    m_tmb = tmb;
    m_sse = sse;
    m_aop = aop;
    m_clock = clock;
    m_sample_rate = sample_rate;
    m_channels = channels;
    m_stop_requested.store(false, std::memory_order_relaxed);
    m_running.store(true, std::memory_order_relaxed);

    m_thread = std::thread(&AudioPump::pumpLoop, this);
    qWarning() << "AudioPump: started";
}

void AudioPump::Stop() {
    if (!m_running.load(std::memory_order_relaxed)) {
        return;
    }

    m_stop_requested.store(true, std::memory_order_relaxed);

    if (m_thread.joinable()) {
        m_thread.join();
    }

    m_running.store(false, std::memory_order_relaxed);
    qWarning() << "AudioPump: stopped";
}

bool AudioPump::IsRunning() const {
    return m_running.load(std::memory_order_relaxed);
}

void AudioPump::SetQualityMode(int mode) {
    m_quality_mode.store(mode, std::memory_order_relaxed);
}

int AudioPump::QualityMode() const {
    return m_quality_mode.load(std::memory_order_relaxed);
}

void AudioPump::pumpLoop() {
    // Buffer for rendered audio
    std::vector<float> render_buffer(MAX_RENDER_FRAMES * m_channels);
    int consecutive_dry_cycles = 0;

    while (!m_stop_requested.load(std::memory_order_relaxed)) {
        // 1. Get current media time from clock
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t media_time_us = m_clock->CurrentTimeUS(aop_playhead);
        float speed = m_clock->Speed();
        int mode = m_quality_mode.load(std::memory_order_relaxed);

        // 2. Fetch mixed audio from TMB (2s lookahead)
        constexpr int64_t MIX_LOOKAHEAD_US = 2000000;
        int64_t fetch_start, fetch_end;
        if (speed >= 0) {
            fetch_start = media_time_us;
            fetch_end = media_time_us + MIX_LOOKAHEAD_US;
        } else {
            fetch_start = media_time_us - MIX_LOOKAHEAD_US;
            fetch_end = media_time_us;
        }

        bool pushed_source = false;
        auto pcm = m_tmb->GetMixedAudio(fetch_start, fetch_end);
        if (pcm && pcm->frames() > 0) {
            // 3. Push to SSE (source data for time-stretching)
            m_sse->PushSourcePcm(pcm->data_f32(), pcm->frames(), pcm->start_time_us());
            pushed_source = true;

            // 4. Update SSE target (position + speed + quality)
            m_sse->SetTarget(media_time_us, speed, static_cast<sse::QualityMode>(mode));
        }

        // 5. Render from SSE and write to AOP
        int64_t buffered = m_aop->BufferedFrames();
        int64_t target_frames = (m_sample_rate * TARGET_BUFFER_MS) / 1000;
        int64_t frames_needed = std::max<int64_t>(0, target_frames - buffered);
        frames_needed = std::min<int64_t>(frames_needed, MAX_RENDER_FRAMES);

        int64_t produced = 0;
        if (frames_needed > 0) {
            produced = m_sse->Render(render_buffer.data(), frames_needed);
            if (produced > 0) {
                m_aop->WriteF32(render_buffer.data(), produced);
            }
        }

        // Output invariant: if we pushed source data, SSE must eventually produce frames.
        // Consecutive dry cycles (source pushed but nothing rendered) indicate SSE is broken.
        if (pushed_source && produced == 0 && frames_needed > 0) {
            consecutive_dry_cycles++;
            if (consecutive_dry_cycles >= 50) {
                char buf[256];
                snprintf(buf, sizeof(buf),
                    "AudioPump: SSE produced 0 frames for 50 consecutive cycles "
                    "(media_time=%lld us, speed=%.2f, mode=%d)",
                    (long long)media_time_us, speed, mode);
                JVE_ASSERT(false, buf);
            }
        } else {
            consecutive_dry_cycles = 0;
        }

        // 6. Adaptive sleep based on buffer level
        int sleep_ms;
        int64_t buffered_after = m_aop->BufferedFrames();
        if (buffered_after < target_frames) {
            sleep_ms = PUMP_INTERVAL_HUNGRY_MS;
        } else {
            sleep_ms = PUMP_INTERVAL_OK_MS;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
    }
}

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
    JVE_ASSERT(surface, "PlaybackController::SetSurface: surface is null");
    m_surface = surface;
}

void PlaybackController::SetTMB(emp::TimelineMediaBuffer* tmb) {
    JVE_ASSERT(tmb, "PlaybackController::SetTMB: tmb is null");
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
    JVE_ASSERT(m_tmb,
        "PlaybackController::Play: TMB not set (call SetTMB before Play)");
    JVE_ASSERT(m_surface,
        "PlaybackController::Play: surface not set (call SetSurface before Play)");
    JVE_ASSERT(direction == 1 || direction == -1,
        "PlaybackController::Play: direction must be 1 or -1");
    JVE_ASSERT(speed > 0,
        "PlaybackController::Play: speed must be positive");

    // Direction change invalidates clip windows: next/prev clips were resolved
    // for the OLD direction, need fresh resolution for NEW direction.
    int old_direction = m_direction.load(std::memory_order_relaxed);
    if (old_direction != 0 && old_direction != direction) {
        InvalidateClipWindows();
    }

    m_direction.store(direction, std::memory_order_relaxed);
    m_speed.store(speed, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_audio_position.store(-1, std::memory_order_relaxed);
    m_last_displayed_frame = -1;

    // Hint TMB for pre-buffer at play start
    {
        int64_t pos = m_position.load(std::memory_order_relaxed);
        m_tmb->SetPlayhead(pos, direction, speed);
    }

    // Start audio pump if audio is active
    if (m_has_audio.load(std::memory_order_relaxed)) {
        JVE_ASSERT(m_aop,
            "PlaybackController::Play: has_audio but AOP is null");
        JVE_ASSERT(m_sse,
            "PlaybackController::Play: has_audio but SSE is null");
        // Compute quality mode from speed
        float abs_speed = speed;
        int quality_mode;
        if (abs_speed > 4.0f) {
            quality_mode = 3;  // Q3_DECIMATE
        } else if (abs_speed >= 1.0f) {
            quality_mode = 1;  // Q1
        } else if (abs_speed >= 0.25f) {
            quality_mode = 3;  // Q3_DECIMATE (varispeed)
        } else {
            quality_mode = 2;  // Q2
        }

        // Reanchor clock at current position
        int64_t current_pos = m_position.load(std::memory_order_relaxed);
        int64_t time_us = (current_pos * 1000000LL * m_fps_den) / m_fps_num;
        float signed_speed = direction * speed;

        m_aop->Flush();
        m_sse->Reset();
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        m_clock.Reanchor(time_us, signed_speed, aop_playhead);
        m_sse->SetTarget(time_us, signed_speed, static_cast<sse::QualityMode>(quality_mode));

        // Start audio output
        m_aop->Start();

        // Start pump thread
        if (m_audio_pump) {
            m_audio_pump->SetQualityMode(quality_mode);
            if (!m_audio_pump->IsRunning()) {
                m_audio_pump->Start(m_tmb, m_sse, m_aop, &m_clock,
                                    m_audio_sample_rate, m_audio_channels);
            }
        }
    }

    if (!m_playing.load(std::memory_order_relaxed)) {
        m_playing.store(true, std::memory_order_relaxed);
        startDisplayLink();
    }

    qWarning() << "PlaybackController: Play dir=" << direction << "speed=" << speed
               << "audio=" << m_has_audio.load(std::memory_order_relaxed);
}

void PlaybackController::Stop() {
    if (!m_playing.load(std::memory_order_relaxed)) {
        return;
    }

    m_playing.store(false, std::memory_order_relaxed);
    stopDisplayLink();

    // Stop audio pump and output
    if (m_audio_pump && m_audio_pump->IsRunning()) {
        m_audio_pump->Stop();
    }
    if (m_aop) {
        m_aop->Stop();
        m_aop->Flush();
    }

    // Immediate position report on stop
    int64_t pos = m_position.load(std::memory_order_relaxed);
    reportPosition(pos, true);

    qWarning() << "PlaybackController: Stop at frame" << pos;
}

void PlaybackController::Seek(int64_t frame) {
    JVE_ASSERT(frame >= 0,
        "PlaybackController::Seek: frame must be >= 0");
    JVE_ASSERT(m_tmb,
        "PlaybackController::Seek: TMB not set (call SetTMB before Seek)");
    JVE_ASSERT(m_surface,
        "PlaybackController::Seek: surface not set (call SetSurface before Seek)");
    JVE_ASSERT(m_fps > 0,
        "PlaybackController::Seek: bounds not set (call SetBounds before Seek)");

    m_position.store(frame, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_last_displayed_frame = -1;

    // Tell TMB we're parking (direction=0 → synchronous decode)
    m_tmb->SetPlayhead(frame, 0, 1.0f);
    deliverFrame(frame, true);  // synchronous: Seek is on main thread
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
// Audio pump control (Phase 3)
// ============================================================================

void PlaybackController::ActivateAudio(aop::AudioOutput* aop, sse::ScrubStretchEngine* sse,
                                       int32_t sample_rate, int32_t channels) {
    JVE_ASSERT(aop, "PlaybackController::ActivateAudio: aop is null");
    JVE_ASSERT(sse, "PlaybackController::ActivateAudio: sse is null");
    JVE_ASSERT(sample_rate > 0, "PlaybackController::ActivateAudio: sample_rate must be > 0");
    JVE_ASSERT(channels > 0, "PlaybackController::ActivateAudio: channels must be > 0");

    m_aop = aop;
    m_sse = sse;
    m_audio_sample_rate = sample_rate;
    m_audio_channels = channels;
    m_has_audio.store(true, std::memory_order_relaxed);

    // Create audio pump if needed
    if (!m_audio_pump) {
        m_audio_pump = std::make_unique<AudioPump>();
    }

    qWarning() << "PlaybackController: ActivateAudio" << sample_rate << "Hz" << channels << "ch";
}

void PlaybackController::DeactivateAudio() {
    if (m_audio_pump && m_audio_pump->IsRunning()) {
        m_audio_pump->Stop();
    }
    m_has_audio.store(false, std::memory_order_relaxed);
    m_aop = nullptr;
    m_sse = nullptr;

    qWarning() << "PlaybackController: DeactivateAudio";
}

bool PlaybackController::HasAudio() const {
    return m_has_audio.load(std::memory_order_relaxed);
}

void PlaybackController::SetSpeed(float signed_speed) {
    JVE_ASSERT(signed_speed != 0, "PlaybackController::SetSpeed: speed cannot be zero");

    float abs_speed = std::abs(signed_speed);
    JVE_ASSERT(abs_speed <= 16.0f,
        "PlaybackController::SetSpeed: abs_speed exceeds MAX_SPEED_DECIMATE (16)");

    m_speed.store(abs_speed, std::memory_order_relaxed);
    int dir = (signed_speed >= 0) ? 1 : -1;
    m_direction.store(dir, std::memory_order_relaxed);

    // Auto-select quality mode from abs(speed)
    // >4x        → Q3_DECIMATE (sample-skipping)
    // 1x-4x      → Q1 (editor, pitch-corrected)
    // 0.25x-1x   → Q3_DECIMATE (varispeed, natural pitch drop)
    // <0.25x     → Q2 (extreme slomo, pitch-corrected)
    int quality_mode;
    if (abs_speed > 4.0f) {
        quality_mode = 3;  // Q3_DECIMATE
    } else if (abs_speed >= 1.0f) {
        quality_mode = 1;  // Q1
    } else if (abs_speed >= 0.25f) {
        quality_mode = 3;  // Q3_DECIMATE (varispeed)
    } else {
        quality_mode = 2;  // Q2
    }

    // If playing with audio, reanchor and update pump
    if (m_playing.load(std::memory_order_relaxed) &&
        m_has_audio.load(std::memory_order_relaxed) && m_aop && m_sse) {

        // Capture current position, reanchor clock
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t current_time_us = m_clock.CurrentTimeUS(aop_playhead);

        // Flush SSE for speed change
        m_aop->Flush();
        m_sse->Reset();

        // Reanchor at new speed
        int64_t new_epoch = m_aop->PlayheadTimeUS();
        m_clock.Reanchor(current_time_us, signed_speed, new_epoch);
        m_sse->SetTarget(current_time_us, signed_speed, static_cast<sse::QualityMode>(quality_mode));

        if (m_audio_pump) {
            m_audio_pump->SetQualityMode(quality_mode);
        }
    }

    qWarning() << "PlaybackController: SetSpeed" << signed_speed << "Q" << quality_mode;
}

void PlaybackController::PlayBurst(int64_t frame_idx, int direction, int duration_ms) {
    JVE_ASSERT(m_has_audio.load(std::memory_order_relaxed),
        "PlaybackController::PlayBurst: audio not activated");
    JVE_ASSERT(m_aop, "PlaybackController::PlayBurst: AOP is null");
    JVE_ASSERT(m_sse, "PlaybackController::PlayBurst: SSE is null");
    JVE_ASSERT(m_tmb, "PlaybackController::PlayBurst: TMB is null");
    if (m_playing.load(std::memory_order_relaxed)) {
        return;  // Don't burst while playing — valid guard
    }

    JVE_ASSERT(direction == 1 || direction == -1,
        "PlaybackController::PlayBurst: direction must be 1 or -1");
    JVE_ASSERT(duration_ms > 0 && duration_ms <= 500,
        "PlaybackController::PlayBurst: duration_ms must be 1-500");

    // Convert frame to time
    int64_t time_us = (frame_idx * 1000000LL * m_fps_den) / m_fps_num;
    int64_t duration_us = duration_ms * 1000LL;
    float speed = static_cast<float>(direction);

    // Setup SSE for burst
    m_aop->Stop();
    m_aop->Flush();
    m_sse->Reset();
    m_sse->SetTarget(time_us, speed, sse::QualityMode::Q1);

    // Fetch audio for burst window
    int64_t fetch_start, fetch_end;
    if (direction >= 0) {
        fetch_start = time_us;
        fetch_end = time_us + duration_us + 200000;  // 200ms extra for WSOLA
    } else {
        fetch_start = time_us - duration_us - 200000;
        fetch_end = time_us;
    }

    auto pcm = m_tmb->GetMixedAudio(fetch_start, fetch_end);
    if (pcm && pcm->frames() > 0) {
        m_sse->PushSourcePcm(pcm->data_f32(), pcm->frames(), pcm->start_time_us());
    }

    // Render burst
    int64_t burst_frames = (m_audio_sample_rate * duration_ms) / 1000;
    burst_frames = std::min<int64_t>(burst_frames, 4096);
    std::vector<float> burst_buffer(static_cast<size_t>(burst_frames * m_audio_channels));
    int64_t produced = m_sse->Render(burst_buffer.data(), burst_frames);

    if (produced > 0) {
        m_aop->WriteF32(burst_buffer.data(), produced);
        m_aop->Start();

        // Note: Lua should schedule stop via timer. For now, audio will drain naturally.
    }

    qWarning() << "PlaybackController: PlayBurst frame=" << frame_idx
               << "dir=" << direction << "duration=" << duration_ms << "ms";
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

        JVE_ASSERT(cb,
            "PlaybackController::checkClipWindow: NeedClips callback not set");
        // Dispatch to main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(frame, dir, type);
        });
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
    JVE_ASSERT(result == kCVReturnSuccess,
        "PlaybackController::startDisplayLink: CVDisplayLink creation failed (headless?)");

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

    // Hint TMB for pre-buffer at current position.
    // TMB guaranteed non-null: Play() asserts m_tmb before setting m_playing.
    JVE_ASSERT(m_tmb, "PlaybackController::displayLinkTick: TMB is null (Play invariant violated)");
    {
        int dir = m_direction.load(std::memory_order_relaxed);
        float spd = m_speed.load(std::memory_order_relaxed);
        m_tmb->SetPlayhead(new_pos, dir, spd);
    }

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
    deliverFrame(new_pos, false);  // async: displayLinkTick is on CVDisplayLink thread

    // Coalesced position report
    reportPosition(new_pos, false);
}

// ============================================================================
// Position advancement
// ============================================================================

int64_t PlaybackController::advancePosition(double elapsed_seconds) {
    int64_t current = m_position.load(std::memory_order_relaxed);

    // Audio-following via PlaybackClock (Phase 3)
    if (m_has_audio.load(std::memory_order_relaxed) &&
        m_audio_pump && m_audio_pump->IsRunning() && m_aop) {
        // Audio is master clock — query PlaybackClock for current time
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t time_us = m_clock.CurrentTimeUS(aop_playhead);
        int64_t frame = PlaybackClock::FrameFromTimeUS(time_us, m_fps_num, m_fps_den);

        // Output invariant: position can't teleport.
        // At 60Hz with 8x speed, max sane delta ≈ 8*fps/60 ≈ 3 frames at 24fps.
        // Allow generous margin (240 frames ≈ 10 seconds) to catch clock bugs
        // without false positives from legitimate large seeks.
        int64_t delta = std::abs(frame - current);
        if (delta >= 240) {
            char buf[256];
            snprintf(buf, sizeof(buf),
                "advancePosition: audio-following jumped %lld frames in one tick "
                "(current=%lld, computed=%lld, time_us=%lld, aop=%lld)",
                (long long)delta, (long long)current, (long long)frame,
                (long long)time_us, (long long)aop_playhead);
            JVE_ASSERT(false, buf);
        }

        // Clamp to valid range
        frame = std::max<int64_t>(0, std::min(frame, m_total_frames - 1));
        return frame;
    }

    // Legacy: Check for audio-driven position from Lua (deprecated)
    int64_t audio_pos = m_audio_position.load(std::memory_order_relaxed);
    if (audio_pos >= 0) {
        // Audio is driving — use its position directly
        return audio_pos;
    }

    // Frame-based advancement (no audio)
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

void PlaybackController::deliverFrame(int64_t frame, bool synchronous) {
    // Prerequisites guaranteed by Seek/Play asserts
    JVE_ASSERT(m_tmb, "PlaybackController::deliverFrame: TMB is null");
    JVE_ASSERT(m_surface, "PlaybackController::deliverFrame: surface is null");

    // Frame repeat: only fetch new frame when video time advances
    // (handles 24fps video on 60Hz display — repeats frames 2-3x)
    if (frame == m_last_displayed_frame) {
        return;
    }

    // Audio-only sequence: no video tracks to display
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

            if (synchronous) {
                // Seek path: already on main thread, call directly
                cb(clip_id, rotation, par_num, par_den, offline);
            } else {
                // displayLinkTick path: hop to main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    cb(clip_id, rotation, par_num, par_den, offline);
                });
            }
        }
    }

    if (result.frame) {
        // Mark as displayed ONLY after successful decode.
        // If TMB returns no frame (pending async decode), we must retry
        // on the next CVDisplayLink tick — don't mark as consumed.
        m_last_displayed_frame = frame;

        std::shared_ptr<emp::Frame> frame_ptr = result.frame;
        GPUVideoSurface* surface = m_surface;

        if (synchronous) {
            // Seek path: already on main thread, render immediately.
            // Without this, dispatch_async defers setFrame to the next
            // event loop pass and the parked frame never appears.
            surface->setFrame(frame_ptr);
        } else {
            // displayLinkTick path: dispatch to main thread for Metal rendering
            dispatch_async(dispatch_get_main_queue(), ^{
                surface->setFrame(frame_ptr);
            });
        }
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
