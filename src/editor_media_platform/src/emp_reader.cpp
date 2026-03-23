#include <editor_media_platform/emp_reader.h>
#include "impl/ffmpeg_context.h"
#include "impl/ffmpeg_hwaccel.h"
#include "impl/ffmpeg_resample.h"
#include "impl/media_file_impl.h"
#include "impl/frame_impl.h"
#include "impl/pcm_chunk_impl.h"
#include <atomic>
#include <cassert>
#include <vector>
#include <memory>
#include <chrono>
#include <cstdio>

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
        assert(m_pkt && m_frame);
        assert(m_audio_pkt && m_audio_frame);
    }

    ~ReaderImpl() {
        av_packet_free(&m_pkt);
        av_frame_free(&m_frame);
        av_packet_free(&m_audio_pkt);
        av_frame_free(&m_audio_frame);
    }

    // Video decode state
    impl::FFmpegCodecContext codec_ctx;
    impl::FFmpegScaleContext scale_ctx;
    AVPacket* m_pkt = nullptr;
    AVFrame* m_frame = nullptr;

    // Tracks where the decoder was last positioned (PTS of last decoded frame).
    // Used by Play path to avoid unnecessary seeks during sequential decode.
    TimeUS last_decode_pts = INT64_MIN;
    bool have_decode_pos = false;

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

    // Resampler FIFO residual tracking. When we skip the flush between
    // sequential decodes, some output samples stay in the FIFO and appear
    // at the start of the NEXT call's output. We track the expected vs
    // actual output delta so the next call can decode fewer input frames
    // and still produce the correct total.
    int64_t resample_owed_samples = 0;  // samples FIFO owes us from last call

    // Per-frame decode time from the last batch decode (play path).
    // batch_total_ms / batch_frame_count. Set on each batch decode,
    // retained across cache-hit calls so callers always see the codec's
    // true per-frame cost rather than 0 (cache hit) or N*frame (batch).
    float last_batch_ms_per_frame = -1.0f;

    // ── Audio decode cache ──
    // Chunk-based cache of decoded PCM in source coordinates.
    // Prevents backward seeks when multiple callers (prefetch, mix thread,
    // pump) access the same Reader at different timeline boundaries.
    // Each caller's sequential decodes accumulate into contiguous chunks;
    // discontinuous callers create separate chunks (no data loss).
    // The Reader pool's use_mutex serializes access, so no internal lock.
    struct AudioDecodeCache {
        struct Chunk {
            TimeUS start_us;
            TimeUS end_us;
            int32_t sample_rate;
            int32_t channels;
            std::vector<float> pcm;
        };

        std::vector<Chunk> chunks;
        static constexpr size_t MAX_CHUNKS = 24;
        // Contiguity tolerance: resampling 44.1→48kHz can produce chunks
        // whose boundaries differ by ~20ms from the next request start.
        static constexpr TimeUS CONTIGUITY_TOLERANCE_US = 50000;  // 50ms

        // Find a single chunk that covers [t0, t1) within tolerance.
        // Resampling (e.g. 44.1→48kHz) can produce chunks whose actual
        // duration is a few ms shorter than the requested range.
        // The extract clamps to available samples, so a small shortfall
        // yields slightly fewer output frames (inaudible at <50ms).
        static constexpr TimeUS COVERAGE_TOLERANCE_US = 50000;  // 50ms

        std::shared_ptr<PcmChunk> find_and_extract(
                TimeUS t0, TimeUS t1, int32_t sr, SampleFormat fmt) const {
            for (const auto& c : chunks) {
                if (c.sample_rate != sr) continue;
                if (c.start_us > t0 || c.end_us + COVERAGE_TOLERANCE_US < t1) continue;

                int64_t skip = ((t0 - c.start_us) * c.sample_rate) / 1000000;
                int64_t want = ((t1 - t0) * c.sample_rate) / 1000000;
                int64_t total = static_cast<int64_t>(c.pcm.size()) / c.channels;
                if (skip < 0) skip = 0;
                if (skip + want > total) want = total - skip;
                if (want <= 0) continue;

                std::vector<float> sub(static_cast<size_t>(want * c.channels));
                std::copy(c.pcm.data() + skip * c.channels,
                          c.pcm.data() + (skip + want) * c.channels,
                          sub.data());
                auto impl = std::make_unique<PcmChunkImpl>(
                    c.sample_rate, c.channels, fmt, t0, std::move(sub));
                return std::make_shared<PcmChunk>(std::move(impl));
            }
            return nullptr;
        }

        void store(TimeUS t0, TimeUS t1, const float* data, int64_t frames,
                   int32_t sr, int32_t ch) {
            // Try to extend an existing chunk (forward or backward contiguous)
            for (auto& c : chunks) {
                if (c.sample_rate != sr || c.channels != ch) continue;

                if (std::abs(t0 - c.end_us) < CONTIGUITY_TOLERANCE_US) {
                    // Forward contiguous — append
                    c.pcm.insert(c.pcm.end(), data, data + frames * ch);
                    c.end_us = t1;
                    trim_chunk(c);
                    return;
                }
                if (std::abs(t1 - c.start_us) < CONTIGUITY_TOLERANCE_US) {
                    // Backward contiguous — prepend
                    c.pcm.insert(c.pcm.begin(), data, data + frames * ch);
                    c.start_us = t0;
                    trim_chunk(c);
                    return;
                }
                // Check if new data is fully contained within existing chunk
                if (c.start_us <= t0 && c.end_us >= t1) {
                    return;  // Already have this data
                }
            }

            // No contiguous match — add as new chunk, evict oldest if full
            while (chunks.size() >= MAX_CHUNKS) {
                chunks.erase(chunks.begin());
            }
            Chunk nc;
            nc.start_us = t0;
            nc.end_us = t1;
            nc.sample_rate = sr;
            nc.channels = ch;
            nc.pcm.assign(data, data + frames * ch);
            chunks.push_back(std::move(nc));
        }

        void clear() { chunks.clear(); }

    private:
        // Must be larger than max playback duration so pump's requests
        // always find data from the continuous prefetch decode.
        // 48kHz stereo × 60s = ~23 MB — acceptable for a single Reader.
        static constexpr TimeUS MAX_CHUNK_DURATION_US = 60000000;  // 60s per chunk

        static void trim_chunk(Chunk& c) {
            if (c.end_us - c.start_us <= MAX_CHUNK_DURATION_US) return;
            TimeUS trim_to = c.end_us - MAX_CHUNK_DURATION_US;
            int64_t trim_samples = ((trim_to - c.start_us) * c.sample_rate) / 1000000;
            int64_t total = static_cast<int64_t>(c.pcm.size()) / c.channels;
            if (trim_samples > 0 && trim_samples < total) {
                c.pcm.erase(c.pcm.begin(), c.pcm.begin() + trim_samples * c.channels);
                c.start_us = trim_to;
            }
        }
    };

    AudioDecodeCache audio_cache;
};

