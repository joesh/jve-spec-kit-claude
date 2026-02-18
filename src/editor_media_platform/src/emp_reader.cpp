#include <editor_media_platform/emp_reader.h>
#include "impl/ffmpeg_context.h"
#include "impl/ffmpeg_resample.h"
#include "impl/media_file_impl.h"
#include "impl/frame_impl.h"
#include "impl/pcm_chunk_impl.h"
#include <cassert>
#include <vector>
#include <map>
#include <memory>
#include <chrono>
#include <cstdio>
#include <thread>
#include <mutex>
#include <atomic>
#include <condition_variable>

// Simple logging - check EMP_LOG_LEVEL env var at runtime
// 0=none (default), 1=warn, 2=debug
namespace {
inline int emp_log_level() {
    static int level = -1;
    if (level < 0) {
        const char* env = std::getenv("EMP_LOG_LEVEL");
        level = env ? std::atoi(env) : 0;
    }
    return level;
}
} // namespace

#define EMP_LOG_WARN(...) do { if (emp_log_level() >= 1) { fprintf(stderr, "[EMP WARN] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)
#define EMP_LOG_DEBUG(...) do { if (emp_log_level() >= 2) { fprintf(stderr, "[EMP] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)

#ifdef EMP_HAS_VIDEOTOOLBOX
#include <CoreVideo/CVPixelBuffer.h>
#endif

namespace emp {

// Global decode mode (thread-safe atomic)
static std::atomic<DecodeMode> g_decode_mode{DecodeMode::Play};

void SetDecodeMode(DecodeMode mode) {
    g_decode_mode.store(mode, std::memory_order_release);
    EMP_LOG_DEBUG("DecodeMode set to %s",
        mode == DecodeMode::Play ? "Play" :
        mode == DecodeMode::Scrub ? "Scrub" : "Park");
}

DecodeMode GetDecodeMode() {
    return g_decode_mode.load(std::memory_order_acquire);
}

// Forward declarations from impl files
namespace impl {
Result<AVFrame*> decode_next_frame(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                    int stream_idx, AVPacket* pkt, AVFrame* frame);
Result<AVFrame*> decode_until_target(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                      AVStream* stream, int stream_idx,
                                      TimeUS target_us,
                                      AVPacket* pkt, AVFrame* frame, AVFrame* best_frame);
// backoff_us: how far before target to seek. Always pass 0 — AVSEEK_FLAG_BACKWARD
// already lands on the keyframe at or before the target.
Result<void> seek_with_backoff(AVFormatContext* fmt_ctx, AVStream* stream,
                                AVCodecContext* codec_ctx, TimeUS target_us,
                                TimeUS backoff_us);
bool need_seek(TimeUS current_pts_us, TimeUS target_us, bool have_current);
std::vector<uint8_t> allocate_bgra_buffer(int width, int height, int* out_stride);
void convert_frame_to_bgra(FFmpegScaleContext& scale_ctx, AVFrame* frame,
                            uint8_t* dst_data, int dst_stride);

// Decoded frame with its PTS
struct DecodedFrame {
    AVFrame* frame;
    TimeUS pts_us;
};
Result<std::vector<DecodedFrame>> decode_frames_batch(
    AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
    AVStream* stream, int stream_idx,
    TimeUS target_us, AVPacket* pkt, AVFrame* temp_frame);
}

// ReaderImpl holds FFmpeg decode state
class ReaderImpl {
public:
    ReaderImpl() {
        m_pkt = av_packet_alloc();
        m_frame = av_frame_alloc();
        m_audio_pkt = av_packet_alloc();
        m_audio_frame = av_frame_alloc();
        m_prefetch_pkt = av_packet_alloc();
        m_prefetch_frame = av_frame_alloc();
        assert(m_pkt && m_frame);
        assert(m_audio_pkt && m_audio_frame);
        assert(m_prefetch_pkt && m_prefetch_frame);
    }

    ~ReaderImpl() {
        // Stop prefetch thread if running (Reader::~Reader calls StopPrefetch,
        // but be defensive)
        prefetch_running.store(false);
        prefetch_cv.notify_all();
        if (prefetch_thread.joinable()) {
            prefetch_thread.join();
        }

        av_packet_free(&m_pkt);
        av_frame_free(&m_frame);
        av_packet_free(&m_audio_pkt);
        av_frame_free(&m_audio_frame);
        av_packet_free(&m_prefetch_pkt);
        av_frame_free(&m_prefetch_frame);
    }

    // Video decode state (main thread)
    impl::FFmpegCodecContext codec_ctx;
    impl::FFmpegScaleContext scale_ctx;
    AVPacket* m_pkt = nullptr;
    AVFrame* m_frame = nullptr;

    // Tracks where the main-thread decoder was last positioned (PTS of last
    // decoded frame). Used by Play path to detect gaps after Park/Scrub seek.
    TimeUS last_decode_pts = INT64_MIN;
    bool have_decode_pos = false;

    // Tracks previous decode mode for transition detection.
    // Park/Scrub→Play transition must clear cache (scattered park frames
    // poison sequential playback via stale floor matches).
    DecodeMode last_mode = DecodeMode::Park;

    // Frame cache: stores ALL decoded frames by PTS
    // Key: PTS in microseconds, Value: shared_ptr<Frame>
    // This captures ALL decoder output to avoid B-frame reordering losses
    std::map<TimeUS, std::shared_ptr<Frame>> frame_cache;
    TimeUS cache_min_pts = INT64_MAX;
    TimeUS cache_max_pts = INT64_MIN;
    static constexpr size_t DEFAULT_MAX_CACHE_FRAMES = 120;  // ~5s at 24fps - larger for reverse
    size_t max_cache_frames = DEFAULT_MAX_CACHE_FRAMES;

