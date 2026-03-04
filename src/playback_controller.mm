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
#import <CoreAudio/CoreAudio.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#include "jve_log.h"

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
    const CVTimeStamp* inNow,
    const CVTimeStamp* inOutputTime,
    CVOptionFlags /*flagsIn*/,
    CVOptionFlags* /*flagsOut*/,
    void* displayLinkContext)
{
    auto* controller = static_cast<PlaybackController*>(displayLinkContext);
    uint64_t cb_start = mach_absolute_time();
    // Use inNow->hostTime (vsync-locked) instead of mach_absolute_time()
    // (callback execution time). Vsync timestamps are perfectly periodic;
    // mach_absolute_time() has scheduling jitter → irregular frame timing.
    controller->displayLinkTick(
        inNow->hostTime,
        inOutputTime->hostTime
    );
    uint64_t cb_end = mach_absolute_time();
    double cb_ms = machTimeToSeconds(cb_end - cb_start) * 1000.0;
    if (cb_ms > 10.0) {
        JVE_LOG_WARN(Ticks, "CVDisplayLink callback took %.1fms", cb_ms);
    }
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
    int64_t output_latency = m_output_latency_us.load(std::memory_order_relaxed);

    int64_t elapsed_us = aop_playhead_us - epoch;

    // Compensate for audio output latency (OS mixer + driver + DAC)
    // The playhead reports audio consumed by OS, but there's additional delay
    // before it reaches the speakers. Subtract this to sync video with heard audio.
    int64_t compensated_elapsed_us = std::max<int64_t>(0, elapsed_us - output_latency);

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

void PlaybackClock::MeasureOutputLatency(uint32_t /*device_id*/, int32_t sample_rate) {
    // Query default output device from CoreAudio. AOP uses Qt's QAudioSink which
    // typically picks the default output device, so this measurement is accurate
    // for the common case. Asserts on failure — silent A/V desync is unacceptable.
    {
        char buf[128];
        snprintf(buf, sizeof(buf), "MeasureOutputLatency: sample_rate must be positive, got %d", sample_rate);
        JVE_ASSERT(sample_rate > 0, buf);
    }

    // Get default output device
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioDeviceID);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);

    {
        char buf[128];
        snprintf(buf, sizeof(buf), "MeasureOutputLatency: failed to get default output device (err=%d, device=%u)",
                 static_cast<int>(status), static_cast<unsigned>(device));
        JVE_ASSERT(status == noErr && device != kAudioObjectUnknown, buf);
    }

    UInt32 latency_frames = 0;
    UInt32 safety_frames = 0;

    // Query device latency (frames between app buffer and hardware output)
    addr = {
        kAudioDevicePropertyLatency,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    size = sizeof(UInt32);
    status = AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &latency_frames);

    {
        char buf[128];
        snprintf(buf, sizeof(buf), "MeasureOutputLatency: kAudioDevicePropertyLatency failed (err=%d, device=%u)",
                 static_cast<int>(status), static_cast<unsigned>(device));
        JVE_ASSERT(status == noErr, buf);
    }

    // Query safety offset (additional buffer for glitch-free playback)
    // Safety offset is optional on some devices — warn but continue if missing.
    addr.mSelector = kAudioDevicePropertySafetyOffset;
    size = sizeof(UInt32);
    status = AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &safety_frames);

    if (status != noErr) {
        JVE_LOG_WARN(Audio, "MeasureOutputLatency: kAudioDevicePropertySafetyOffset failed (err=%d), using latency only",
                     static_cast<int>(status));
        safety_frames = 0;
    }

    // Convert frames to microseconds
    UInt32 total_frames = latency_frames + safety_frames;
    int64_t latency_us = (static_cast<int64_t>(total_frames) * 1000000LL) / sample_rate;

    // Sanity bounds: CoreAudio should report 1-500ms; outside = broken device query
    {
        char buf[128];
        snprintf(buf, sizeof(buf), "MeasureOutputLatency: measured %lldus out of sane range [1ms,500ms]",
                 static_cast<long long>(latency_us));
        JVE_ASSERT(latency_us >= 1000 && latency_us <= 500000, buf);
    }

    m_output_latency_us.store(latency_us, std::memory_order_relaxed);
    JVE_LOG_EVENT(Audio, "MeasureOutputLatency: device=%u → %lldus (latency=%u + safety=%u frames @ %dHz)",
                  static_cast<unsigned>(device), static_cast<long long>(latency_us),
                  latency_frames, safety_frames, sample_rate);
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
    JVE_LOG_EVENT(Audio, "AudioPump: started");
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
    JVE_LOG_EVENT(Audio, "AudioPump: stopped");
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
        ++m_pump_cycle;

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

        // Dense startup log: first 10 cycles log every iteration
        if (m_pump_cycle <= 10) {
            JVE_LOG_DETAIL(Audio, "pump[%lld]: aop_ph=%lldus media_t=%lldus fetch=[%lld..%lld]us",
                          (long long)m_pump_cycle, (long long)aop_playhead,
                          (long long)media_time_us,
                          (long long)fetch_start, (long long)fetch_end);
        }

        bool pushed_source = false;
        auto pcm = m_tmb->GetMixedAudio(fetch_start, fetch_end);
        if (pcm && pcm->frames() > 0) {
            // 3. Push to SSE (source data for time-stretching)
            // SetTarget is NOT called here — SSE advances naturally via
            // advance_time() inside Render(). Transport events (Play, SetSpeed)
            // call SetTarget after Reset(). See test_steady_state_render_without_set_target.
            m_sse->PushSourcePcm(pcm->data_f32(), pcm->frames(), pcm->start_time_us());
            pushed_source = true;
        }

        // Dense startup log: push details
        if (m_pump_cycle <= 10 && pcm) {
            JVE_LOG_DETAIL(Audio, "pump[%lld]: pushed %lld frames at t=%lldus",
                          (long long)m_pump_cycle, (long long)pcm->frames(),
                          (long long)pcm->start_time_us());
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

        // Dense startup log: render details
        if (m_pump_cycle <= 10) {
            JVE_LOG_DETAIL(Audio, "pump[%lld]: rendered=%lld needed=%lld buf_before=%lld buf_after=%lld",
                          (long long)m_pump_cycle, (long long)produced,
                          (long long)frames_needed, (long long)buffered,
                          (long long)m_aop->BufferedFrames());
        }

        // Sampled DETAIL log: every 50th cycle
        if (m_pump_cycle % 50 == 0) {
            JVE_LOG_DETAIL(Audio, "pump: media_t=%lldus fetched=%lld rendered=%lld buf=%lld",
                          (long long)media_time_us,
                          pcm ? (long long)pcm->frames() : 0LL,
                          (long long)produced, (long long)buffered);
        }

        // Duplicate fetch detection: only interesting when media_time hasn't
        // advanced (clock stuck), not when the 2s lookahead window overlaps.
        if (media_time_us == m_last_media_time && m_pump_cycle > 1) {
            m_stalled_cycles++;
        } else {
            if (m_stalled_cycles > 5) {
                JVE_LOG_DETAIL(Audio, "pump: clock stalled for %lld cycles at media_t=%lldus",
                              (long long)m_stalled_cycles, (long long)m_last_media_time);
            }
            m_stalled_cycles = 0;
        }
        m_last_media_time = media_time_us;
        m_last_fetch_start = fetch_start;
        m_last_fetch_end = fetch_end;

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

        // 6. Detect AOP underruns (ring buffer emptied → audible click/gap)
        if (m_aop->HadUnderrun()) {
            m_aop->ClearUnderrunFlag();
            ++m_underrun_count;
            JVE_LOG_WARN(Audio, "pump: AOP underrun #%lld at media_t=%lldus buf=%lld",
                        (long long)m_underrun_count, (long long)media_time_us,
                        (long long)m_aop->BufferedFrames());
        }

        // 7. Adaptive sleep based on buffer level
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
    JVE_LOG_EVENT(Ticks, "PlaybackController: created");
}

