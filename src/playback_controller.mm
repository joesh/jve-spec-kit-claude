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

// Flag-to-string helpers for diagnostics dump
std::string tickFlagsStr(uint8_t flags) {
    if (flags == 0) return "";
    std::string s;
    if (flags & TickFlags::SKIP) s += "SKIP|";
    if (flags & TickFlags::HOLD) s += "HOLD|";
    if (flags & TickFlags::REPEAT) s += "REPEAT|";
    if (flags & TickFlags::PREFETCH) s += "PREFETCH|";
    if (flags & TickFlags::GAP) s += "GAP|";
    if (flags & TickFlags::TRANSITION) s += "TRANSITION|";
    if (flags & TickFlags::OFFLINE) s += "OFFLINE|";
    if (flags & TickFlags::DROPPED) s += "DROPPED|";
    if (!s.empty()) s.pop_back();
    return s;
}

std::string pumpFlagsStr(uint8_t flags) {
    if (flags == 0) return "";
    std::string s;
    if (flags & PumpFlags::UNDERRUN) s += "UNDERRUN|";
    if (flags & PumpFlags::STALL) s += "STALL|";
    if (flags & PumpFlags::DRY) s += "DRY|";
    if (!s.empty()) s.pop_back();
    return s;
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

    m_device_latency_us = latency_us;
    m_output_latency_us.store(latency_us, std::memory_order_relaxed);
    JVE_LOG_EVENT(Audio, "MeasureOutputLatency: device=%u → %lldus (latency=%u + safety=%u frames @ %dHz)",
                  static_cast<unsigned>(device), static_cast<long long>(latency_us),
                  latency_frames, safety_frames, sample_rate);
}