    // Thread-safety for frame cache (shared between main and prefetch threads)
    mutable std::mutex cache_mutex;

    // =========================================================================
    // Prefetch thread state - has its OWN decoder to avoid contention
    // =========================================================================
    std::thread prefetch_thread;
    std::atomic<bool> prefetch_running{false};
    std::atomic<TimeUS> prefetch_target{0};
    std::atomic<int> prefetch_direction{0};  // 0=stopped, 1=forward, -1=reverse
    std::condition_variable prefetch_cv;
    std::mutex prefetch_mutex;  // For condition variable

    // Prefetch thread's own decoder (initialized lazily on first StartPrefetch)
    impl::FFmpegFormatContext prefetch_fmt_ctx;  // Separate format context!
    impl::FFmpegCodecContext prefetch_codec_ctx;
    impl::FFmpegScaleContext prefetch_scale_ctx;
    AVPacket* m_prefetch_pkt = nullptr;
    AVFrame* m_prefetch_frame = nullptr;
    bool prefetch_decoder_initialized = false;

    // Prefetch decoder position tracking — used to detect when the prefetch
    // decoder is far from the target and needs a forward seek.
    std::atomic<TimeUS> prefetch_decode_pts{INT64_MIN};
    std::atomic<bool> have_prefetch_pos{false};

    // Diagnostics: total frames decoded by prefetch since last StartPrefetch.
    // Reset in StartPrefetch, incremented in prefetch_worker.  Exposed via
    // Reader::PrefetchFramesDecoded() for testing seek-vs-forward-decode.
    std::atomic<int64_t> prefetch_frames_decoded{0};

    // Audio decode state
    impl::FFmpegCodecContext audio_codec_ctx;
    impl::FFmpegResampleContext resample_ctx;
    AVPacket* m_audio_pkt = nullptr;
    AVFrame* m_audio_frame = nullptr;
    bool audio_initialized = false;
    int current_audio_out_rate = 0;  // Track resampler target rate

    // Audio decoder state
    bool have_audio_pts = false;
    TimeUS audio_pts_us = 0;

    // Stale cache rejection threshold: max gap between floor match and target
    // before treating as cache miss. Computed from stream frame rate in DecodeAtUS,
    // shared with GetCachedFrame (which doesn't have stream access).
    std::atomic<TimeUS> max_floor_gap_us{84000};  // conservative default ~2 frames @ 24fps
};

Reader::Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<MediaFile> asset)
    : m_impl(std::move(impl)), m_media_file(std::move(asset)) {
    assert(m_impl && m_media_file && "Reader impl/media_file cannot be null");
}

Reader::~Reader() {
    // Stop prefetch thread before destroying impl
    StopPrefetch();
}

std::shared_ptr<MediaFile> Reader::media_file() const {
    return m_media_file;
}

Result<std::shared_ptr<Reader>> Reader::Create(std::shared_ptr<MediaFile> asset) {
    if (!asset) {
        return Error::invalid_arg("MediaFile is null");
    }
    if (!asset->info().has_video && !asset->info().has_audio) {
        return Error::unsupported("MediaFile has no video or audio stream");
    }

    auto impl = std::make_unique<ReaderImpl>();

    // Get format context from asset (requires friend access)
    MediaFileImpl* asset_impl = asset->impl_ptr();

    // Initialize video codec if asset has video
    if (asset->info().has_video) {
        AVCodecParameters* params = asset_impl->fmt_ctx.video_codec_params();

        auto codec_result = impl->codec_ctx.init(params);
        if (codec_result.is_error()) {
            return codec_result.error();
        }

        // Only initialize software scaler if NOT using hw accel
        // (hw path uses GPU YUV→RGB, sw path needs swscale BGRA conversion)
        if (!impl->codec_ctx.is_hw_accelerated()) {
            auto scale_result = impl->scale_ctx.init(
                params->width, params->height,
                static_cast<AVPixelFormat>(params->format),
                params->width, params->height
            );
            if (scale_result.is_error()) {
                return scale_result.error();
            }
        }
    }

    // Initialize audio codec if asset has audio
    if (asset->info().has_audio) {
        AVCodecParameters* audio_params = asset_impl->fmt_ctx.audio_codec_params();
        auto audio_codec_result = impl->audio_codec_ctx.init(audio_params);
        if (audio_codec_result.is_error()) {
            // Audio codec init failure is not fatal - we just won't have audio
            impl->audio_initialized = false;
        } else {
            impl->audio_initialized = true;
        }
    }

    return std::make_shared<Reader>(std::move(impl), std::move(asset));
}

Result<void> Reader::Seek(FrameTime t) {
    return SeekUS(t.to_us());
}

Result<void> Reader::SeekUS(TimeUS t_us) {
    if (!m_media_file->info().has_video) {
        return Error::unsupported("Seek requires video stream");
    }

    MediaFileImpl* asset_impl = m_media_file->impl_ptr();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();

    auto result = impl::seek_with_backoff(
        asset_impl->fmt_ctx.get(),
        stream,
        m_impl->codec_ctx.get(),
        t_us, 0
    );

    // Note: We don't clear the frame cache on seek. The cached frames are still valid
    // (they hold BGRA data, not decoder state). Clearing would invalidate any handles
    // held by Lua. Natural eviction will remove old frames as new ones are decoded.

    return result;
}

Result<std::shared_ptr<Frame>> Reader::DecodeAt(FrameTime t) {
    return DecodeAtUS(t.to_us());
}