PlaybackController::~PlaybackController() {
    Stop();
    JVE_LOG_EVENT(Ticks, "PlaybackController: destroyed");
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

void PlaybackController::SetBounds(int64_t total_frames, int32_t fps_num, int32_t fps_den) {
    JVE_ASSERT(fps_num > 0 && fps_den > 0,
        "PlaybackController::SetBounds: fps must be positive");
    JVE_ASSERT(total_frames > 0,
        "PlaybackController::SetBounds: total_frames must be positive");

    m_total_frames = total_frames;
    m_fps_num = fps_num;
    m_fps_den = fps_den;
    m_fps = static_cast<double>(fps_num) / fps_den;

    JVE_LOG_EVENT(Ticks, "PlaybackController: SetBounds %lld frames @ %d/%d fps",
                 (long long)total_frames, fps_num, fps_den);
}

// ============================================================================
// Transport
// ============================================================================

void PlaybackController::prefillVideo(int64_t pos, int direction) {
    // Sync-decode the current frame on every video track into TMB's cache.
    // Mirrors deliverFrame's track iteration. Runs BEFORE CVDisplayLink starts,
    // so the first tick has an immediate cache hit (no stall).
    auto video_tracks = m_tmb->GetVideoTrackIds();
    for (int track_idx : video_tracks) {
        emp::TrackId track{emp::TrackType::Video, track_idx};
        m_tmb->GetVideoFrame(track, pos);  // sync decode, populates cache
    }
    JVE_LOG_DETAIL(Ticks, "Play: pre-filled %zu video track(s) at frame %lld",
                   video_tracks.size(), (long long)pos);
}

void PlaybackController::prefillAudio(int64_t pos, int direction, float speed) {
    JVE_ASSERT(m_aop,
        "PlaybackController::prefillAudio: AOP is null");
    JVE_ASSERT(m_sse,
        "PlaybackController::prefillAudio: SSE is null");

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
    int64_t time_us = (pos * 1000000LL * m_fps_den) / m_fps_num;
    float signed_speed = direction * speed;

    JVE_LOG_DETAIL(Audio, "Play: pre-flush buf=%lld aop_playing=%d",
                  (long long)m_aop->BufferedFrames(),
                  (int)m_aop->IsPlaying());
    m_aop->Flush();
    m_sse->Reset();
    int64_t aop_playhead = m_aop->PlayheadTimeUS();
    m_clock.Reanchor(time_us, signed_speed, aop_playhead);
    m_sse->SetTarget(time_us, signed_speed, static_cast<sse::QualityMode>(quality_mode));

    // Pre-fill: decode audio into the ring buffer BEFORE starting AOP.
    // Fill the full ring buffer capacity (600ms at 3x target) so the pump
    // has enough runway to warm the TMB cache without CoreAudio starving.
    constexpr int64_t PREFILL_LOOKAHEAD_US = 2000000;
    int64_t ring_capacity = 3 * (m_audio_sample_rate * AudioPump::TARGET_BUFFER_MS) / 1000;
    int64_t fetch_t0 = time_us;
    int64_t fetch_t1 = (signed_speed >= 0)
        ? time_us + PREFILL_LOOKAHEAD_US
        : time_us - PREFILL_LOOKAHEAD_US;
    if (fetch_t1 < fetch_t0) std::swap(fetch_t0, fetch_t1);

    auto pcm = m_tmb->GetMixedAudio(fetch_t0, fetch_t1);
    if (pcm && pcm->frames() > 0) {
        m_sse->PushSourcePcm(pcm->data_f32(), pcm->frames(),
                             pcm->start_time_us());
    }

    // Render in chunks until ring buffer is full
    int64_t total_prefilled = 0;
    constexpr int64_t CHUNK = 4096;
    std::vector<float> prefill_buf(CHUNK * m_audio_channels);
    while (total_prefilled < ring_capacity) {
        int64_t want = std::min(CHUNK, ring_capacity - total_prefilled);
        int64_t rendered = m_sse->Render(prefill_buf.data(), want);
        if (rendered <= 0) break;  // SSE starved
        int64_t written = m_aop->WriteF32(prefill_buf.data(), rendered);
        if (written <= 0) break;   // ring buffer full
        total_prefilled += written;
    }
    JVE_LOG_DETAIL(Audio, "Play: pre-filled %lld/%lld frames into ring buffer",
                  (long long)total_prefilled, (long long)ring_capacity);

    // Start audio output — ring buffer now has ~600ms of decoded audio.
    m_aop->Start();
    JVE_LOG_DETAIL(Audio, "Play: post-start aop_ph=%lldus media_anchor=%lldus",
                  (long long)aop_playhead, (long long)time_us);

    // Start pump thread
    if (m_audio_pump) {
        m_audio_pump->SetQualityMode(quality_mode);
        if (!m_audio_pump->IsRunning()) {
            m_audio_pump->Start(m_tmb, m_sse, m_aop, &m_clock,
                                m_audio_sample_rate, m_audio_channels);
        }
    }
}

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

    // State setup
    m_direction.store(direction, std::memory_order_relaxed);
    m_speed.store(speed, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_fractional_frames = 0.0;
    m_last_displayed_frame = -1;
    m_hold_count = 0;
    m_skip_count = 0;

    int64_t pos = m_position.load(std::memory_order_relaxed);

    // Hint TMB for pre-buffer direction
    m_tmb->SetPlayhead(pos, direction, speed);

    // Symmetric prefill: decode first frame(s) synchronously for both media
    // types BEFORE starting outputs. Video prefill mirrors audio prefill —
    // TMB sync-decodes on cache miss, populating the cache so the first
    // CVDisplayLink tick gets an immediate hit (no frozen PENDING frames).
    prefillVideo(pos, direction);
    if (m_has_audio.load(std::memory_order_relaxed)) {
        prefillAudio(pos, direction, speed);
    }

    // Start display link (video output)
    if (!m_playing.load(std::memory_order_relaxed)) {
        m_playing.store(true, std::memory_order_relaxed);
        // Anchor host time BEFORE starting display link so first tick has valid elapsed.
        // Also needed for Tick() when CVDisplayLink is unavailable (headless/--test).
        m_last_host_time = mach_absolute_time();
        startDisplayLink();
    }

    JVE_LOG_EVENT(Ticks, "Play dir=%d speed=%.1f audio=%d",
                 direction, speed, (int)m_has_audio.load(std::memory_order_relaxed));
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
    m_fractional_frames = 0.0;

    // Immediate position report on stop
    int64_t pos = m_position.load(std::memory_order_relaxed);
    reportPosition(pos, true);

    int64_t underruns = m_audio_pump ? m_audio_pump->UnderrunCount() : 0;
    JVE_LOG_EVENT(Ticks, "Stop at frame %lld (ticks=%lld holds=%lld skips=%lld delivers=%lld underruns=%lld)",
                 (long long)pos, (long long)m_advance_count,
                 (long long)m_hold_count, (long long)m_skip_count,
                 (long long)m_deliver_count, (long long)underruns);
}

void PlaybackController::Park(int64_t frame) {
    JVE_ASSERT(frame >= 0,
        "PlaybackController::Park: frame must be >= 0");
    JVE_ASSERT(m_total_frames > 0,
        "PlaybackController::Park: bounds not set (call SetBounds before Park)");
    {
        char buf[128];
        snprintf(buf, sizeof(buf),
            "PlaybackController::Park: frame %lld >= total_frames %lld",
            (long long)frame, (long long)m_total_frames);
        JVE_ASSERT(frame < m_total_frames, buf);
    }
    JVE_ASSERT(m_tmb,
        "PlaybackController::Park: TMB not set (call SetTMB before Park)");
    // No surface assert — Lua handles display in park mode

    m_position.store(frame, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_fractional_frames = 0.0;
    m_last_displayed_frame = -1;

    // Tell TMB we're parking (direction=0 → synchronous decode)
    m_tmb->SetPlayhead(frame, 0, 1.0f);
    JVE_LOG_EVENT(Ticks, "Park: frame=%lld", (long long)frame);
}

void PlaybackController::Seek(int64_t frame) {
    Park(frame);
    JVE_ASSERT(m_surface,
        "PlaybackController::Seek: surface not set (call SetSurface before Seek)");
    JVE_LOG_EVENT(Ticks, "Seek: frame=%lld surface=%p",
                 (long long)frame, (void*)m_surface);
    deliverFrame(frame, true);  // synchronous: Seek is on main thread
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

    // Measure hardware output latency for A/V sync
    m_clock.MeasureOutputLatency(0, sample_rate);

    // Create audio pump if needed
    if (!m_audio_pump) {
        m_audio_pump = std::make_unique<AudioPump>();
    }

    JVE_LOG_EVENT(Audio, "ActivateAudio %d Hz %d ch latency=%lldus",
                  sample_rate, channels, static_cast<long long>(m_clock.OutputLatencyUS()));
}

void PlaybackController::DeactivateAudio() {
    if (m_audio_pump && m_audio_pump->IsRunning()) {
        m_audio_pump->Stop();
    }
    m_has_audio.store(false, std::memory_order_relaxed);
    m_aop = nullptr;
    m_sse = nullptr;

    JVE_LOG_EVENT(Audio, "DeactivateAudio");
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
        m_fractional_frames = 0.0;

        // Reanchor at new speed
        int64_t new_epoch = m_aop->PlayheadTimeUS();
        m_clock.Reanchor(current_time_us, signed_speed, new_epoch);
        m_sse->SetTarget(current_time_us, signed_speed, static_cast<sse::QualityMode>(quality_mode));

        if (m_audio_pump) {
            m_audio_pump->SetQualityMode(quality_mode);
        }
    }

    JVE_LOG_EVENT(Ticks, "SetSpeed %.2f Q%d", signed_speed, quality_mode);
}

void PlaybackController::PlayBurst(int64_t frame_idx, int direction, int duration_ms) {
    JVE_ASSERT(m_has_audio.load(std::memory_order_relaxed),
        "PlaybackController::PlayBurst: audio not activated");
    JVE_ASSERT(m_aop, "PlaybackController::PlayBurst: AOP is null");
    JVE_ASSERT(m_sse, "PlaybackController::PlayBurst: SSE is null");
    JVE_ASSERT(m_tmb, "PlaybackController::PlayBurst: TMB is null");
    JVE_ASSERT(frame_idx >= 0,
        "PlaybackController::PlayBurst: frame_idx must be >= 0");
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

    JVE_LOG_EVENT(Audio, "PlayBurst frame=%lld dir=%d duration=%d ms",
                 (long long)frame_idx, direction, duration_ms);
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
    {
        char buf[128];
        snprintf(buf, sizeof(buf),
            "PlaybackController::SetClipWindow: lo %lld must be < hi %lld",
            (long long)lo, (long long)hi);
        JVE_ASSERT(lo < hi, buf);
    }
    JVE_ASSERT(lo >= 0,
        "PlaybackController::SetClipWindow: lo must be >= 0");

    ClipWindow& window = (type == emp::TrackType::Video) ? m_video_window : m_audio_window;

    bool was_valid = window.valid.load(std::memory_order_relaxed);
    int64_t old_lo = window.lo.load(std::memory_order_relaxed);
    int64_t old_hi = window.hi.load(std::memory_order_relaxed);

    window.lo.store(lo, std::memory_order_relaxed);
    window.hi.store(hi, std::memory_order_relaxed);
    window.valid.store(true, std::memory_order_relaxed);

    // Only clear debounce if window is genuinely new/expanded.
    // If Lua returns the same window (nothing more to load), keep pending=true
    // so checkClipWindow won't re-fire until InvalidateClipWindows().
    bool changed = !was_valid || lo != old_lo || hi != old_hi;
    if (changed) {
        window.need_clips_pending.store(false, std::memory_order_relaxed);
    }

    JVE_LOG_EVENT(Ticks, "SetClipWindow %s lo=%lld hi=%lld changed=%d",
                 (type == emp::TrackType::Video ? "video" : "audio"),
                 (long long)lo, (long long)hi, changed);
}

void PlaybackController::InvalidateClipWindows() {
    m_video_window.valid.store(false, std::memory_order_relaxed);
    m_video_window.need_clips_pending.store(false, std::memory_order_relaxed);
    m_audio_window.valid.store(false, std::memory_order_relaxed);
    m_audio_window.need_clips_pending.store(false, std::memory_order_relaxed);
    JVE_LOG_EVENT(Ticks, "InvalidateClipWindows");
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

bool PlaybackController::startDisplayLink() {
    if (m_displayLink) {
        return true;  // Already running
    }

    CVDisplayLinkRef displayLink;
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (result != kCVReturnSuccess) {
        // CVDisplayLink unavailable — headless / --test mode / no display.
        // Video ticks won't fire but audio can still work.
        JVE_LOG_WARN(Ticks, "CVDisplayLink creation failed (headless?)");
        return false;
    }

    result = CVDisplayLinkSetOutputCallback(displayLink, &displayLinkCallback, this);
    JVE_ASSERT(result == kCVReturnSuccess,
        "PlaybackController: CVDisplayLinkSetOutputCallback failed");

    m_displayLink = displayLink;
    m_last_host_time = mach_absolute_time();

    result = CVDisplayLinkStart(displayLink);
    JVE_ASSERT(result == kCVReturnSuccess,
        "PlaybackController: CVDisplayLinkStart failed");

    JVE_LOG_EVENT(Ticks, "CVDisplayLink started");
    return true;
}

void PlaybackController::stopDisplayLink() {
    if (!m_displayLink) {
        return;
    }

    CVDisplayLinkRef displayLink = static_cast<CVDisplayLinkRef>(m_displayLink);
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
    m_displayLink = nullptr;

    JVE_LOG_EVENT(Ticks, "CVDisplayLink stopped");
}

void PlaybackController::Tick() {
    displayLinkTick(mach_absolute_time(), 0);
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

    // Track per-tick timing jitter: log outliers (>25% off nominal vsync)
    double elapsed_ms = elapsed * 1000.0;
    if (m_advance_count > 2) {
        // After first couple of ticks, expect ~16.7ms (60Hz) or ~8.3ms (120Hz)
        if (elapsed_ms > 22.0 || elapsed_ms < 5.0) {
            JVE_LOG_DETAIL(Ticks, "displayLinkTick: JITTER elapsed=%.2fms (tick %lld)",
                          elapsed_ms, (long long)m_advance_count);
        }
    }

    // ── Full tick timing breakdown ──
    uint64_t t0 = mach_absolute_time();

    // Advance position
    int64_t new_pos = advancePosition(elapsed);
    m_position.store(new_pos, std::memory_order_relaxed);
    uint64_t t1 = mach_absolute_time();

    // Hint TMB for pre-buffer at current position.
    // TMB guaranteed non-null: Play() asserts m_tmb before setting m_playing.
    JVE_ASSERT(m_tmb, "PlaybackController::displayLinkTick: TMB is null (Play invariant violated)");
    {
        int dir = m_direction.load(std::memory_order_relaxed);
        float spd = m_speed.load(std::memory_order_relaxed);
        m_tmb->SetPlayhead(new_pos, dir, spd);
    }
    uint64_t t2 = mach_absolute_time();

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
    uint64_t t3 = mach_absolute_time();

    // Deliver frame (if it changed)
    deliverFrame(new_pos, false);  // async: displayLinkTick is on CVDisplayLink thread
    uint64_t t4 = mach_absolute_time();

    // Coalesced position report
    reportPosition(new_pos, false);
    uint64_t t5 = mach_absolute_time();

    // Full tick timing breakdown: log if any section >5ms
    double total_ms = machTimeToSeconds(t5 - t0) * 1000.0;
    if (total_ms > 5.0) {
        double adv_ms = machTimeToSeconds(t1 - t0) * 1000.0;
        double sph_ms = machTimeToSeconds(t2 - t1) * 1000.0;
        double chk_ms = machTimeToSeconds(t3 - t2) * 1000.0;
        double dlv_ms = machTimeToSeconds(t4 - t3) * 1000.0;
        double rpt_ms = machTimeToSeconds(t5 - t4) * 1000.0;
        JVE_LOG_WARN(Ticks, "tick SLOW %.1fms: advance=%.1f setPlayhead=%.1f "
                     "clipWin=%.1f deliver=%.1f report=%.1f frame=%lld",
                     total_ms, adv_ms, sph_ms, chk_ms, dlv_ms, rpt_ms,
                     (long long)new_pos);
    }
}

// ============================================================================
// Position advancement
// ============================================================================

int64_t PlaybackController::advancePosition(double elapsed_seconds) {
    ++m_advance_count;
    // Input validation: elapsed must be non-negative and sane.
    // CVDisplayLink uses uint64_t subtraction (can't underflow), but guard against
    // stale m_last_host_time from a previous Play session producing a huge elapsed.
    JVE_ASSERT(elapsed_seconds >= 0,
        "advancePosition: elapsed_seconds is negative (clock error)");
    if (elapsed_seconds > 1.0) {
        // First tick after a long pause or stale host_time — discard.
        // Normal tick at 60Hz is ~0.016s. Anything > 1s is not real elapsed time.
        elapsed_seconds = 0.0;
    }

    int64_t current = m_position.load(std::memory_order_relaxed);
    int dir = m_direction.load(std::memory_order_relaxed);
    float speed = m_speed.load(std::memory_order_relaxed);

    // Step 1: Compute PLL correction from current A/V drift (before frame advance).
    // Instead of abrupt skip/hold (which causes visible stutter), gently steer
    // the fractional accumulator rate toward the audio clock each tick.
    // At 60Hz, a 3% correction resolves 1-frame drift in ~14 ticks (~230ms).
    double pll_adjust = 0.0;
    double diff_seconds = 0.0;
    bool has_drift_measurement = false;

    if (m_has_audio.load(std::memory_order_relaxed) &&
        m_audio_pump && m_audio_pump->IsRunning() && m_aop) {

        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t audio_time_us = m_clock.CurrentTimeUS(aop_playhead);
        int64_t video_time_us = (current * 1000000LL * m_fps_den) / m_fps_num;
        diff_seconds = static_cast<double>(video_time_us - audio_time_us) / 1000000.0;
        double drift_frames = diff_seconds * m_fps;
        has_drift_measurement = true;

        // PLL: proportional correction clamped to avoid overshoot.
        // Positive drift = video ahead → slow down (positive pll_adjust subtracted below).
        // Negative drift = video behind → speed up (negative pll_adjust adds below).
        pll_adjust = std::clamp(drift_frames * PLL_GAIN, -PLL_MAX_CORRECTION, PLL_MAX_CORRECTION);
    }

    // Step 2: Frame-based advancement with PLL-adjusted rate.
    // CVDisplayLink elapsed time drives the accumulator; PLL nudges it per-tick.
    // At 60Hz with 24fps content, base adds 0.4 frames/tick. PLL adjusts ±0.15 max.
    m_fractional_frames += elapsed_seconds * m_fps * speed - pll_adjust;
    m_fractional_frames = std::max(0.0, m_fractional_frames);  // never reverse
    auto whole_frames = static_cast<int64_t>(m_fractional_frames);
    m_fractional_frames -= whole_frames;
    int64_t new_pos = current + dir * whole_frames;

    // Step 3: Emergency hard correction (PLL can't recover fast enough).
    if (has_drift_measurement) {
        if (diff_seconds < -PLL_EMERGENCY_THRESHOLD) {
            new_pos += dir;
            ++m_skip_count;
            if (m_advance_count % 30 == 0) {
                JVE_LOG_DETAIL(Ticks, "advancePosition: SKIP drift=%.4fs frame=%lld (skips=%lld)",
                              diff_seconds, (long long)new_pos, (long long)m_skip_count);
            }
        } else if (diff_seconds > PLL_EMERGENCY_THRESHOLD) {
            new_pos = current;
            ++m_hold_count;
            if (m_advance_count % 30 == 0) {
                JVE_LOG_DETAIL(Ticks, "advancePosition: HOLD drift=%.4fs frame=%lld (holds=%lld)",
                              diff_seconds, (long long)current, (long long)m_hold_count);
            }
        }

        // Sampled PLL telemetry
        if (m_advance_count % 60 == 0) {
            JVE_LOG_DETAIL(Ticks, "advancePosition: PLL drift=%.4fs adjust=%.4f frac=%.4f",
                          diff_seconds, pll_adjust, m_fractional_frames);
        }
    }

    // Step 3: Teleport assert + clamp.
    {
        int64_t delta = std::abs(new_pos - current);
        if (delta >= 240) {
            char buf[256];
            snprintf(buf, sizeof(buf),
                "advancePosition: jumped %lld frames in one tick "
                "(current=%lld, new=%lld, elapsed=%.4fs, speed=%.2f)",
                (long long)delta, (long long)current, (long long)new_pos,
                elapsed_seconds, speed);
            JVE_ASSERT(false, buf);
        }
    }

    new_pos = std::max<int64_t>(0, std::min(new_pos, m_total_frames - 1));
    return new_pos;
}

// ============================================================================
// Frame delivery
// ============================================================================

// Frame number → "HH:MM:SS:FF" timecode string (non-drop-frame).
static std::string frameToTC(int64_t frame, int fps) {
    if (fps <= 0) return "??:??:??:??";
    int ff = static_cast<int>(frame % fps);
    int64_t total_sec = frame / fps;
    int ss = static_cast<int>(total_sec % 60);
    int mm = static_cast<int>((total_sec / 60) % 60);
    int hh = static_cast<int>(total_sec / 3600);
    char buf[16];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d:%02d", hh, mm, ss, ff);
    return buf;
}

void PlaybackController::deliverFrame(int64_t frame, bool synchronous) {
    // Prerequisites guaranteed by Seek/Play asserts
    JVE_ASSERT(m_tmb, "PlaybackController::deliverFrame: TMB is null");
    JVE_ASSERT(m_surface, "PlaybackController::deliverFrame: surface is null");

    ++m_deliver_count;

    // Frame repeat: only fetch new frame when video time advances
    // (handles 24fps video on 60Hz display — repeats frames 2-3x)
    if (frame == m_last_displayed_frame) {
        ++m_repeat_streak;
        // Log every 60th repeat when stalling (>3x is suspicious for 24fps/60Hz)
        if (m_repeat_streak > 3 && (m_repeat_streak % 60 == 0)) {
            JVE_LOG_DETAIL(Ticks, "deliverFrame: STUCK repeat=%lld on frame %lld (position not advancing)",
                          (long long)m_repeat_streak, (long long)frame);
        }
        return;
    }
    m_repeat_streak = 0;

    // Ask TMB which video tracks have clips (sorted descending = topmost first).
    // Single source of truth: TMB owns the track list, no mirrored state to race.
    auto video_tracks = m_tmb->GetVideoTrackIds();
    if (video_tracks.empty()) {
        return;
    }

    // Query tracks top-to-bottom (highest index = topmost = highest priority).
    // If the topmost track is a gap at this frame, fall through to the next.
    emp::VideoResult result;
    bool found_frame = false;
    for (int track_idx : video_tracks) {
        emp::TrackId track{emp::TrackType::Video, track_idx};
        result = m_tmb->GetVideoFrame(track, frame);
        if (result.frame || !result.clip_id.empty()) {
            found_frame = true;
            break;
        }
    }

    if (!found_frame) {
        // All tracks are gaps at this frame — gap IS content, show black.
        // This applies to both sync (seek/park) and async (playback).
        // If the next clip's REFILL is slow and the surface stays black
        // through the transition, that's a WARM latency problem to fix
        // in the buffering layer — not a reason to show stale frames.
        JVE_LOG_EVENT(Ticks, "deliverFrame: gap at %s frame=%lld (no clip on %zu tracks)",
                     frameToTC(frame, m_fps_num / m_fps_den).c_str(),
                     (long long)frame, video_tracks.size());
        m_surface->clearFrame();
        m_last_displayed_frame = frame;

        if (!synchronous) {
            // Stale-data detection: only invalidate the clip window when the
            // playhead is INSIDE the window but TMB has no clips. This means
            // the window's clip list is stale (Lua told us clips exist here
            // but TMB disagrees).
            //
            // When the playhead is OUTSIDE the window (before lo or past hi),
            // the gap is expected — checkClipWindow already handles refetching.
            // Invalidating here would create a tight loop: invalidate → NeedClips
            // → Lua sets same window → next tick invalidates again (every tick
            // until playhead crosses into the window).
            int64_t lo = m_video_window.lo.load(std::memory_order_relaxed);
            int64_t hi = m_video_window.hi.load(std::memory_order_relaxed);
            bool inside_window = m_video_window.valid.load(std::memory_order_relaxed) &&
                                frame >= lo && frame < hi;
            if (inside_window) {
                m_video_window.valid.store(false, std::memory_order_relaxed);
                m_video_window.need_clips_pending.store(false, std::memory_order_relaxed);
                JVE_LOG_DETAIL(Ticks, "deliverFrame: GAP inside window [%lld,%lld) at %s frame=%lld — invalidated",
                              (long long)lo, (long long)hi,
                              frameToTC(frame, m_fps_num / m_fps_den).c_str(),
                              (long long)frame);
            }
        }
        return;
    }

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
            std::string media_path = result.media_path;

            if (synchronous) {
                cb(clip_id, rotation, par_num, par_den, offline, media_path);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    cb(clip_id, rotation, par_num, par_den, offline, media_path);
                });
            }
        }
    }

    if (result.frame) {
        m_last_displayed_frame = frame;

        // Frame cadence: measure time between consecutive DISPLAYED frames.
        // At 25fps/60Hz, expect ~40ms (2-3 vsyncs). Log outliers.
        // Measured here (not earlier) so same-frame holds don't corrupt timing.
        {
            uint64_t now = mach_absolute_time();
            if (m_last_new_frame_time > 0) {
                double cadence_ms = machTimeToSeconds(now - m_last_new_frame_time) * 1000.0;
                double expected_ms = 1000.0 / m_fps;  // 40ms at 25fps
                if (cadence_ms > expected_ms * 1.5 || cadence_ms < expected_ms * 0.5) {
                    JVE_LOG_DETAIL(Ticks, "deliverFrame: CADENCE %.1fms (expect %.1fms) frame=%lld",
                                  cadence_ms, expected_ms, (long long)frame);
                }
            }
            m_last_new_frame_time = now;
        }

        if (synchronous) {
            JVE_LOG_EVENT(Ticks, "deliverFrame: sync frame=%lld clip=%s %dx%d",
                         (long long)frame, result.clip_id.c_str(),
                         result.frame->width(), result.frame->height());
        }

        // Sampled DETAIL log: every 30th new frame delivered
        if (m_deliver_count % 30 == 0) {
            JVE_LOG_DETAIL(Ticks, "deliverFrame: frame=%lld clip=%s offline=%d",
                          (long long)frame, result.clip_id.c_str(),
                          (int)result.offline);
        }

        m_surface->setFrame(result.frame);
    } else if (!result.clip_id.empty()) {
        // TMB has a clip at this frame but returned no decoded frame data.
        if (result.offline) {
            // Offline clip: no frame data expected. The Lua renderer handles
            // offline frames via offline_frame_cache. Not a decode failure.
            JVE_LOG_EVENT(Ticks, "deliverFrame: offline clip=%s frame=%lld",
                         result.clip_id.c_str(), (long long)frame);
        } else if (synchronous) {
            // Online clip with no frame on sync seek = real decode failure
            char buf[256];
            snprintf(buf, sizeof(buf),
                "PlaybackController::deliverFrame: Seek to frame %lld returned no frame "
                "data but clip_id='%s' (decode failure?)",
                (long long)frame, result.clip_id.c_str());
            JVE_ASSERT(false, buf);
        } else if (m_deliver_count % 30 == 0) {
            JVE_LOG_DETAIL(Ticks, "deliverFrame: NULL FRAME clip=%s frame=%lld offline=%d",
                          result.clip_id.c_str(), (long long)frame,
                          (int)result.offline);
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
