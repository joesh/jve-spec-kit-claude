#include <editor_media_platform/emp_reader.h>
#include "impl/ffmpeg_context.h"
#include "impl/ffmpeg_resample.h"
#include "impl/asset_impl.h"
#include "impl/frame_impl.h"
#include "impl/pcm_chunk_impl.h"
#include <cassert>
#include <vector>

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
}

// ReaderImpl holds FFmpeg decode state
class ReaderImpl {
public:
    ReaderImpl() {
        m_pkt = av_packet_alloc();
        m_frame = av_frame_alloc();
        m_best_frame = av_frame_alloc();
        m_audio_pkt = av_packet_alloc();
        m_audio_frame = av_frame_alloc();
        assert(m_pkt && m_frame && m_best_frame);
        assert(m_audio_pkt && m_audio_frame);
    }

    ~ReaderImpl() {
        av_packet_free(&m_pkt);
        av_frame_free(&m_frame);
        av_frame_free(&m_best_frame);
        av_packet_free(&m_audio_pkt);
        av_frame_free(&m_audio_frame);
    }

    // Video decode state
    impl::FFmpegCodecContext codec_ctx;
    impl::FFmpegScaleContext scale_ctx;
    AVPacket* m_pkt = nullptr;
    AVFrame* m_frame = nullptr;
    AVFrame* m_best_frame = nullptr;

    // Current video decoder state
    bool have_current_pts = false;
    TimeUS current_pts_us = 0;

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

Reader::~Reader() = default;

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

    if (result.is_ok()) {
        m_impl->have_current_pts = false;
        m_impl->current_pts_us = 0;
    }

    return result;
}

Result<std::shared_ptr<Frame>> Reader::DecodeAt(FrameTime t) {
    return DecodeAtUS(t.to_us());
}

Result<std::shared_ptr<Frame>> Reader::DecodeAtUS(TimeUS t_us) {
    AssetImpl* asset_impl = m_asset->impl_ptr();
    AVFormatContext* fmt_ctx = asset_impl->fmt_ctx.get();
    AVStream* stream = asset_impl->fmt_ctx.video_stream();
    int stream_idx = asset_impl->fmt_ctx.video_stream_index();

    // Check if we need to seek
    if (impl::need_seek(m_impl->current_pts_us, t_us, m_impl->have_current_pts)) {
        auto seek_result = impl::seek_with_backoff(
            fmt_ctx, stream, m_impl->codec_ctx.get(), t_us
        );
        if (seek_result.is_error()) {
            return seek_result.error();
        }
        m_impl->have_current_pts = false;
    }

    // Decode until we find floor frame
    auto decode_result = impl::decode_until_target(
        m_impl->codec_ctx.get(),
        fmt_ctx,
        stream,
        stream_idx,
        t_us,
        m_impl->m_pkt,
        m_impl->m_frame,
        m_impl->m_best_frame
    );

    if (decode_result.is_error()) {
        return decode_result.error();
    }

    AVFrame* result_frame = decode_result.value();

    // Update current position
    m_impl->current_pts_us = impl::stream_pts_to_us(result_frame->pts, stream);
    m_impl->have_current_pts = true;

#ifdef EMP_HAS_VIDEOTOOLBOX
    // Check if this is a hardware-accelerated frame (VideoToolbox)
    if (result_frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        // Extract CVPixelBuffer from AVFrame
        // For VideoToolbox, data[3] contains the CVPixelBufferRef
        CVPixelBufferRef pixel_buffer = (CVPixelBufferRef)result_frame->data[3];
        assert(pixel_buffer && "VideoToolbox frame missing CVPixelBuffer");

        // Calculate stride for when lazy CPU transfer happens
        int stride = ((result_frame->width * 4) + 31) & ~31;

        // Create Frame with hw buffer (lazy CPU transfer)
        auto frame_impl = std::make_unique<FrameImpl>(
            result_frame->width,
            result_frame->height,
            stride,
            m_impl->current_pts_us,
            pixel_buffer  // FrameImpl will retain this
        );

        return std::make_shared<Frame>(std::move(frame_impl));
    }
#endif

    // Software decode path: convert to BGRA32 immediately
    int stride;
    auto buffer = impl::allocate_bgra_buffer(result_frame->width, result_frame->height, &stride);
    impl::convert_frame_to_bgra(m_impl->scale_ctx, result_frame, buffer.data(), stride);

    // Create Frame with CPU buffer
    auto frame_impl = std::make_unique<FrameImpl>(
        result_frame->width,
        result_frame->height,
        stride,
        m_impl->current_pts_us,
        std::move(buffer)
    );

    return std::make_shared<Frame>(std::move(frame_impl));
}

Result<std::shared_ptr<PcmChunk>> Reader::DecodeAudioRange(FrameTime t0, FrameTime t1,
                                                            const AudioFormat& out) {
    return DecodeAudioRangeUS(t0.to_us(), t1.to_us(), out);
}

Result<std::shared_ptr<PcmChunk>> Reader::DecodeAudioRangeUS(TimeUS t0_us, TimeUS t1_us,
                                                              const AudioFormat& out) {
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
    pcm_buffer.reserve(static_cast<size_t>(max_samples * out.channels));

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
            pcm_buffer.resize(current_size + static_cast<size_t>(out_samples_needed * out.channels));

            int64_t out_samples = m_impl->resample_ctx.convert(
                m_impl->m_audio_frame->data,
                frame_samples,
                pcm_buffer.data() + current_size,
                out_samples_needed
            );

            // Adjust buffer to actual output size
            pcm_buffer.resize(current_size + static_cast<size_t>(out_samples * out.channels));
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
        size_t flush_buffer_size = 1024 * out.channels;
        size_t current_size = pcm_buffer.size();
        pcm_buffer.resize(current_size + flush_buffer_size);

        int64_t flushed = m_impl->resample_ctx.flush(
            pcm_buffer.data() + current_size,
            1024
        );

        pcm_buffer.resize(current_size + static_cast<size_t>(flushed * out.channels));
        total_output_samples += flushed;
    }

    // Handle case where we got no audio (EOF before range)
    if (decoded_start_us < 0) {
        decoded_start_us = t0_us;
    }

    // Create PcmChunk
    auto chunk_impl = std::make_unique<PcmChunkImpl>(
        out.sample_rate,
        out.channels,
        out.fmt,
        decoded_start_us,
        std::move(pcm_buffer)
    );

    return std::make_shared<PcmChunk>(std::move(chunk_impl));
}

} // namespace emp