// Helper: Convert AVFrame to emp::Frame (handles both hw and sw paths)
static std::shared_ptr<Frame> avframe_to_emp_frame(
    AVFrame* av_frame, TimeUS pts_us,
    impl::FFmpegScaleContext& scale_ctx,
    [[maybe_unused]] impl::FFmpegCodecContext& codec_ctx)
{
#ifdef EMP_HAS_VIDEOTOOLBOX
    if (av_frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)av_frame->data[3];
        assert(pixel_buffer && "VideoToolbox frame missing CVPixelBuffer");

        int stride = ((av_frame->width * 4) + 31) & ~31;

        auto frame_impl = std::make_unique<FrameImpl>(
            av_frame->width, av_frame->height, stride, pts_us, pixel_buffer
        );
        return std::make_shared<Frame>(std::move(frame_impl));
    }
#endif

    // Software decode path
    int stride;
    auto buffer = impl::allocate_bgra_buffer(av_frame->width, av_frame->height, &stride);
    impl::convert_frame_to_bgra(scale_ctx, av_frame, buffer.data(), stride);

    auto frame_impl = std::make_unique<FrameImpl>(
        av_frame->width, av_frame->height, stride, pts_us, std::move(buffer)
    );
    return std::make_shared<Frame>(std::move(frame_impl));
}

// Helper: Evict oldest frames from cache when exceeding limit
static void evict_cache_frames(
    std::map<TimeUS, std::shared_ptr<Frame>>& cache,
    TimeUS& cache_min_pts, TimeUS& cache_max_pts,
    TimeUS keep_around_pts, size_t max_frames)
{
    while (cache.size() > max_frames) {
        // Evict frame furthest from keep_around_pts
        auto it_first = cache.begin();
        auto it_last = std::prev(cache.end());

        TimeUS dist_first = (keep_around_pts > it_first->first)
            ? (keep_around_pts - it_first->first)
            : (it_first->first - keep_around_pts);
        TimeUS dist_last = (keep_around_pts > it_last->first)
            ? (keep_around_pts - it_last->first)
            : (it_last->first - keep_around_pts);

        if (dist_first >= dist_last) {
            cache.erase(it_first);
        } else {
            cache.erase(it_last);
        }
    }

    // Update bounds
    if (cache.empty()) {
        cache_min_pts = INT64_MAX;
        cache_max_pts = INT64_MIN;
    } else {
        cache_min_pts = cache.begin()->first;
        cache_max_pts = cache.rbegin()->first;
    }
}

void Reader::SetMaxCacheFrames(size_t max_frames) {
    {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        m_impl->max_cache_frames = max_frames;

        // Evict immediately if over new limit
        if (m_impl->frame_cache.size() > max_frames) {
            TimeUS center = m_impl->prefetch_target.load();
            evict_cache_frames(
                m_impl->frame_cache,
                m_impl->cache_min_pts, m_impl->cache_max_pts,
                center, max_frames
            );
        }
    }

    EMP_LOG_DEBUG("SetMaxCacheFrames: %zu", max_frames);
}

int64_t Reader::PrefetchFramesDecoded() const {
    return m_impl->prefetch_frames_decoded.load();
}