Reader::Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<MediaFile> asset)
    : m_impl(std::move(impl)), m_media_file(std::move(asset)) {
    assert(m_impl && m_media_file && "Reader impl/media_file cannot be null");
}

Reader::~Reader() = default;

bool Reader::IsHwAccelerated() const {
    return m_impl->codec_ctx.is_hw_accelerated();
}

float Reader::LastBatchMsPerFrame() const {
    return m_impl->last_batch_ms_per_frame;
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

        // Log HW decode status — SW fallback on VT-capable codec is a perf disaster
        if (impl->codec_ctx.is_hw_accelerated()) {
            EMP_LOG_DEBUG("Reader::Create: VT hw_accel codec=%d %dx%d path=%s",
                    params->codec_id, params->width, params->height,
                    asset->info().path.c_str());
        } else if (impl::codec_supports_videotoolbox(params->codec_id)) {
            EMP_LOG_WARN("SW decode: codec=%d %dx%d — VT unsupported for this file. path=%s",
                    params->codec_id, params->width, params->height,
                    asset->info().path.c_str());
        } else {
            EMP_LOG_DEBUG("Reader::Create: SW decode (no VT support) codec=%d %dx%d path=%s",
                    params->codec_id, params->width, params->height,
                    asset->info().path.c_str());
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

    // Initialize audio codec if asset has audio.
    // NSF-ACCEPT: Audio codec failure is non-fatal — Reader::Create succeeds
    // but audio_initialized=false. DecodeAudioRangeUS returns Error::unsupported
    // when called on such a Reader. Caller (TMB) treats this as silence/gap.
    if (asset->info().has_audio) {
        AVCodecParameters* audio_params = asset_impl->fmt_ctx.audio_codec_params();
        auto audio_codec_result = impl->audio_codec_ctx.init(audio_params);
        if (audio_codec_result.is_error()) {
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


Result<std::shared_ptr<Frame>> Reader::DecodeAtUS(TimeUS t_us) {
    if (!m_media_file->info().has_video) {
        return Error::unsupported("DecodeAt requires video stream");
    }

    MediaFileImpl* asset_impl = m_media_file->impl_ptr();
    AVFormatContext* fmt_ctx = asset_impl->fmt_ctx.get();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();
    int stream_idx = asset_impl->fmt_ctx.video_stream_index();

    DecodeMode mode = GetDecodeMode();
    auto decode_start = std::chrono::steady_clock::now();

    // Seek decision: Park/Scrub always seek. Play seeks only when needed.
    if (mode == DecodeMode::Scrub || mode == DecodeMode::Park) {
        auto seek_result = impl::seek_with_backoff(
            fmt_ctx, stream, m_impl->codec_ctx.get(), t_us, 0
        );
        if (seek_result.is_error()) {
            return seek_result.error();
        }
    } else {
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
        // Scrub/Park: decode-and-discard intermediates, keep only floor frame.
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

        AVFrame* floor_frame = target_result.value();
        TimeUS floor_pts = impl::stream_pts_to_us(floor_frame->pts, stream);
        auto result = avframe_to_emp_frame(
            floor_frame, floor_pts, m_impl->scale_ctx, m_impl->codec_ctx
        );
        av_frame_free(&best_frame);

        // Decoder position is indeterminate after scrub/park decode.
        // Force seek on next Play call.
        m_impl->have_decode_pos = false;

        auto decode_end = std::chrono::steady_clock::now();
        auto decode_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            decode_end - decode_start).count();
        if (decode_ms > 10) {
            EMP_LOG_DEBUG("Decode target: %lldms mode=%s",
                    static_cast<long long>(decode_ms),
                    mode == DecodeMode::Scrub ? "scrub" : "park");
        }

        return result;
    }

    // Play path: decode frames up to target, convert only the target frame.
    auto batch_result = impl::decode_frames_batch(
        m_impl->codec_ctx.get(), fmt_ctx, stream, stream_idx,
        t_us, m_impl->m_pkt, m_impl->m_frame
    );

    if (batch_result.is_error()) {
        return batch_result.error();
    }

    auto& decoded_frames = batch_result.value();
    assert(!decoded_frames.empty() && "decode_frames_batch returned empty batch");

    // Track decoder position as max PTS of this batch.
    TimeUS batch_max_pts = decoded_frames[0].pts_us;
    for (const auto& df : decoded_frames) {
        if (df.pts_us > batch_max_pts) batch_max_pts = df.pts_us;
    }
    m_impl->last_decode_pts = batch_max_pts;
    m_impl->have_decode_pos = true;

    // Find floor frame: largest PTS <= target.
    int floor_idx = -1;
    TimeUS floor_pts = INT64_MIN;
    for (size_t i = 0; i < decoded_frames.size(); ++i) {
        if (decoded_frames[i].pts_us <= t_us && decoded_frames[i].pts_us > floor_pts) {
            floor_idx = static_cast<int>(i);
            floor_pts = decoded_frames[i].pts_us;
        }
    }
    // If no frame <= target, take the first (closest to target).
    if (floor_idx < 0) {
        floor_idx = 0;
        floor_pts = decoded_frames[0].pts_us;
    }

    // Convert only the target frame to BGRA.
    auto result = avframe_to_emp_frame(
        decoded_frames[floor_idx].frame, floor_pts,
        m_impl->scale_ctx, m_impl->codec_ctx
    );

    // Record per-frame decode cost before freeing.
    auto decode_end = std::chrono::steady_clock::now();
    auto decode_us = std::chrono::duration_cast<std::chrono::microseconds>(
        decode_end - decode_start).count();
    float decode_ms = static_cast<float>(decode_us) / 1000.0f;
    m_impl->last_batch_ms_per_frame =
        decode_ms / static_cast<float>(decoded_frames.size());

    if (decode_ms > 10) {
        EMP_LOG_DEBUG("Decode: %zu frames in %.1fms (%.1fms/frame) floor_pts=%lld target=%lld",
                decoded_frames.size(), decode_ms,
                (double)decode_ms / decoded_frames.size(),
                (long long)floor_pts, (long long)t_us);
    }

    // Free all AVFrames.
    for (auto& df : decoded_frames) {
        av_frame_free(&df.frame);
    }

    return result;
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

    // ── Decode cache: serve from chunk cache if available ──
    // This prevents backward seeks when prefetch advances the decoder ahead
    // of on-demand callers (mix thread, pump). All callers share the same
    // Reader via the pool's use_mutex, so no additional locking needed.
    {
        // Full cache hit: entire [t0, t1) covered
        auto cached = m_impl->audio_cache.find_and_extract(
            t0_us, t1_us, out.sample_rate, out.fmt);
        if (cached) {
            return cached;
        }

        // Partial cache hit: cache covers [t0, X) where X < t1.
        if (m_impl->have_audio_pts && m_impl->audio_pts_us > t0_us
                && m_impl->audio_pts_us < t1_us) {
            auto prefix = m_impl->audio_cache.find_and_extract(
                t0_us, m_impl->audio_pts_us, out.sample_rate, out.fmt);
            if (prefix) {
                auto suffix_result = DecodeAudioRangeUS(
                    m_impl->audio_pts_us, t1_us, out);
                if (suffix_result.is_error() || !suffix_result.value()
                        || suffix_result.value()->frames() == 0) {
                    return prefix;
                }
                auto suffix = suffix_result.value();

                int64_t total_frames = prefix->frames() + suffix->frames();
                constexpr int STEREO = 2;
                std::vector<float> combined(total_frames * STEREO);
                std::copy(prefix->data_f32(),
                          prefix->data_f32() + prefix->frames() * STEREO,
                          combined.data());
                std::copy(suffix->data_f32(),
                          suffix->data_f32() + suffix->frames() * STEREO,
                          combined.data() + prefix->frames() * STEREO);

                auto impl = std::make_unique<PcmChunkImpl>(
                    out.sample_rate, STEREO, out.fmt, t0_us,
                    std::move(combined));
                return std::make_shared<PcmChunk>(std::move(impl));
            }
        }
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

    // Sequential decode optimization: skip seek if the decoder is already
    // positioned near the start of the requested range. For compressed formats
    // (MP3, AAC), seeking destroys the bit reservoir and is imprecise — causing
    // gaps and artifacts. Sequential decode produces gapless audio.
    constexpr TimeUS CONTIGUOUS_THRESHOLD_US = 100000;  // 100ms tolerance
    bool need_seek = true;
    if (m_impl->have_audio_pts) {
        int64_t gap = t0_us - m_impl->audio_pts_us;
        // Decoder is behind t0 but close enough — sequential decode will catch up
        if (gap >= 0 && gap < CONTIGUOUS_THRESHOLD_US) {
            need_seek = false;
        }
        // Decoder is slightly ahead of t0 — continue sequential decode.
        // The output will start at audio_pts (not t0), creating a small gap
        // at the beginning. decoded_start_us is set from the ACTUAL first
        // frame PTS, not t0, so callers know where the data really starts.
        if (gap < 0 && gap > -CONTIGUOUS_THRESHOLD_US) {
            need_seek = false;
        }
    }

    if (need_seek) {
        // Seek with pre-roll: start 50ms before t0 so the resampler's FIR
        // filter is primed with real audio before we start collecting output.
        // Without this, the first ~26ms of output are zeros (group delay).
        constexpr TimeUS RESAMPLER_PREROLL_US = 50000;  // 50ms
        TimeUS seek_target_us = std::max(static_cast<TimeUS>(0), t0_us - RESAMPLER_PREROLL_US);

        int64_t seek_pts = impl::us_to_stream_pts(seek_target_us, audio_stream);
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
        m_impl->resample_owed_samples = 0;  // FIFO is empty after reset
    }

    // Decode audio packets until we've covered [t0_us, t1_us)
    TimeUS decoded_start_us = -1;
    int64_t total_output_samples = 0;
    int ret;

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

            // Skip frames before our range. After a seek, feed them to the
            // resampler (but discard output) to prime the FIR filter — otherwise
            // the first ~26ms of output are zeros (group delay ramp-up).
            if (frame_end_us <= t0_us) {
                if (need_seek) {
                    int64_t prime_out = m_impl->resample_ctx.get_out_samples(frame_samples);
                    if (prime_out > 0) {
                        std::vector<float> discard(prime_out * RESAMPLER_OUTPUT_CHANNELS);
                        m_impl->resample_ctx.convert(
                            m_impl->m_audio_frame->data, frame_samples,
                            discard.data(), prime_out);
                    }
                }
                av_frame_unref(m_impl->m_audio_frame);
                continue;
            }

            // Don't stop on PTS alone — the resampler's FIR filter may need
            // frames past t1 to push out enough output samples. The output
            // sample count check (below) is the authoritative stop condition.

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

        // Check if we've produced enough output samples.
        // Need expected + owed because owed samples will be trimmed (they're
        // FIFO residual from previous call, belonging to the previous range).
        int64_t expected_samples = ((t1_us - t0_us) * out.sample_rate) / 1000000;
        int64_t need_total = expected_samples + (need_seek ? 0 : m_impl->resample_owed_samples);
        if (total_output_samples >= need_total) {
            break;
        }
    }

done:
    // NEVER flush the resampler. The FIR filter's FIFO residual carries over
    // to the next call, producing continuous audio across ALL calls (including
    // the prefill→pump transition). Flushing creates a discontinuity because
    // the filter history is zeroed — verified at 44.1→48kHz.
    //
    // The FIFO retains residual samples from the previous call, which appear
    // at the START of this call's output. Trim them — they belong to the
    // previous call's time range.
    constexpr int RESAMPLER_OUT_CH = 2;

    if (m_impl->resample_owed_samples > 0) {
        int64_t skip = std::min(m_impl->resample_owed_samples, total_output_samples);
        if (skip > 0) {
            pcm_buffer.erase(pcm_buffer.begin(),
                             pcm_buffer.begin() + skip * RESAMPLER_OUT_CH);
            total_output_samples -= skip;
        }
    }

    // Track the deficit: how many samples the FIFO owes the NEXT call.
    {
        int64_t expected = ((t1_us - t0_us) * out.sample_rate) / 1000000;
        m_impl->resample_owed_samples = expected - total_output_samples;
        if (m_impl->resample_owed_samples < 0) m_impl->resample_owed_samples = 0;
    }

    decoded_start_us = t0_us;
    TimeUS decoded_end_us = decoded_start_us + (total_output_samples * 1000000LL) / out.sample_rate;
    m_impl->have_audio_pts = true;
    m_impl->audio_pts_us = decoded_end_us;

    // Store in decode cache before moving pcm_buffer
    m_impl->audio_cache.store(decoded_start_us, decoded_end_us,
                              pcm_buffer.data(), total_output_samples,
                              out.sample_rate, RESAMPLER_OUT_CH);

    auto chunk_impl = std::make_unique<PcmChunkImpl>(
        out.sample_rate,
        RESAMPLER_OUT_CH,
        out.fmt,
        decoded_start_us,
        std::move(pcm_buffer)
    );

    return std::make_shared<PcmChunk>(std::move(chunk_impl));
}


} // namespace emp
