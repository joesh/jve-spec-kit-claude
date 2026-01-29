#include <editor_media_platform/emp_reader.h>
#include "impl/ffmpeg_context.h"
#include "impl/ffmpeg_resample.h"
#include "impl/asset_impl.h"
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

// Forward declarations from impl files
namespace impl {
Result<AVFrame*> decode_next_frame(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                    int stream_idx, AVPacket* pkt, AVFrame* frame);
Result<AVFrame*> decode_until_target(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                      AVStream* stream, int stream_idx,
                                      TimeUS target_us,
                                      AVPacket* pkt, AVFrame* frame, AVFrame* best_frame);
Result<void> seek_with_backoff(AVFormatContext* fmt_ctx, AVStream* stream,
                                AVCodecContext* codec_ctx, TimeUS target_us);
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

    // Frame cache: stores ALL decoded frames by PTS
    // Key: PTS in microseconds, Value: shared_ptr<Frame>
    // This captures ALL decoder output to avoid B-frame reordering losses
    std::map<TimeUS, std::shared_ptr<Frame>> frame_cache;
    TimeUS cache_min_pts = INT64_MAX;
    TimeUS cache_max_pts = INT64_MIN;
    static constexpr size_t MAX_CACHE_FRAMES = 120;  // ~5s at 24fps - larger for reverse

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
};

Reader::Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<Asset> asset)
    : m_impl(std::move(impl)), m_asset(std::move(asset)) {
    assert(m_impl && m_asset && "Reader impl/asset cannot be null");
}

Reader::~Reader() {
    // Stop prefetch thread before destroying impl
    StopPrefetch();
}

std::shared_ptr<Asset> Reader::asset() const {
    return m_asset;
}

Result<std::shared_ptr<Reader>> Reader::Create(std::shared_ptr<Asset> asset) {
    if (!asset) {
        return Error::invalid_arg("Asset is null");
    }
    if (!asset->info().has_video) {
        return Error::unsupported("Asset has no video stream");
    }

    auto impl = std::make_unique<ReaderImpl>();

    // Get format context from asset (requires friend access)
    AssetImpl* asset_impl = asset->impl_ptr();
    AVCodecParameters* params = asset_impl->fmt_ctx.video_codec_params();

    // Initialize codec
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
    AssetImpl* asset_impl = m_asset->impl_ptr();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();

    auto result = impl::seek_with_backoff(
        asset_impl->fmt_ctx.get(),
        stream,
        m_impl->codec_ctx.get(),
        t_us
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

Result<std::shared_ptr<Frame>> Reader::DecodeAtUS(TimeUS t_us) {
    AssetImpl* asset_impl = m_asset->impl_ptr();
    AVFormatContext* fmt_ctx = asset_impl->fmt_ctx.get();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();
    int stream_idx = asset_impl->fmt_ctx.video_stream_index();

    static int cache_hits = 0, cache_misses = 0;
    static auto last_log = std::chrono::steady_clock::now();

    // 1. Check cache first (fast path) - thread-safe lookup
    {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        if (!m_impl->frame_cache.empty() && t_us <= m_impl->cache_max_pts) {
            auto it = m_impl->frame_cache.upper_bound(t_us);
            if (it != m_impl->frame_cache.begin()) {
                --it;  // Now points to largest pts <= t_us
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

    // Check cache state under lock
    bool need_seek_backward = false;
    bool cache_empty = false;
    {
        std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
        cache_empty = m_impl->frame_cache.empty();
        need_seek_backward = (t_us < m_impl->cache_min_pts && m_impl->cache_min_pts != INT64_MAX);
    }

    if (need_seek_backward) {
        auto seek_result = impl::seek_with_backoff(
            fmt_ctx, stream, m_impl->codec_ctx.get(), t_us
        );
        if (seek_result.is_error()) {
            return seek_result.error();
        }
    }

    if (cache_empty) {
        auto seek_result = impl::seek_with_backoff(
            fmt_ctx, stream, m_impl->codec_ctx.get(), t_us
        );
        if (seek_result.is_error()) {
            return seek_result.error();
        }
    }

    // 3. Decode frames until we find one at/past target
    auto batch_result = impl::decode_frames_batch(
        m_impl->codec_ctx.get(), fmt_ctx, stream, stream_idx,
        t_us, m_impl->m_pkt, m_impl->m_frame
    );

    if (batch_result.is_error()) {
        return batch_result.error();
    }

    // 4. Convert and add to shared cache (under cache lock)
    auto& decoded_frames = batch_result.value();

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
        auto decode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(decode_end - decode_start).count();
        if (decode_ms > 10) {
            EMP_LOG_DEBUG("Decode batch: %zu frames in %lldms (%.1fms/frame)",
                    decoded_frames.size(), static_cast<long long>(decode_ms),
                    decoded_frames.size() > 0 ? (double)decode_ms / decoded_frames.size() : 0);
        }

        // Evict old frames
        evict_cache_frames(
            m_impl->frame_cache,
            m_impl->cache_min_pts, m_impl->cache_max_pts,
            t_us, ReaderImpl::MAX_CACHE_FRAMES
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
    if (!m_asset->info().has_audio) {
        return Error::unsupported("Asset has no audio stream");
    }
    if (!m_impl->audio_initialized) {
        return Error::unsupported("Audio codec not initialized");
    }
    if (t1_us <= t0_us) {
        return Error::invalid_arg("DecodeAudioRangeUS: t1 must be > t0");
    }

    AssetImpl* asset_impl = m_asset->impl_ptr();
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

    // Initialize prefetch decoder if not already done (lazy init)
    if (!m_impl->prefetch_decoder_initialized) {
        const std::string& path = m_asset->info().path;

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
        TimeUS duration = m_asset->info().duration_us;
        if (prefetch_to > duration) prefetch_to = duration;

        // Check if we need to decode (check under lock)
        bool need_decode = false;
        {
            std::lock_guard<std::mutex> lock(m_impl->cache_mutex);
            if (m_impl->frame_cache.empty()) {
                need_decode = true;
            } else if (dir > 0) {
                // Forward: need to decode if prefetch target is past cache max
                need_decode = (prefetch_to > m_impl->cache_max_pts);
            } else {
                // Reverse: need to decode if prefetch target is before cache min
                need_decode = (prefetch_to < m_impl->cache_min_pts);
            }
        }

        if (need_decode) {
            auto decode_start = std::chrono::steady_clock::now();
            // No decode_mutex needed - we have our own decoder!

            // For reverse, we need to seek backward first
            if (dir < 0 && prefetch_to < m_impl->cache_min_pts) {
                auto seek_result = impl::seek_with_backoff(
                    fmt_ctx, stream, m_impl->prefetch_codec_ctx.get(), prefetch_to
                );
                if (seek_result.is_error()) {
                    EMP_LOG_DEBUG("Seek failed: %s",
                            seek_result.error().message.c_str());
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    continue;
                }
            }

            // Decode batch using prefetch thread's own decoder
            auto batch_result = impl::decode_frames_batch(
                m_impl->prefetch_codec_ctx.get(), fmt_ctx, stream, stream_idx,
                prefetch_to, m_impl->m_prefetch_pkt, m_impl->m_prefetch_frame
            );

            if (batch_result.is_error()) {
                if (batch_result.error().code == ErrorCode::EOFReached) {
                    EMP_LOG_DEBUG("Reached EOF");
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            }

            // Convert and add to shared cache (under cache lock only)
            auto& decoded_frames = batch_result.value();
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
                    target, ReaderImpl::MAX_CACHE_FRAMES
                );
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