Result<std::shared_ptr<Frame>> Reader::DecodeAtUS(TimeUS t_us) {
    if (!m_media_file->info().has_video) {
        return Error::unsupported("DecodeAt requires video stream");
    }

    MediaFileImpl* asset_impl = m_media_file->impl_ptr();
    AVFormatContext* fmt_ctx = asset_impl->fmt_ctx.get();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();
    int stream_idx = asset_impl->fmt_ctx.video_stream_index();

    static int cache_hits = 0, cache_misses = 0;
    static auto last_log = std::chrono::steady_clock::now();

    // Keep the prefetch target in sync with the main-thread playhead.
    // Without this, the prefetch relies entirely on Lua calling
    // UpdatePrefetchTarget, which happens AFTER DecodeAtUS returns.
    // On clip switch the sequence is:
    //   1. activate() → stops old prefetch
    //   2. show_frame_at_time() → DecodeAtUS (94ms sync batch)
    //   3. set_playhead() → StartPrefetch + UpdatePrefetchTarget
    // The prefetch starts in step 3 with target still at the PREVIOUS
    // session's position.  It computes prefetch_to = stale + 500ms, sees
    // cache_max_pts (from step 2's batch) is already past that, and sleeps
    // instead of decoding ahead.  Storing t_us here ensures the prefetch
    // uses the correct target from its very first iteration.
    m_impl->prefetch_target.store(t_us);

    // Stale session: target far outside cached range → cache is from a
    // previous session (pooled reader reactivation, large seek). Clear.
    {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        if (!m_impl->frame_cache.empty()) {
            constexpr TimeUS STALE_THRESHOLD_US = 1000000;  // 1s
            bool outside = (t_us > m_impl->cache_max_pts + STALE_THRESHOLD_US) ||
                           (t_us < m_impl->cache_min_pts - STALE_THRESHOLD_US);
            if (outside) {
                EMP_LOG_DEBUG("Stale session cleared: target=%lldus outside [%lld,%lld]+1s",
                        (long long)t_us,
                        (long long)m_impl->cache_min_pts,
                        (long long)m_impl->cache_max_pts);
                m_impl->frame_cache.clear();
                m_impl->cache_min_pts = INT64_MAX;
                m_impl->cache_max_pts = INT64_MIN;
                m_impl->have_decode_pos = false;
                m_impl->have_prefetch_pos.store(false);
            }
        }
    }

    // 0. Mode transition: Park/Scrub→Play clears scattered cache.
    //    Scattered park frames cause stale floor matches during sequential play
    //    and fool the prefetch into thinking the cache is already ahead.
    DecodeMode mode = GetDecodeMode();
    if (mode == DecodeMode::Play && m_impl->last_mode != DecodeMode::Play) {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        if (!m_impl->frame_cache.empty()) {
            // Scattered Park/Scrub frames poison sequential Play via stale
            // floor matches. Clear only when there's something to clear —
            // freshly-activated readers (empty cache, stale last_mode from
            // pool) skip this harmlessly.
            m_impl->frame_cache.clear();
            m_impl->cache_min_pts = INT64_MAX;
            m_impl->cache_max_pts = INT64_MIN;
            m_impl->have_decode_pos = false;
            m_impl->have_prefetch_pos.store(false);
            EMP_LOG_DEBUG("Cache cleared on %s→Play transition",
                    m_impl->last_mode == DecodeMode::Park ? "Park" : "Scrub");
        }
    }
    m_impl->last_mode = mode;

    // Max gap between floor match and target before treating as cache miss.
    // 2 frame durations: tight enough to reject scattered Park frames while
    // allowing for PTS rounding and off-by-one at frame boundaries.
    // (decode_frames_batch now properly drains the decoder's B-frame buffer,
    // so cache should have contiguous PTS coverage — no need for large gaps.)
    // Ceiling division avoids off-by-one: e.g. 24000/1001 → floor gives 41708,
    // but actual PTS gaps can be 41709 due to av_rescale_q rounding.
    TimeUS frame_dur_us = (stream->avg_frame_rate.num > 0)
        ? (1000000LL * stream->avg_frame_rate.den + stream->avg_frame_rate.num - 1)
          / stream->avg_frame_rate.num
        : 42000;  // ~24fps fallback only if stream has no rate (shouldn't happen)
    TimeUS max_floor_gap_us = frame_dur_us * 2;
    m_impl->max_floor_gap_us.store(max_floor_gap_us);

    // 1. Check cache first (fast path) - thread-safe lookup
    {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        if (!m_impl->frame_cache.empty() && t_us <= m_impl->cache_max_pts) {
            auto it = m_impl->frame_cache.upper_bound(t_us);
            if (it != m_impl->frame_cache.begin()) {
                --it;  // Now points to largest pts <= t_us
                TimeUS gap = t_us - it->first;

                // Stale floor match: cache has frames but none near the target.
                // Treat as miss so decode path fills the gap.
                if (gap > max_floor_gap_us) {
                    EMP_LOG_DEBUG("Stale cache hit rejected: gap=%lldus (max=%lldus), "
                            "floor_pts=%lld target=%lld",
                            (long long)gap, (long long)max_floor_gap_us,
                            (long long)it->first, (long long)t_us);
                    // Fall through to decode path
                } else {
                    cache_hits++;
                    auto now = std::chrono::steady_clock::now();
                    if (std::chrono::duration_cast<std::chrono::seconds>(now - last_log).count() >= 2) {
                        EMP_LOG_DEBUG("Cache: %d hits, %d misses (%.1f%% hit rate), size=%zu",
                                cache_hits, cache_misses,
                                100.0 * cache_hits / (cache_hits + cache_misses + 1),
                                m_impl->frame_cache.size());
                        last_log = now;
                    }
                    return it->second;
                }
            }
        }
    }

    // If prefetch is running, wait briefly for it to catch up
    if (m_impl->prefetch_direction.load() != 0) {
        for (int i = 0; i < 10; ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            auto cached = GetCachedFrame(t_us);
            if (cached) {
                cache_hits++;
                return cached;
            }
        }
    }

    cache_misses++;
    auto decode_start = std::chrono::steady_clock::now();

    // 2. Synchronous decode fallback (scrub, seek, initial load)
    //    Main thread uses its own decoder - no lock needed (prefetch has separate decoder)
    std::shared_ptr<Frame> result_frame;

    if (mode == DecodeMode::Scrub || mode == DecodeMode::Park) {
        // Park/Scrub: always seek to nearest keyframe for minimum latency.
        // Zero backoff — AVSEEK_FLAG_BACKWARD already lands on the keyframe
        // at or before target. No need to overshoot backward by 2 seconds.
        auto seek_result = impl::seek_with_backoff(
            fmt_ctx, stream, m_impl->codec_ctx.get(), t_us, 0
        );
        if (seek_result.is_error()) {
            return seek_result.error();
        }
    } else {
        // Play: seek when decoder can't produce target by sequential decode.
        // need_seek checks: no position, backward, or >2s gap.
        // Do NOT clear the cache here — the prefetch may have filled it with
        // good frames even though the main decoder hasn't run in a while.
        // Park→Play transition (above) handles genuinely stale caches.
        if (impl::need_seek(m_impl->last_decode_pts, t_us, m_impl->have_decode_pos)) {
            auto seek_result = impl::seek_with_backoff(
                fmt_ctx, stream, m_impl->codec_ctx.get(), t_us, 0
            );
            if (seek_result.is_error()) {
                return seek_result.error();
            }
        }
    }

    if (mode == DecodeMode::Scrub || mode == DecodeMode::Park) {
        // =====================================================================
        // Scrub/Park path: decode-and-discard intermediates, keep only the
        // floor frame. Uses decode_until_target which reuses two AVFrames
        // (no per-frame allocation, no vector).
        // =====================================================================
        AVFrame* best_frame = av_frame_alloc();
        assert(best_frame && "av_frame_alloc failed");

        auto target_result = impl::decode_until_target(
            m_impl->codec_ctx.get(), fmt_ctx, stream, stream_idx,
            t_us, m_impl->m_pkt, m_impl->m_frame, best_frame
        );

        if (target_result.is_error()) {
            av_frame_free(&best_frame);
            return target_result.error();
        }

        // Convert the single floor frame to BGRA
        AVFrame* floor_frame = target_result.value();
        TimeUS floor_pts = impl::stream_pts_to_us(floor_frame->pts, stream);
        result_frame = avframe_to_emp_frame(
            floor_frame, floor_pts, m_impl->scale_ctx, m_impl->codec_ctx
        );
        av_frame_free(&best_frame);

        // Decoder position is indeterminate after B-frame lookahead drain.
        // Force Play to seek on next mode switch.
        m_impl->have_decode_pos = false;

        // Cache the result
        {
            std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
            m_impl->frame_cache[floor_pts] = result_frame;
            if (floor_pts < m_impl->cache_min_pts) m_impl->cache_min_pts = floor_pts;
            if (floor_pts > m_impl->cache_max_pts) m_impl->cache_max_pts = floor_pts;

            evict_cache_frames(
                m_impl->frame_cache,
                m_impl->cache_min_pts, m_impl->cache_max_pts,
                t_us, m_impl->max_cache_frames
            );
        }

        auto decode_end = std::chrono::steady_clock::now();
        auto decode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            decode_end - decode_start).count();
        if (decode_ms > 10) {
            EMP_LOG_DEBUG("Decode target: %lldms mode=%s",
                    static_cast<long long>(decode_ms),
                    mode == DecodeMode::Scrub ? "scrub" : "park");
        }
    } else {
        // =====================================================================
        // Play path: decode batch, BGRA-convert ALL frames, cache for
        // sequential access and prefetch.
        // =====================================================================
        auto batch_result = impl::decode_frames_batch(
            m_impl->codec_ctx.get(), fmt_ctx, stream, stream_idx,
            t_us, m_impl->m_pkt, m_impl->m_frame
        );

        if (batch_result.is_error()) {
            return batch_result.error();
        }

        auto& decoded_frames = batch_result.value();

        // Track main-thread decoder position as max PTS of THIS batch.
        // Must NOT use cache_max_pts — it includes prefetch frames from
        // a separate decoder. Using it would make need_seek() think the
        // main decoder is further ahead than it actually is.
        // Computed before av_frame_free loop (pts_us is a value copy, but
        // keeping it here makes the data dependency obvious).
        if (!decoded_frames.empty()) {
            TimeUS batch_max_pts = decoded_frames[0].pts_us;
            for (const auto& df : decoded_frames) {
                if (df.pts_us > batch_max_pts) batch_max_pts = df.pts_us;
            }
            m_impl->last_decode_pts = batch_max_pts;
            m_impl->have_decode_pos = true;
        }

        {
            std::lock_guard<std::mutex> lock(m_impl->cache_mutex);

            for (auto& df : decoded_frames) {
                if (m_impl->frame_cache.find(df.pts_us) == m_impl->frame_cache.end()) {
                    auto emp_frame = avframe_to_emp_frame(
                        df.frame, df.pts_us, m_impl->scale_ctx, m_impl->codec_ctx
                    );
                    m_impl->frame_cache[df.pts_us] = emp_frame;

                    if (df.pts_us < m_impl->cache_min_pts) {
                        m_impl->cache_min_pts = df.pts_us;
                    }
                    if (df.pts_us > m_impl->cache_max_pts) {
                        m_impl->cache_max_pts = df.pts_us;
                    }
                }
                av_frame_free(&df.frame);
            }

            auto decode_end = std::chrono::steady_clock::now();
            auto decode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                decode_end - decode_start).count();
            if (decode_ms > 10) {
                EMP_LOG_DEBUG("Decode batch: %zu frames in %lldms (%.1fms/frame) mode=play",
                        decoded_frames.size(), static_cast<long long>(decode_ms),
                        decoded_frames.size() > 0 ? (double)decode_ms / decoded_frames.size() : 0);
            }

            evict_cache_frames(
                m_impl->frame_cache,
                m_impl->cache_min_pts, m_impl->cache_max_pts,
                t_us, m_impl->max_cache_frames
            );

            // Return floor frame from cache
            auto it = m_impl->frame_cache.upper_bound(t_us);
            if (it != m_impl->frame_cache.begin()) {
                --it;
                result_frame = it->second;
            } else if (!m_impl->frame_cache.empty()) {
                result_frame = m_impl->frame_cache.begin()->second;
            }
        }
    }

    if (result_frame) {
        return result_frame;
    }

    return Error::internal("DecodeAtUS: no frames decoded");
}