void PlaybackClock::SetSinkBufferLatency(int64_t sink_us) {
    {
        char buf[128];
        snprintf(buf, sizeof(buf),
            "SetSinkBufferLatency: sink_us=%lld out of sane range [0, 500ms]",
            (long long)sink_us);
        JVE_ASSERT(sink_us >= 0 && sink_us <= 500000, buf);
    }
    int64_t total = m_device_latency_us + sink_us;
    {
        char buf[128];
        snprintf(buf, sizeof(buf),
            "SetSinkBufferLatency: total=%lldus (device=%lld + sink=%lld) out of sane range [1ms, 1s]",
            (long long)total, (long long)m_device_latency_us, (long long)sink_us);
        JVE_ASSERT(total >= 1000 && total <= 1000000, buf);
    }
    m_output_latency_us.store(total, std::memory_order_relaxed);
    JVE_LOG_EVENT(Audio, "SetSinkBufferLatency: sink=%lldus device=%lldus total=%lldus",
                  (long long)sink_us, (long long)m_device_latency_us, (long long)total);
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
                      int32_t sample_rate, int32_t channels,
                      DiagRing<PumpMetric, DIAG_AUDIO_RING_SIZE>* diag) {
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
    m_diag = diag;
    m_stop_requested.store(false, std::memory_order_relaxed);
    m_running.store(true, std::memory_order_relaxed);
    ResetPushState();

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

void AudioPump::ResetPushState() {
    m_last_push_end_us.store(-1, std::memory_order_relaxed);
}

void AudioPump::SetQualityMode(int mode) {
    m_quality_mode.store(mode, std::memory_order_relaxed);
}

int AudioPump::QualityMode() const {
    return m_quality_mode.load(std::memory_order_relaxed);
}

void AudioPump::pumpLoop() {
    std::vector<float> render_buffer(MAX_RENDER_FRAMES * m_channels);
    int consecutive_dry_cycles = 0;
    int64_t stalled_cycles = 0;
    int64_t last_media_time = -1;

    while (!m_stop_requested.load(std::memory_order_relaxed)) {
        // 1. Get current media time from clock
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t media_time_us = m_clock->CurrentTimeUS(aop_playhead);
        float speed = m_clock->Speed();
        int mode = m_quality_mode.load(std::memory_order_relaxed);

        // 2. Incremental push: extract each time range ONCE, no re-extraction.
        //
        // Two concerns must be addressed simultaneously:
        // (a) Never re-push overlapping audio (causes ±1 sample pops from
        //     integer truncation in μs→sample conversion)
        // (b) Always call GetMixedAudio every cycle (keeps TMB audio cache
        //     warm — skipping causes cache misses → decode stalls → stutters)
        //
        // Solution: always fetch from SSE's current position (cache warming),
        // but only push to SSE when we need new data (from last_end onwards).
        constexpr int64_t MIX_LOOKAHEAD_US = 2000000;
        constexpr int64_t REFILL_THRESHOLD_US = 1000000;  // push when < 1s ahead

        int64_t last_end = m_last_push_end_us.load(std::memory_order_relaxed);
        int64_t sse_time = m_sse->CurrentTimeUS();

        // Always fetch from SSE position to keep TMB cache warm.
        // This ensures that when we DO push, the data is already decoded.
        int64_t warm_start, warm_end;
        if (speed >= 0) {
            warm_start = sse_time;
            warm_end = sse_time + MIX_LOOKAHEAD_US;
        } else {
            warm_start = sse_time - MIX_LOOKAHEAD_US;
            warm_end = sse_time;
        }
        m_tmb->GetMixedAudio(warm_start, warm_end);  // result discarded — cache warming

        // Decide whether SSE needs more source data
        bool need_push = false;
        int64_t push_start = 0;
        if (last_end < 0) {
            // First push after reset — full window from SSE position
            need_push = true;
            push_start = sse_time;
        } else if (speed >= 0) {
            if (last_end - sse_time < REFILL_THRESHOLD_US) {
                need_push = true;
                push_start = last_end;
            }
        } else {
            if (sse_time - last_end < REFILL_THRESHOLD_US) {
                need_push = true;
                push_start = last_end;
            }
        }

        bool pushed_source = false;

        if (need_push) {
            // Align push_start to a sample boundary to prevent ±1 sample
            // discontinuity at chunk joins. Without alignment:
            //   chunk A end = start + (frames * 1e6) / sr  (truncated)
            //   chunk B start = that truncated value
            //   TMB extract: sample_idx = (offset * sr) / 1e6  (truncated again)
            // Double truncation can skip or repeat 1 sample at the boundary.
            // With alignment: boundaries fall on exact sample positions.
            // NSF: push_start must be non-negative. Playhead is clamped to [0, total_frames)
            // and sse_time starts at 0, so this should always hold. If reverse playback
            // ever crosses time 0, the floor division below handles it correctly.
            JVE_ASSERT(push_start >= 0,
                "AudioPump: push_start is negative — unexpected reverse past time 0");
            // Floor to second boundary. Integer division truncates toward zero, which
            // equals floor for non-negative values. For negative values (defensive):
            // subtract (denominator-1) before dividing to get true floor.
            int64_t denom = 1000000LL;
            int64_t aligned_start = (push_start >= 0)
                ? (push_start / denom) * denom
                : ((push_start - denom + 1) / denom) * denom;
            int64_t offset_us = push_start - aligned_start;
            int64_t offset_samples = (offset_us * m_sample_rate) / 1000000LL;
            int64_t aligned_push = aligned_start + (offset_samples * 1000000LL) / m_sample_rate;

            int64_t fetch_start, fetch_end;
            if (speed >= 0) {
                fetch_start = aligned_push;
                fetch_end = aligned_push + MIX_LOOKAHEAD_US;
            } else {
                fetch_end = aligned_push;
                fetch_start = aligned_push - MIX_LOOKAHEAD_US;
            }

            auto pcm = m_tmb->GetMixedAudio(fetch_start, fetch_end);

            if (pcm && pcm->frames() > 0) {
                // Push to SSE (source data for time-stretching).
                // SetTarget is NOT called here — SSE advances naturally via
                // advance_time() inside Render(). Transport events (Play, SetSpeed)
                // call SetTarget after Reset().
                m_sse->PushSourcePcm(pcm->data_f32(), pcm->frames(), pcm->start_time_us());
                pushed_source = true;

                // Track end of pushed data using sample-aligned arithmetic.
                // Convert frames to μs via the same round-trip to ensure the
                // next push_start aligns to the same sample grid.
                int64_t end_samples = offset_samples + pcm->frames();
                int64_t pcm_end_us = aligned_start + (end_samples * 1000000LL) / m_sample_rate;
                if (speed >= 0) {
                    m_last_push_end_us.store(pcm_end_us, std::memory_order_relaxed);
                } else {
                    m_last_push_end_us.store(pcm->start_time_us(), std::memory_order_relaxed);
                }
            } else {
                // GetMixedAudio returned null — gap in audio clips.
                // Advance last_push_end past the gap so next cycle tries
                // further ahead. Without this, the pump retries the same
                // stale position forever while SSE fills silence.
                JVE_LOG_DETAIL(Audio,
                    "pump: audio gap at [%lld..%lld) us, advancing past",
                    (long long)fetch_start, (long long)fetch_end);
                if (speed >= 0) {
                    m_last_push_end_us.store(fetch_end, std::memory_order_relaxed);
                } else {
                    m_last_push_end_us.store(fetch_start, std::memory_order_relaxed);
                }
            }
        }

        // 3. Render from SSE and write to AOP
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

        // 4. Diagnostics flags
        uint8_t flags = 0;

        // Stall detection (clock not advancing)
        if (media_time_us == last_media_time && last_media_time >= 0) {
            stalled_cycles++;
            if (stalled_cycles > 5) flags |= PumpFlags::STALL;
        } else {
            stalled_cycles = 0;
        }
        last_media_time = media_time_us;

        // Dry detection + assert
        if (pushed_source && produced == 0 && frames_needed > 0) {
            consecutive_dry_cycles++;
            flags |= PumpFlags::DRY;
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

        // 5. AOP underrun detection (WARN stays — rare, important)
        if (m_aop->HadUnderrun()) {
            m_aop->ClearUnderrunFlag();
            ++m_underrun_count;
            flags |= PumpFlags::UNDERRUN;
            JVE_LOG_WARN(Audio, "pump: AOP underrun #%lld at media_t=%lldus buf=%lld",
                        (long long)m_underrun_count, (long long)media_time_us,
                        (long long)m_aop->BufferedFrames());
        }

        // 6. Write ring entry
        if (m_diag) {
            auto& entry = m_diag->next();
            entry.media_time_us = media_time_us;
            entry.aop_playhead_us = aop_playhead;
            entry.fetched_frames = pushed_source ? 1 : 0;  // simplified: was pcm->frames()
            entry.rendered_frames = produced;
            entry.buffered_frames = buffered;
            entry.flags = flags;
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

void PlaybackController::waitForVideoCache(int64_t pos, int timeout_ms) {
    // Poll TMB's video cache until REFILL workers have decoded the playhead frame
    // on every video track. Uses cache_only=true to avoid acquiring reader locks —
    // only reads the video_cache map under m_tracks_mutex (microsecond hold),
    // so there's zero contention with REFILL workers.
    JVE_ASSERT(m_tmb, "PlaybackController::waitForVideoCache: TMB is null");
    JVE_ASSERT(timeout_ms > 0,
        "PlaybackController::waitForVideoCache: timeout_ms must be positive");

    auto video_tracks = m_tmb->GetVideoTrackIds();
    if (video_tracks.empty()) return;

    using clock = std::chrono::steady_clock;
    auto start = clock::now();
    auto deadline = start + std::chrono::milliseconds(timeout_ms);
    int ready = 0;
    int timed_out = 0;

    for (int track_idx : video_tracks) {
        emp::TrackId track{emp::TrackType::Video, track_idx};
        bool got_it = false;
        while (clock::now() < deadline) {
            auto r = m_tmb->GetVideoFrame(track, pos, /*cache_only=*/true);
            // Only state worth polling: clip exists (!clip_id.empty) but
            // decode pending (!frame && !offline). All others are terminal:
            //   frame != null  → cached, ready
            //   offline        → media unavailable, nothing to wait for
            //   clip_id empty  → gap (no clip at this position)
            bool pending = !r.clip_id.empty() && !r.frame && !r.offline;
            if (!pending) {
                ++ready;
                got_it = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(PREROLL_POLL_MS));
        }
        if (!got_it) ++timed_out;
    }

    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        clock::now() - start).count();

    if (timed_out > 0) {
        JVE_LOG_WARN(Ticks,
            "waitForVideoCache: %d/%zu track(s) timed out after %lldms at frame %lld "
            "— starting anyway (adaptive stride will compensate)",
            timed_out, video_tracks.size(), (long long)elapsed_ms, (long long)pos);
    } else {
        JVE_LOG_DETAIL(Ticks, "Play: video cache ready %d/%zu track(s) at frame %lld in %lldms",
                       ready, video_tracks.size(), (long long)pos, (long long)elapsed_ms);
    }
    // Always proceed — adaptive stride + audio-master handle slow codecs at runtime.
    // Timeout is not fatal: it means REFILL workers are slow, not that playback can't start.
}

void PlaybackController::prefillAudio(int64_t pos, int direction, float speed) {
    JVE_ASSERT(m_aop,
        "PlaybackController::prefillAudio: AOP is null");
    JVE_ASSERT(m_sse,
        "PlaybackController::prefillAudio: SSE is null");
    JVE_ASSERT(m_tmb,
        "PlaybackController::prefillAudio: TMB is null");
    JVE_ASSERT(m_fps_num > 0,
        "PlaybackController::prefillAudio: fps_num must be positive");
    JVE_ASSERT(m_audio_sample_rate > 0,
        "PlaybackController::prefillAudio: audio_sample_rate must be positive");
    JVE_ASSERT(m_audio_channels > 0,
        "PlaybackController::prefillAudio: audio_channels must be positive");

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
    if (m_audio_pump) m_audio_pump->ResetPushState();
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
    if (total_prefilled == 0) {
        JVE_LOG_WARN(Audio, "Play: audio pre-fill produced 0 frames "
                     "(ring_capacity=%lld, pcm=%s, time_us=%lld) — "
                     "AOP starts with empty ring buffer",
                     (long long)ring_capacity,
                     pcm ? "non-null" : "null",
                     (long long)time_us);
    } else {
        JVE_LOG_DETAIL(Audio, "Play: pre-filled %lld/%lld frames into ring buffer",
                      (long long)total_prefilled, (long long)ring_capacity);
    }

    // Start audio output — ring buffer has decoded audio (or is empty at gaps).
    m_aop->Start();

    // Add QAudioSink's internal buffer to output latency. MeasureOutputLatency
    // (called in ActivateAudio) measured CoreAudio device + safety offset, but
    // missed the Qt-level buffer between QIODevice::readData and CoreAudio
    // submission. Without this, video runs ahead by sink_buffer_us → audio
    // sounds late by ~2-4 frames.
    m_clock.SetSinkBufferLatency(m_aop->SinkBufferUS());

    JVE_LOG_DETAIL(Audio, "Play: post-start aop_ph=%lldus media_anchor=%lldus",
                  (long long)aop_playhead, (long long)time_us);

    // Start pump thread
    if (m_audio_pump) {
        m_audio_pump->SetQualityMode(quality_mode);
        if (!m_audio_pump->IsRunning()) {
            m_audio_pump->Start(m_tmb, m_sse, m_aop, &m_clock,
                                m_audio_sample_rate, m_audio_channels,
                                &m_audio_diag);
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

    // State setup
    m_direction.store(direction, std::memory_order_relaxed);
    m_speed.store(speed, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_fractional_frames = 0.0;
    m_last_displayed_frame = -1;
    m_video_diag.reset();
    m_audio_diag.reset();
    m_current_tick = nullptr;
    m_clip_transitions.clear();
    m_diag_tick_index = 0;

    // Reset audio stall detection state
    m_audio_master_position = false;
    m_consecutive_audio_dry = 0;
    m_consecutive_audio_healthy = 0;

    int64_t pos = m_position.load(std::memory_order_relaxed);

    auto play_t0 = std::chrono::steady_clock::now();

    // Load clips BEFORE SetPlayhead: cold-start priming (0→1 direction) submits
    // REFILLs for all existing tracks. Clips must be in the TMB at that point,
    // otherwise REFILL finds empty clip lists → 0/48 decoded → 3s timeout.
    // AddClips deduplicates, so re-adding existing clips is a no-op.
    resetPrefetchFrontiers();
    prefetchClips();

    auto t_after_prefetch = std::chrono::steady_clock::now();

    // Set direction (0→1) — triggers cold-start REFILL for all tracks.
    // Clips are now present from prefetchClips() above.
    m_tmb->SetPlayhead(pos, direction, speed);

    auto t_after_setplayhead = std::chrono::steady_clock::now();

    // Pre-roll: wait for REFILL workers to cache the playhead frame on all
    // video tracks. Polls cache_only=true (no reader lock) so there's zero
    // contention with the async REFILL jobs that SetPlayhead() just submitted.
    waitForVideoCache(pos, PREROLL_TIMEOUT_MS);

    auto t_after_videocache = std::chrono::steady_clock::now();

    if (m_has_audio.load(std::memory_order_relaxed)) {
        prefillAudio(pos, direction, speed);
    }

    auto t_after_audio = std::chrono::steady_clock::now();
    auto total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        t_after_audio - play_t0).count();
    if (total_ms > 50) {
        JVE_LOG_WARN(Ticks,
            "Play: SLOW START %lldms at frame %lld — "
            "prefetch=%lldms SetPlayhead=%lldms videoCache=%lldms audio=%lldms",
            (long long)total_ms, (long long)pos,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                t_after_prefetch - play_t0).count(),
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                t_after_setplayhead - t_after_prefetch).count(),
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                t_after_videocache - t_after_setplayhead).count(),
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                t_after_audio - t_after_videocache).count());
    }

    // Start display link (video output)
    if (!m_playing.load(std::memory_order_relaxed)) {
        m_playing.store(true, std::memory_order_relaxed);
        // Anchor host time BEFORE starting display link so first tick has valid elapsed.
        // Also needed for Tick() when CVDisplayLink is unavailable (headless/--test).
        m_last_host_time = mach_absolute_time();
        startDisplayLink();
    }

    JVE_LOG_EVENT(Audio, "Play: has_audio=%d pump_running=%d aop=%p sse=%p",
        (int)m_has_audio.load(std::memory_order_relaxed),
        m_audio_pump ? (int)m_audio_pump->IsRunning() : -1,
        (void*)m_aop, (void*)m_sse);
    JVE_LOG_EVENT(Ticks, "Play dir=%d speed=%.1f audio=%d",
                 direction, speed, (int)m_has_audio.load(std::memory_order_relaxed));
}

void PlaybackController::Stop() {
    // Atomic exchange: eliminates TOCTOU race between boundary auto-stop
    // (sets m_playing=false in displayLinkTick) and explicit Stop() call.
    bool was_playing = m_playing.exchange(false, std::memory_order_relaxed);

    // If not playing AND no diagnostic data → nothing to do
    if (!was_playing && m_video_diag.size() == 0) {
        return;
    }

    // All cleanup steps are idempotent (check their own state guards)
    stopDisplayLink();

    if (m_audio_pump && m_audio_pump->IsRunning()) {
        m_audio_pump->Stop();
    }
    if (m_aop) {
        m_aop->Stop();
        m_aop->Flush();
    }
    m_fractional_frames = 0.0;

    // Position report only when we were playing (avoid double-report on boundary stop)
    if (was_playing) {
        int64_t pos = m_position.load(std::memory_order_relaxed);
        reportPosition(pos, true);
    }

    dumpDiagnostics();
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
    m_direction.store(0, std::memory_order_relaxed);
    m_hit_boundary.store(false, std::memory_order_relaxed);
    m_fractional_frames = 0.0;
    m_last_displayed_frame = -1;

    // Tell TMB we're parking (direction=0 → synchronous decode)
    m_tmb->SetPlayhead(frame, 0, 1.0f);

    // Prefetch clips at parked frame so TMB has clip data for sync decode
    resetPrefetchFrontiers();
    prefetchClips();

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
        if (m_audio_pump) m_audio_pump->ResetPushState();
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

void PlaybackController::SetClipProvider(ClipProviderCallback cb) {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_clip_provider = std::move(cb);
}

void PlaybackController::SetClipTransitionCallback(ClipTransitionCallback cb) {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_clip_transition_callback = std::move(cb);
}

// ============================================================================
// Clip prefetch
// ============================================================================

void PlaybackController::prefetchClips() {
    ClipProviderCallback provider;
    {
        std::lock_guard<std::mutex> lock(m_callback_mutex);
        provider = m_clip_provider;
    }
    if (!provider) {
        // No clip provider set — caller hasn't wired Lua. Skip prefetch.
        m_prefetch_pending.store(false, std::memory_order_relaxed);
        return;
    }

    int64_t current_position = m_position.load(std::memory_order_relaxed);
    int dir = m_direction.load(std::memory_order_relaxed);
    JVE_ASSERT(dir >= -1 && dir <= 1,
        "PlaybackController::prefetchClips: invalid direction");

    // Helper: ask the clip provider to load clips for both video and audio
    // tracks in [from, to). The provider (Lua) queries the DB and calls
    // TMB::AddClips for each clip found in that range.
    auto load_clips_in_range = [&](int64_t from, int64_t to) {
        JVE_ASSERT(from < to,
            "PlaybackController: load_clips_in_range from >= to");
        provider(from, to, emp::TrackType::Video);
        provider(from, to, emp::TrackType::Audio);
    };

    // Dispatch: load clips the playhead will need based on direction.
    switch (dir) {
    case 0: {
        // Park: only need clips at the current frame
        load_clips_in_range(current_position, current_position + 1);
        break;
    }
    case 1: {
        int64_t prefetch_goal = current_position + PREFETCH_LOOKAHEAD;
        int64_t already_fetched = m_prefetched_forward.load(std::memory_order_relaxed);
        if (already_fetched < prefetch_goal) {
            load_clips_in_range(already_fetched, prefetch_goal);
            m_prefetched_forward.store(prefetch_goal, std::memory_order_relaxed);
        }
        break;
    }
    case -1: {
        int64_t prefetch_goal = std::max(int64_t(0), current_position - PREFETCH_LOOKAHEAD);
        int64_t already_fetched = m_prefetched_backward.load(std::memory_order_relaxed);
        if (already_fetched > prefetch_goal) {
            load_clips_in_range(prefetch_goal, already_fetched);
            m_prefetched_backward.store(prefetch_goal, std::memory_order_relaxed);
        }
        break;
    }
    }

    m_prefetch_pending.store(false, std::memory_order_relaxed);
}

void PlaybackController::resetPrefetchFrontiers() {
    int64_t pos = m_position.load(std::memory_order_relaxed);
    m_prefetched_forward.store(pos, std::memory_order_relaxed);
    m_prefetched_backward.store(pos, std::memory_order_relaxed);
    m_prefetch_pending.store(false, std::memory_order_relaxed);
}

void PlaybackController::reloadAllClips() {
    JVE_ASSERT(m_tmb,
        "PlaybackController::reloadAllClips: TMB not set");
    m_tmb->ClearAllClips();
    resetPrefetchFrontiers();
    prefetchClips();
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

    // Ring entry for this tick (zeroed by next())
    auto& tick = m_video_diag.next();
    m_current_tick = &tick;
    tick.elapsed_ms = elapsed * 1000.0;

    // ── Tick timing ──
    uint64_t t0 = mach_absolute_time();

    // Advance position (writes drift_s, pll_adjust, frame, SKIP/HOLD flags)
    int64_t new_pos = advancePosition(elapsed);
    m_position.store(new_pos, std::memory_order_relaxed);
    uint64_t t1 = mach_absolute_time();
    tick.advance_ms = machTimeToSeconds(t1 - t0) * 1000.0;

    // Hint TMB for pre-buffer at current position
    JVE_ASSERT(m_tmb, "PlaybackController::displayLinkTick: TMB is null (Play invariant violated)");
    {
        int dir = m_direction.load(std::memory_order_relaxed);
        float spd = m_speed.load(std::memory_order_relaxed);
        m_tmb->SetPlayhead(new_pos, dir, spd);
    }
    uint64_t t2 = mach_absolute_time();
    tick.setPlayhead_ms = machTimeToSeconds(t2 - t1) * 1000.0;

    // Boundary detection
    int dir = m_direction.load(std::memory_order_relaxed);
    bool hit_start = (dir < 0 && new_pos <= 0);
    bool hit_end = (dir > 0 && new_pos >= m_total_frames - 1);

    if (hit_start || hit_end) {
        int64_t boundary_frame = hit_start ? 0 : (m_total_frames - 1);
        m_position.store(boundary_frame, std::memory_order_relaxed);
        m_hit_boundary.store(true, std::memory_order_relaxed);

        if (!m_shuttle_mode.load(std::memory_order_relaxed)) {
            m_playing.store(false, std::memory_order_relaxed);
            m_current_tick = nullptr;
            dispatch_async(dispatch_get_main_queue(), ^{
                stopDisplayLink();
                reportPosition(boundary_frame, true);
            });
            return;
        }
    }

    // Prefetch: dispatch clip loading when playhead approaches the frontier
    if (!m_prefetch_pending.load(std::memory_order_relaxed)) {
        bool need_prefetch = false;
        if (dir > 0) {
            need_prefetch = (new_pos + PREFETCH_MARGIN >= m_prefetched_forward.load(std::memory_order_relaxed));
        } else if (dir < 0) {
            need_prefetch = (new_pos - PREFETCH_MARGIN <= m_prefetched_backward.load(std::memory_order_relaxed));
        }
        if (need_prefetch) {
            tick.flags |= TickFlags::PREFETCH;
            m_prefetch_pending.store(true, std::memory_order_relaxed);
            dispatch_async(dispatch_get_main_queue(), ^{
                prefetchClips();
            });
        }
    }

    // Deliver frame (TMB stride-fill ensures cache hits at every position)
    uint64_t t3 = mach_absolute_time();
    deliverFrame(new_pos, false);
    uint64_t t4_final = mach_absolute_time();
    tick.deliver_ms = machTimeToSeconds(t4_final - t3) * 1000.0;

    // Coalesced position report
    reportPosition(new_pos, false);
    uint64_t t5 = mach_absolute_time();
    tick.report_ms = machTimeToSeconds(t5 - t4_final) * 1000.0;

    // Audio buffer level
    if (m_has_audio.load(std::memory_order_relaxed) && m_aop) {
        tick.audio_buf_frames = m_aop->BufferedFrames();
    }

    m_current_tick = nullptr;
    ++m_diag_tick_index;
}

// ============================================================================
// Position advancement
// ============================================================================

int64_t PlaybackController::advancePosition(double elapsed_seconds) {
    // Input validation: elapsed must be non-negative and sane.
    JVE_ASSERT(elapsed_seconds >= 0,
        "advancePosition: elapsed_seconds is negative (clock error)");
    if (elapsed_seconds > 1.0) {
        // First tick after a long pause or stale host_time — discard.
        elapsed_seconds = 0.0;
    }

    int64_t current = m_position.load(std::memory_order_relaxed);
    int dir = m_direction.load(std::memory_order_relaxed);
    float speed = m_speed.load(std::memory_order_relaxed);

    // Audio-master detection: engage when PLL can't maintain sync.
    // Trigger: audio stall (buf=0 for AUDIO_DRY_CONSECUTIVE ticks).
    // Frame stride engages independently in updateStrideDetection().
    // When engaged, video position = audio clock position. No PLL, no drift.
    if (m_has_audio.load(std::memory_order_relaxed) &&
        m_audio_pump && m_audio_pump->IsRunning() && m_aop) {

        int64_t buf = m_aop->BufferedFrames();
        int64_t aop_playhead = m_aop->PlayheadTimeUS();
        int64_t audio_time_us = m_clock.CurrentTimeUS(aop_playhead);
        int64_t video_time_us = (current * 1000000LL * m_fps_den) / m_fps_num;
        double drift_s = static_cast<double>(video_time_us - audio_time_us) / 1000000.0;

        // Trigger 1: audio buffer empty (audio clock frozen)
        if (buf == 0) {
            ++m_consecutive_audio_dry;
            m_consecutive_audio_healthy = 0;
            if (m_consecutive_audio_dry >= AUDIO_DRY_CONSECUTIVE && !m_audio_master_position) {
                m_audio_master_position = true;
                JVE_LOG_EVENT(Ticks, "audio-master ON: buf=0 for %d ticks", m_consecutive_audio_dry);
            }
        } else {
            m_consecutive_audio_dry = 0;
            ++m_consecutive_audio_healthy;
        }

        // Recovery: audio buffer healthy
        if (m_audio_master_position &&
            m_consecutive_audio_healthy >= AUDIO_HEALTHY_CONSECUTIVE) {
            m_audio_master_position = false;
            m_fractional_frames = 0.0;
            JVE_LOG_EVENT(Ticks, "audio-master OFF: drift=%.3fs buf=%lld", drift_s, (long long)buf);
        }

        // Audio-master path: derive position directly from audio clock
        if (m_audio_master_position) {
            int64_t new_pos = PlaybackClock::FrameFromTimeUS(audio_time_us, m_fps_num, m_fps_den);
            new_pos = std::max<int64_t>(0, std::min(new_pos, m_total_frames - 1));

            // Postcondition: audio-master must not teleport video.
            // Clock discontinuity (bad reanchor, overflow) would silently jump.
            {
                int64_t delta = std::abs(new_pos - current);
                if (delta >= 240) {
                    char buf[256];
                    snprintf(buf, sizeof(buf),
                        "advancePosition(audio-master): jumped %lld frames in one tick "
                        "(current=%lld, new=%lld, audio_time_us=%lld, drift=%.3fs)",
                        (long long)delta, (long long)current, (long long)new_pos,
                        (long long)audio_time_us, drift_s);
                    JVE_ASSERT(false, buf);
                }
            }

            if (m_current_tick) {
                m_current_tick->drift_s = drift_s;
                m_current_tick->pll_adjust = 0.0;
                m_current_tick->frame = new_pos;
            }
            return new_pos;
        }
    }

    // Step 1: PLL correction from A/V drift.
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

        pll_adjust = std::clamp(drift_frames * PLL_GAIN, -PLL_MAX_CORRECTION, PLL_MAX_CORRECTION);
    }

    // Step 2: Frame-based advancement with PLL-adjusted rate.
    m_fractional_frames += elapsed_seconds * m_fps * speed - pll_adjust;
    m_fractional_frames = std::max(0.0, m_fractional_frames);
    auto whole_frames = static_cast<int64_t>(m_fractional_frames);
    m_fractional_frames -= whole_frames;
    int64_t new_pos = current + dir * whole_frames;

    // Step 3: Write drift to ring.
    if (has_drift_measurement) {
        if (m_current_tick) {
            m_current_tick->drift_s = diff_seconds;
            m_current_tick->pll_adjust = pll_adjust;
        }
    }

    // Step 4: Teleport assert + clamp.
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

    // Write frame to ring
    if (m_current_tick) {
        m_current_tick->frame = new_pos;
    }

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
    JVE_ASSERT(m_tmb, "PlaybackController::deliverFrame: TMB is null");
    JVE_ASSERT(m_surface, "PlaybackController::deliverFrame: surface is null");

    // Frame repeat: only fetch new frame when video time advances
    if (frame == m_last_displayed_frame) {
        ++m_repeat_streak;
        if (m_current_tick) m_current_tick->flags |= TickFlags::REPEAT;
        return;
    }
    m_repeat_streak = 0;

    // Ask TMB which video tracks have clips
    auto video_tracks = m_tmb->GetVideoTrackIds();
    if (video_tracks.empty()) {
        return;
    }

    // Query tracks top-to-bottom. Topmost clip always occludes — if V2 has a
    // clip at this frame, V1 is never visible regardless of cache state.
    // Cache miss during playback → hold last frame (no new setFrame call).
    emp::VideoResult result;
    bool found_frame = false;
    for (int track_idx : video_tracks) {
        emp::TrackId track{emp::TrackType::Video, track_idx};
        auto r = m_tmb->GetVideoFrame(track, frame, /*cache_only=*/!synchronous);
        // DEBUG: log cache hit/miss per track for V2 diagnosis
        if (track_idx > 0 && !r.clip_id.empty()) {
            JVE_LOG_EVENT(Ticks, "deliverFrame: V%d frame=%lld clip=%.8s has_frame=%d",
                track_idx, (long long)frame, r.clip_id.c_str(), (int)(r.frame != nullptr));
        }
        if (r.frame || r.offline || !r.clip_id.empty()) {
            result = r;
            found_frame = true;
            break;
        }
    }

    if (!found_frame) {
        // Gap — show black
        JVE_LOG_EVENT(Ticks, "deliverFrame: gap at %s frame=%lld (no clip on %zu tracks)",
                     frameToTC(frame, m_fps_num / m_fps_den).c_str(),
                     (long long)frame, video_tracks.size());
        m_surface->clearFrame();
        if (!m_current_clip_id.empty()) {
            // Entering gap from a clip — record transition
            m_current_clip_id.clear();
            m_clip_transitions.push_back({m_diag_tick_index, frame, "", "(gap)"});
        }
        m_last_displayed_frame = frame;
        if (m_current_tick) m_current_tick->flags |= TickFlags::GAP;
        return;
    }

    // Clip transition → fire callback with metadata for rotation/PAR.
    // Defer when async cache miss (frame=nullptr, not offline): rotation/PAR
    // aren't populated on cache_only path. Callback fires when REFILL delivers
    // the first cached frame of the new clip.
    bool has_clip_data = result.frame || result.offline || synchronous;
    if (result.clip_id != m_current_clip_id && has_clip_data) {
        m_current_clip_id = result.clip_id;
        if (m_current_tick) m_current_tick->flags |= TickFlags::TRANSITION;

        // Record for diag dump — clip name + timecode at transition point
        m_clip_transitions.push_back({m_diag_tick_index, frame,
                                      result.clip_id, result.media_path});

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
            int64_t trans_frame = frame;

            if (synchronous) {
                cb(clip_id, rotation, par_num, par_den, offline, media_path, trans_frame);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    cb(clip_id, rotation, par_num, par_den, offline, media_path, trans_frame);
                });
            }
        }
    }

    if (result.frame) {
        m_last_displayed_frame = frame;

        // Frame cadence → ring
        {
            uint64_t now = mach_absolute_time();
            if (m_last_new_frame_time > 0 && m_current_tick) {
                m_current_tick->cadence_ms = machTimeToSeconds(now - m_last_new_frame_time) * 1000.0;
            }
            m_last_new_frame_time = now;
        }

        if (synchronous) {
            JVE_LOG_EVENT(Ticks, "deliverFrame: sync frame=%lld clip=%s %dx%d",
                         (long long)frame, result.clip_id.c_str(),
                         result.frame->width(), result.frame->height());
        }

        m_surface->setFrame(result.frame);
    } else if (!result.clip_id.empty()) {
        if (result.offline) {
            m_last_displayed_frame = frame;
            if (m_current_tick) m_current_tick->flags |= TickFlags::OFFLINE;
        } else if (synchronous) {
            char buf[256];
            snprintf(buf, sizeof(buf),
                "PlaybackController::deliverFrame: Seek to frame %lld returned no frame "
                "data but clip_id='%s' (decode failure?)",
                (long long)frame, result.clip_id.c_str());
            JVE_ASSERT(false, buf);
        }
        // Async null frame during playback: captured in ring (no cadence written)
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

// ============================================================================
// Diagnostics dump (writes to /tmp/jve_playback_diag.txt at Stop)
// ============================================================================

PlaybackController::DiagSummary PlaybackController::GetDiagSummary() const {
    DiagSummary s{};
    s.tick_count = m_video_diag.size();
    s.audio_master_engaged = m_audio_master_position;

    if (s.tick_count == 0) return s;

    // Collect values for percentile computation
    std::vector<double> cadences, drifts;
    int64_t prev_frame = -1;

    m_video_diag.for_each([&](const TickMetric& t) {
        if (t.cadence_ms > 0.0) cadences.push_back(t.cadence_ms);
        drifts.push_back(std::abs(t.drift_s));
        if (t.flags & TickFlags::SKIP) ++s.skip_count;
        if (t.flags & TickFlags::HOLD) ++s.hold_count;
        if (t.flags & TickFlags::REPEAT) ++s.repeat_count;
        if (t.flags & TickFlags::GAP) ++s.gap_count;
        if (t.flags & TickFlags::DROPPED) ++s.dropped_count;

        // Backward jump: frame decreased on a non-REPEAT tick (forward playback)
        if (prev_frame >= 0 && !(t.flags & TickFlags::REPEAT) && t.frame < prev_frame) {
            ++s.backward_jumps;
        }
        prev_frame = t.frame;
    });

    std::sort(cadences.begin(), cadences.end());
    std::sort(drifts.begin(), drifts.end());

    auto pctd = [](const std::vector<double>& sorted, double p) -> double {
        if (sorted.empty()) return 0.0;
        size_t idx = static_cast<size_t>(p * static_cast<double>(sorted.size() - 1));
        return sorted[idx];
    };

    s.cadence_p50_ms = pctd(cadences, 0.50);
    s.cadence_p95_ms = pctd(cadences, 0.95);
    s.cadence_p99_ms = pctd(cadences, 0.99);
    s.drift_p50_s = pctd(drifts, 0.50);
    s.drift_p95_s = pctd(drifts, 0.95);
    s.drift_p99_s = pctd(drifts, 0.99);

    return s;
}

void PlaybackController::dumpDiagnostics() {
    size_t video_count = m_video_diag.size();
    if (video_count == 0) {
        int64_t pos = m_position.load(std::memory_order_relaxed);
        JVE_LOG_EVENT(Ticks, "Stop at %s (frame %lld, no ticks recorded)",
                      frameToTC(pos, m_fps_num / m_fps_den).c_str(), (long long)pos);
        return;
    }

    int64_t pos = m_position.load(std::memory_order_relaxed);

    // Compute total duration from elapsed times
    double total_duration_s = 0.0;
    m_video_diag.for_each([&](const TickMetric& t) {
        total_duration_s += t.elapsed_ms / 1000.0;
    });

    // Collect values for percentile computation
    std::vector<double> cadences, delivers, drifts;
    int64_t skip_count = 0, hold_count = 0, repeat_count = 0;
    int64_t gap_count = 0, transition_count = 0, dropped_count = 0;

    m_video_diag.for_each([&](const TickMetric& t) {
        if (t.cadence_ms > 0.0) cadences.push_back(t.cadence_ms);
        delivers.push_back(t.deliver_ms);
        drifts.push_back(std::abs(t.drift_s));
        if (t.flags & TickFlags::SKIP) ++skip_count;
        if (t.flags & TickFlags::HOLD) ++hold_count;
        if (t.flags & TickFlags::REPEAT) ++repeat_count;
        if (t.flags & TickFlags::GAP) ++gap_count;
        if (t.flags & TickFlags::TRANSITION) ++transition_count;
        if (t.flags & TickFlags::DROPPED) ++dropped_count;
    });

    std::sort(cadences.begin(), cadences.end());
    std::sort(delivers.begin(), delivers.end());
    std::sort(drifts.begin(), drifts.end());

    // Audio pump stats
    std::vector<int64_t> buf_levels;
    size_t pump_count = m_audio_diag.size();
    int64_t stall_count = 0;

    m_audio_diag.for_each([&](const PumpMetric& p) {
        buf_levels.push_back(p.buffered_frames);
        if (p.flags & PumpFlags::STALL) ++stall_count;
    });

    std::sort(buf_levels.begin(), buf_levels.end());

    // Percentile helpers
    auto pctd = [](const std::vector<double>& sorted, double p) -> double {
        if (sorted.empty()) return 0.0;
        size_t idx = static_cast<size_t>(p * static_cast<double>(sorted.size() - 1));
        return sorted[idx];
    };
    auto pcti = [](const std::vector<int64_t>& sorted, double p) -> int64_t {
        if (sorted.empty()) return 0;
        size_t idx = static_cast<size_t>(p * static_cast<double>(sorted.size() - 1));
        return sorted[idx];
    };

    // Open file
    FILE* f = fopen("/tmp/jve_playback_diag.txt", "w");
    if (!f) {
        JVE_LOG_WARN(Ticks, "dumpDiagnostics: failed to open /tmp/jve_playback_diag.txt");
        return;
    }

    // Header
    fprintf(f, "=== PLAYBACK DIAG (%.1fs, %zu ticks) ===\n", total_duration_s, video_count);

    // Video stats
    fprintf(f, "VIDEO:\n");
    if (!cadences.empty()) {
        fprintf(f, "  cadence: med=%.1fms p95=%.1fms p99=%.1fms max=%.1fms\n",
                pctd(cadences, 0.50), pctd(cadences, 0.95), pctd(cadences, 0.99),
                cadences.back());
    }
    if (!delivers.empty()) {
        fprintf(f, "  deliver: med=%.1fms p95=%.1fms max=%.1fms\n",
                pctd(delivers, 0.50), pctd(delivers, 0.95), delivers.back());
    }
    if (!drifts.empty()) {
        fprintf(f, "  drift:   med=%.3fs p95=%.3fs max=%.3fs\n",
                pctd(drifts, 0.50), pctd(drifts, 0.95), drifts.back());
    }
    fprintf(f, "  flags:   skips=%lld holds=%lld repeats=%lld gaps=%lld transitions=%lld dropped=%lld\n",
            (long long)skip_count, (long long)hold_count, (long long)repeat_count,
            (long long)gap_count, (long long)transition_count, (long long)dropped_count);
    if (dropped_count > 0) {
        // Compute effective video fps from non-dropped, non-repeat ticks
        int64_t decoded_ticks = static_cast<int64_t>(video_count) - dropped_count - repeat_count;
        double effective_fps = (total_duration_s > 0 && decoded_ticks > 0)
            ? static_cast<double>(decoded_ticks) / total_duration_s : 0.0;
        fprintf(f, "  SLOW DECODE: dropped %lld frames, effective video fps=%.1f\n",
                (long long)dropped_count, effective_fps);
    }

    // Outlier ticks
    double expected_cadence_ms = 1000.0 / m_fps;
    double outlier_threshold = expected_cadence_ms * 2.0;
    fprintf(f, "  OUTLIER TICKS (cadence > %.0fms):\n", outlier_threshold);
    {
        size_t idx = 0;
        m_video_diag.for_each([&](const TickMetric& t) {
            if (t.cadence_ms > outlier_threshold) {
                fprintf(f, "    tick[%zu]: elapsed=%.1fms cadence=%.1fms deliver=%.1fms "
                        "drift=%.3fs flags=%s frame=%lld [%s]\n",
                        idx, t.elapsed_ms, t.cadence_ms, t.deliver_ms,
                        t.drift_s, tickFlagsStr(t.flags).c_str(), (long long)t.frame,
                        frameToTC(t.frame, m_fps_num / m_fps_den).c_str());
            }
            ++idx;
        });
    }

    // Audio pump stats
    if (pump_count > 0) {
        int64_t underruns = m_audio_pump ? m_audio_pump->UnderrunCount() : 0;

        // Compute fetch statistics
        int64_t total_fetched = 0;
        int64_t fetch_hit_count = 0;
        int64_t first_fetch_cycle = -1;
        int64_t first_fetch_media_t = 0;
        int64_t min_media_t = INT64_MAX, max_media_t = INT64_MIN;
        {
            size_t idx = 0;
            m_audio_diag.for_each([&](const PumpMetric& p) {
                total_fetched += p.fetched_frames;
                if (p.media_time_us < min_media_t) min_media_t = p.media_time_us;
                if (p.media_time_us > max_media_t) max_media_t = p.media_time_us;
                if (p.fetched_frames > 0) {
                    ++fetch_hit_count;
                    if (first_fetch_cycle < 0) {
                        first_fetch_cycle = static_cast<int64_t>(idx);
                        first_fetch_media_t = p.media_time_us;
                    }
                }
                ++idx;
            });
        }

        fprintf(f, "AUDIO PUMP (%zu cycles):\n", pump_count);
        if (!buf_levels.empty()) {
            fprintf(f, "  buffer: med=%lld p5=%lld min=%lld\n",
                    (long long)pcti(buf_levels, 0.50),
                    (long long)pcti(buf_levels, 0.05),
                    (long long)buf_levels.front());
        }
        fprintf(f, "  underruns=%lld stalls=%lld\n",
                (long long)underruns, (long long)stall_count);
        fprintf(f, "  fetch: total=%lld hits=%lld first_hit_cycle=%lld first_hit_t=%lldus\n",
                (long long)total_fetched, (long long)fetch_hit_count,
                (long long)first_fetch_cycle, (long long)first_fetch_media_t);
        fprintf(f, "  media_time: min=%lldus max=%lldus range=%.3fs\n",
                (long long)min_media_t, (long long)max_media_t,
                static_cast<double>(max_media_t - min_media_t) / 1000000.0);

        // Audio outliers (low buffer)
        fprintf(f, "  OUTLIER CYCLES (buffer < 1000):\n");
        {
            size_t idx = 0;
            m_audio_diag.for_each([&](const PumpMetric& p) {
                if (p.buffered_frames < 1000) {
                    fprintf(f, "    pump[%zu]: buf=%lld rendered=%lld media_t=%lldus flags=%s\n",
                            idx, (long long)p.buffered_frames,
                            (long long)p.rendered_frames,
                            (long long)p.media_time_us,
                            pumpFlagsStr(p.flags).c_str());
                }
                ++idx;
            });
        }
    }

    // Build transition index: tick_index → transition info
    std::unordered_map<size_t, size_t> transition_at_tick;  // tick_index → index in m_clip_transitions
    for (size_t i = 0; i < m_clip_transitions.size(); ++i) {
        transition_at_tick[m_clip_transitions[i].tick_index] = i;
    }

    int tc_fps = m_fps_num / m_fps_den;

    // All ticks chronological
    fprintf(f, "ALL TICKS (chronological):\n");
    {
        size_t idx = 0;
        m_video_diag.for_each([&](const TickMetric& t) {
            // Insert clip transition separator before this tick
            auto tit = transition_at_tick.find(idx);
            if (tit != transition_at_tick.end()) {
                const auto& ct = m_clip_transitions[tit->second];
                // Extract filename from path for readability
                const char* name = ct.media_path.c_str();
                const char* slash = strrchr(name, '/');
                if (slash) name = slash + 1;
                fprintf(f, "  ──── %s [%s] %s ────\n",
                        frameToTC(ct.frame, tc_fps).c_str(),
                        ct.clip_id.substr(0, 8).c_str(), name);
            }
            fprintf(f, "  [%zu] elapsed=%.1f cadence=%.1f deliver=%.1f drift=%.3f "
                    "buf=%lld flags=%s frame=%lld [%s]\n",
                    idx, t.elapsed_ms, t.cadence_ms, t.deliver_ms,
                    t.drift_s, (long long)t.audio_buf_frames,
                    tickFlagsStr(t.flags).c_str(), (long long)t.frame,
                    frameToTC(t.frame, tc_fps).c_str());
            ++idx;
        });
    }

    fclose(f);

    // One-line summary to stderr
    JVE_LOG_EVENT(Ticks, "Stop at %s (frame %lld) — diag written to /tmp/jve_playback_diag.txt",
                  frameToTC(pos, m_fps_num / m_fps_den).c_str(), (long long)pos);

    // Rings are NOT reset here — Play() resets them at start.
    // This lets Lua call GetDiagSummary() after Stop() returns.
}

#endif // __APPLE__