Result<std::shared_ptr<PcmChunk>> Reader::DecodeAudioRange(FrameTime t0, FrameTime t1,
                                                            const AudioFormat& out) {
    return DecodeAudioRangeUS(t0.to_us(), t1.to_us(), out);
}

Result<std::shared_ptr<PcmChunk>> Reader::DecodeAudioRangeUS(TimeUS t0_us, TimeUS t1_us,
                                                              const AudioFormat& out) {
    // Resampler ALWAYS outputs stereo (2 channels) regardless of source format
    // See ffmpeg_resample.h: "Converts any input format to float32 stereo"
    constexpr int RESAMPLER_OUTPUT_CHANNELS = 2;

    // Validate
    if (!m_media_file->info().has_audio) {
        return Error::unsupported("MediaFile has no audio stream");
    }
    if (!m_impl->audio_initialized) {
        return Error::unsupported("Audio codec not initialized");
    }
    if (t1_us <= t0_us) {
        return Error::invalid_arg("DecodeAudioRangeUS: t1 must be > t0");
    }

    MediaFileImpl* asset_impl = m_media_file->impl_ptr();
    AVFormatContext* fmt_ctx = asset_impl->fmt_ctx.get();
    AVStream* audio_stream = asset_impl->fmt_ctx.audio_stream();
    int audio_stream_idx = asset_impl->fmt_ctx.audio_stream_index();
    AVCodecContext* audio_codec = m_impl->audio_codec_ctx.get();

    // Initialize or reinitialize resampler if output rate changed
    if (m_impl->current_audio_out_rate != out.sample_rate) {
        auto resample_result = m_impl->resample_ctx.init(
            audio_codec->sample_rate,
            &audio_codec->ch_layout,
            audio_codec->sample_fmt,
            out.sample_rate
        );
        if (resample_result.is_error()) {
            return resample_result.error();
        }
        m_impl->current_audio_out_rate = out.sample_rate;
    }

    // Calculate expected output samples
    int64_t duration_us = t1_us - t0_us;
    int64_t expected_samples = (duration_us * out.sample_rate) / 1000000;
    // Add margin for resampling
    int64_t max_samples = expected_samples + 1024;

    std::vector<float> pcm_buffer;
    pcm_buffer.reserve(static_cast<size_t>(max_samples * RESAMPLER_OUTPUT_CHANNELS));

    // Seek to start position in audio stream
    int64_t seek_pts = impl::us_to_stream_pts(t0_us, audio_stream);
    int ret = av_seek_frame(fmt_ctx, audio_stream_idx, seek_pts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        // Seek failed - try from beginning
        ret = av_seek_frame(fmt_ctx, audio_stream_idx, 0, AVSEEK_FLAG_BACKWARD);
        if (ret < 0) {
            return impl::ffmpeg_error(ret, "Audio seek failed");
        }
    }
    avcodec_flush_buffers(audio_codec);
    m_impl->resample_ctx.reset();  // Clear resampler FIFO after discontinuous seek

    // Decode audio packets until we've covered [t0_us, t1_us)
    TimeUS decoded_start_us = -1;
    int64_t total_output_samples = 0;

    while (true) {
        ret = av_read_frame(fmt_ctx, m_impl->m_audio_pkt);
        if (ret == AVERROR_EOF) {
            break;  // End of file
        }
        if (ret < 0) {
            av_packet_unref(m_impl->m_audio_pkt);
            return impl::ffmpeg_error(ret, "av_read_frame (audio)");
        }

        if (m_impl->m_audio_pkt->stream_index != audio_stream_idx) {
            av_packet_unref(m_impl->m_audio_pkt);
            continue;  // Skip non-audio packets
        }

        // Send packet to decoder
        ret = avcodec_send_packet(audio_codec, m_impl->m_audio_pkt);
        av_packet_unref(m_impl->m_audio_pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            return impl::ffmpeg_error(ret, "avcodec_send_packet (audio)");
        }

        // Receive decoded frames
        while (true) {
            ret = avcodec_receive_frame(audio_codec, m_impl->m_audio_frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            }
            if (ret < 0) {
                return impl::ffmpeg_error(ret, "avcodec_receive_frame (audio)");
            }

            // Calculate frame time range
            TimeUS frame_pts_us = impl::stream_pts_to_us(m_impl->m_audio_frame->pts, audio_stream);
            int64_t frame_samples = m_impl->m_audio_frame->nb_samples;
            TimeUS frame_duration_us = (frame_samples * 1000000LL) / audio_codec->sample_rate;
            TimeUS frame_end_us = frame_pts_us + frame_duration_us;

            // Skip frames entirely before our range
            if (frame_end_us <= t0_us) {
                av_frame_unref(m_impl->m_audio_frame);
                continue;
            }

            // Stop if we've passed our range
            if (frame_pts_us >= t1_us) {
                av_frame_unref(m_impl->m_audio_frame);
                goto done;
            }

            // Record start time of first decoded audio
            if (decoded_start_us < 0) {
                decoded_start_us = frame_pts_us;
            }

            // Resample this frame
            int64_t out_samples_needed = m_impl->resample_ctx.get_out_samples(frame_samples);
            size_t current_size = pcm_buffer.size();
            pcm_buffer.resize(current_size + static_cast<size_t>(out_samples_needed * RESAMPLER_OUTPUT_CHANNELS));

            int64_t out_samples = m_impl->resample_ctx.convert(
                m_impl->m_audio_frame->data,
                frame_samples,
                pcm_buffer.data() + current_size,
                out_samples_needed
            );

            // Adjust buffer to actual output size
            pcm_buffer.resize(current_size + static_cast<size_t>(out_samples * RESAMPLER_OUTPUT_CHANNELS));
            total_output_samples += out_samples;

            av_frame_unref(m_impl->m_audio_frame);
        }

        // Check if we've decoded enough
        TimeUS decoded_duration_us = (total_output_samples * 1000000LL) / out.sample_rate;
        if (decoded_start_us >= 0 && decoded_start_us + decoded_duration_us >= t1_us) {
            break;
        }
    }

done:
    // Flush any remaining samples from resampler
    if (total_output_samples > 0) {
        size_t flush_buffer_size = 1024 * RESAMPLER_OUTPUT_CHANNELS;
        size_t current_size = pcm_buffer.size();
        pcm_buffer.resize(current_size + flush_buffer_size);

        int64_t flushed = m_impl->resample_ctx.flush(
            pcm_buffer.data() + current_size,
            1024
        );

        pcm_buffer.resize(current_size + static_cast<size_t>(flushed * RESAMPLER_OUTPUT_CHANNELS));
        total_output_samples += flushed;
    }

    // Handle case where we got no audio (EOF before range)
    if (decoded_start_us < 0) {
        decoded_start_us = t0_us;
    }

    // Create PcmChunk
    // Note: Resampler always outputs stereo (2 channels) regardless of source
    // See ffmpeg_resample.h - "Converts any input format to float32 stereo"
    auto chunk_impl = std::make_unique<PcmChunkImpl>(
        out.sample_rate,
        2,  // Resampler always outputs stereo
        out.fmt,
        decoded_start_us,
        std::move(pcm_buffer)
    );

    return std::make_shared<PcmChunk>(std::move(chunk_impl));
}

// =============================================================================
// Prefetch Thread Implementation
// =============================================================================

void Reader::StartPrefetch(int direction) {
    assert(direction >= -1 && direction <= 1 && "direction must be -1, 0, or 1");

    if (direction == 0) {
        StopPrefetch();
        return;
    }

    // Prefetch is for video frames - skip for audio-only files
    if (!m_media_file->info().has_video) {
        return;
    }

    // Sync last_mode to current global mode so prefetch output doesn't get
    // cleared by a phantom mode transition on the next main-thread decode.
    m_impl->last_mode = GetDecodeMode();

    // Reset decode counter for diagnostics/testing.
    m_impl->prefetch_frames_decoded.store(0);

    // Force prefetch to seek on restart.  Without this, have_prefetch_pos
    // retains the stale prefetch_decode_pts from the previous session.
    // If that position is within 2s of the new target, need_seek() returns
    // false and the prefetch tries to decode forward from the old format-
    // context read position — potentially hundreds of frames behind the
    // playhead.  The entire clip plays with zero prefetch output, causing
    // stale-cache rejections on every frame past the initial batch.
    m_impl->have_prefetch_pos.store(false);

    // Initialize prefetch decoder if not already done (lazy init)
    if (!m_impl->prefetch_decoder_initialized) {
        const std::string& path = m_media_file->info().path;

        // Open separate format context for prefetch thread
        auto fmt_result = m_impl->prefetch_fmt_ctx.open(path);
        if (fmt_result.is_error()) {
            EMP_LOG_WARN("Failed to open format ctx: %s",
                    fmt_result.error().message.c_str());
            return;  // Can't prefetch without decoder
        }

        auto stream_result = m_impl->prefetch_fmt_ctx.find_video_stream();
        if (stream_result.is_error()) {
            EMP_LOG_WARN("Failed to find video stream");
            return;
        }

        AVCodecParameters* params = m_impl->prefetch_fmt_ctx.video_codec_params();
        auto codec_result = m_impl->prefetch_codec_ctx.init(params);
        if (codec_result.is_error()) {
            EMP_LOG_WARN("Failed to init codec: %s",
                    codec_result.error().message.c_str());
            return;
        }

        // Initialize scaler if software decode
        if (!m_impl->prefetch_codec_ctx.is_hw_accelerated()) {
            auto scale_result = m_impl->prefetch_scale_ctx.init(
                params->width, params->height,
                static_cast<AVPixelFormat>(params->format),
                params->width, params->height
            );
            if (scale_result.is_error()) {
                EMP_LOG_WARN("Failed to init scaler");
                return;
            }
        }

        m_impl->prefetch_decoder_initialized = true;
        EMP_LOG_DEBUG("Decoder initialized (hw=%d)",
                m_impl->prefetch_codec_ctx.is_hw_accelerated());
    }

    // Update direction (wakes thread if already running)
    m_impl->prefetch_direction.store(direction);
    m_impl->prefetch_cv.notify_one();

    // Start thread if not already running
    if (!m_impl->prefetch_running.load()) {
        m_impl->prefetch_running.store(true);

        // Join any previous thread first
        if (m_impl->prefetch_thread.joinable()) {
            m_impl->prefetch_thread.join();
        }

        m_impl->prefetch_thread = std::thread([this]() {
            prefetch_worker();
        });
    }
}

void Reader::StopPrefetch() {
    m_impl->prefetch_direction.store(0);
    m_impl->prefetch_running.store(false);
    m_impl->prefetch_cv.notify_all();

    if (m_impl->prefetch_thread.joinable()) {
        m_impl->prefetch_thread.join();
    }
}

void Reader::UpdatePrefetchTarget(TimeUS t_us) {
    m_impl->prefetch_target.store(t_us);
    m_impl->prefetch_cv.notify_one();
}

std::shared_ptr<Frame> Reader::GetCachedFrame(TimeUS t_us) {
    std::lock_guard<std::mutex> lock(m_impl->cache_mutex);

    if (m_impl->frame_cache.empty()) {
        return nullptr;
    }

    // Only return from cache if target is within cached range
    if (t_us > m_impl->cache_max_pts) {
        return nullptr;  // Target is beyond cache - miss
    }

    auto it = m_impl->frame_cache.upper_bound(t_us);
    if (it != m_impl->frame_cache.begin()) {
        --it;  // Now points to largest pts <= t_us

        // Reject stale floor matches — if the nearest cached frame is more
        // than 2 frame durations away, this is a sparse cache gap, not a hit.
        // Without this check, scattered Park frames silently freeze playback.
        TimeUS gap = t_us - it->first;
        if (gap > m_impl->max_floor_gap_us.load()) {
            return nullptr;
        }

        return it->second;
    }

    // t_us is before all cached frames
    return nullptr;
}

void Reader::prefetch_worker() {
    // Prefetch thread uses its OWN decoder resources - no contention with main thread!
    // Both threads share only the frame cache (protected by cache_mutex).

    // Use prefetch thread's own format context, codec context, etc.
    AVFormatContext* fmt_ctx = m_impl->prefetch_fmt_ctx.get();
    AVStream* stream = m_impl->prefetch_fmt_ctx.video_stream();
    int stream_idx = m_impl->prefetch_fmt_ctx.video_stream_index();

    // Lookahead amount in microseconds
    constexpr TimeUS LOOKAHEAD_US = 500000;  // 0.5 seconds

    EMP_LOG_DEBUG("Thread started (separate decoder)");

    while (m_impl->prefetch_running.load()) {
        int dir = m_impl->prefetch_direction.load();

        if (dir == 0) {
            // Stopped - wait for signal
            std::unique_lock<std::mutex> lock(m_impl->prefetch_mutex);
            m_impl->prefetch_cv.wait_for(lock, std::chrono::milliseconds(50));
            continue;
        }

        TimeUS target = m_impl->prefetch_target.load();
        TimeUS lookahead = (dir > 0) ? LOOKAHEAD_US : -LOOKAHEAD_US;
        TimeUS prefetch_to = target + lookahead;

        // Clamp to valid range
        if (prefetch_to < 0) prefetch_to = 0;
        TimeUS duration = m_media_file->info().duration_us;
        if (prefetch_to > duration) prefetch_to = duration;

        // Check if we need to decode (simple bounds check).
        // Stale sessions are already handled by DecodeAtUS's stale-session
        // detection (clears cache when target is >1s outside cached range),
        // so cache_max_pts/cache_min_pts are always from the current session.
        bool need_decode = false;
        {
            std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
            if (m_impl->frame_cache.empty()) {
                need_decode = true;
            } else if (dir > 0) {
                need_decode = (prefetch_to > m_impl->cache_max_pts);
            } else {
                need_decode = (prefetch_to < m_impl->cache_min_pts);
            }
        }

        if (need_decode) {
            auto decode_start = std::chrono::steady_clock::now();
            // No decode_mutex needed - we have our own decoder!

            // Seek target: continue from where the cache ends.
            // Direction-aware: forward starts past cache_max_pts to avoid
            // re-decoding; reverse seeks to prefetch_to so FFmpeg lands on
            // a keyframe BEFORE the region we need.
            TimeUS seek_target = target;
            {
                std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
                if (!m_impl->frame_cache.empty()) {
                    if (dir > 0 && m_impl->cache_max_pts > seek_target) {
                        seek_target = m_impl->cache_max_pts;
                    } else if (dir < 0) {
                        seek_target = prefetch_to;
                    }
                }
            }

            bool do_seek = impl::need_seek(
                m_impl->prefetch_decode_pts.load(),
                seek_target,
                m_impl->have_prefetch_pos.load()
            );
            EMP_LOG_DEBUG("Prefetch: need_decode=1 seek=%d target=%lldus seek_to=%lldus prefetch_to=%lldus",
                    do_seek, (long long)target, (long long)seek_target, (long long)prefetch_to);
            if (do_seek) {
                auto seek_result = impl::seek_with_backoff(
                    fmt_ctx, stream, m_impl->prefetch_codec_ctx.get(), seek_target, 0
                );
                if (seek_result.is_error()) {
                    EMP_LOG_DEBUG("Prefetch seek failed: %s",
                            seek_result.error().message.c_str());
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    continue;
                }
            }

            EMP_LOG_DEBUG("Prefetch: decoding batch (target=%lldus)...", (long long)prefetch_to);

            // Decode batch using prefetch thread's own decoder
            auto batch_result = impl::decode_frames_batch(
                m_impl->prefetch_codec_ctx.get(), fmt_ctx, stream, stream_idx,
                prefetch_to, m_impl->m_prefetch_pkt, m_impl->m_prefetch_frame
            );

            if (batch_result.is_error()) {
                if (batch_result.error().code == ErrorCode::EOFReached) {
                    EMP_LOG_DEBUG("Prefetch: reached EOF");
                } else {
                    EMP_LOG_WARN("Prefetch decode failed: %s",
                            batch_result.error().message.c_str());
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            }

            // Convert and add to shared cache (under cache lock only)
            auto& decoded_frames = batch_result.value();

            // Track prefetch decode count + decoder position
            m_impl->prefetch_frames_decoded.fetch_add(
                static_cast<int64_t>(decoded_frames.size()));
            if (!decoded_frames.empty()) {
                TimeUS pf_max = decoded_frames[0].pts_us;
                for (const auto& df : decoded_frames) {
                    if (df.pts_us > pf_max) pf_max = df.pts_us;
                }
                m_impl->prefetch_decode_pts.store(pf_max);
                m_impl->have_prefetch_pos.store(true);
            }

            {
                std::lock_guard<std::mutex> lock(m_impl->cache_mutex);

                for (auto& df : decoded_frames) {
                    if (m_impl->frame_cache.find(df.pts_us) == m_impl->frame_cache.end()) {
                        // Use prefetch thread's scale context
                        auto emp_frame = avframe_to_emp_frame(
                            df.frame, df.pts_us,
                            m_impl->prefetch_scale_ctx, m_impl->prefetch_codec_ctx
                        );
                        m_impl->frame_cache[df.pts_us] = emp_frame;

                        if (df.pts_us < m_impl->cache_min_pts) {
                            m_impl->cache_min_pts = df.pts_us;
                        }
                        if (df.pts_us > m_impl->cache_max_pts) {
                            m_impl->cache_max_pts = df.pts_us;
                        }
                    }
                    av_frame_free(&df.frame);
                }

                // Evict old frames
                evict_cache_frames(
                    m_impl->frame_cache,
                    m_impl->cache_min_pts, m_impl->cache_max_pts,
                    target, m_impl->max_cache_frames
                );
            }

            // Cache full — prefetch has filled available space.
            // Check under lock, sleep outside to avoid blocking main thread.
            bool cache_full = false;
            {
                std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
                cache_full = (m_impl->frame_cache.size() >= m_impl->max_cache_frames);
            }
            if (cache_full) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }

            auto decode_end = std::chrono::steady_clock::now();
            auto decode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                decode_end - decode_start).count();
            EMP_LOG_DEBUG("Decoded %zu frames in %lldms, cache=%zu",
                    decoded_frames.size(), static_cast<long long>(decode_ms),
                    m_impl->frame_cache.size());
        } else {
            // Cache is ahead - sleep briefly
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    EMP_LOG_DEBUG("Thread stopped");
}

} // namespace emp
