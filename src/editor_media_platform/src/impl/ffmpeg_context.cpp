#include "ffmpeg_context.h"
#include "ffmpeg_hwaccel.h"
#include <cassert>

namespace emp {
namespace impl {

Error ffmpeg_error(int errnum, const std::string& context) {
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(errnum, errbuf, sizeof(errbuf));
    std::string msg = context + ": " + errbuf;

    // Map FFmpeg errors to EMP errors
    if (errnum == AVERROR(ENOENT) || errnum == AVERROR_EOF) {
        return Error::file_not_found(msg);
    } else if (errnum == AVERROR_INVALIDDATA || errnum == AVERROR(EINVAL)) {
        return Error::unsupported(msg);
    } else if (errnum == AVERROR_DECODER_NOT_FOUND) {
        return Error::unsupported("No decoder found: " + context);
    }
    return Error::internal(msg);
}

// FFmpegFormatContext implementation

FFmpegFormatContext::~FFmpegFormatContext() {
    if (m_fmt_ctx) {
        avformat_close_input(&m_fmt_ctx);
    }
}

FFmpegFormatContext::FFmpegFormatContext(FFmpegFormatContext&& other) noexcept
    : m_fmt_ctx(other.m_fmt_ctx),
      m_video_stream_idx(other.m_video_stream_idx),
      m_audio_stream_idx(other.m_audio_stream_idx) {
    other.m_fmt_ctx = nullptr;
    other.m_video_stream_idx = -1;
    other.m_audio_stream_idx = -1;
}

FFmpegFormatContext& FFmpegFormatContext::operator=(FFmpegFormatContext&& other) noexcept {
    if (this != &other) {
        if (m_fmt_ctx) {
            avformat_close_input(&m_fmt_ctx);
        }
        m_fmt_ctx = other.m_fmt_ctx;
        m_video_stream_idx = other.m_video_stream_idx;
        m_audio_stream_idx = other.m_audio_stream_idx;
        other.m_fmt_ctx = nullptr;
        other.m_video_stream_idx = -1;
        other.m_audio_stream_idx = -1;
    }
    return *this;
}

Result<void> FFmpegFormatContext::open(const std::string& path) {
    int ret = avformat_open_input(&m_fmt_ctx, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        if (ret == AVERROR(ENOENT)) {
            return Error::file_not_found(path);
        }
        return ffmpeg_error(ret, "avformat_open_input(" + path + ")");
    }

    ret = avformat_find_stream_info(m_fmt_ctx, nullptr);
    if (ret < 0) {
        return ffmpeg_error(ret, "avformat_find_stream_info");
    }

    return Result<void>();
}

Result<int> FFmpegFormatContext::find_video_stream() {
    assert(m_fmt_ctx && "Format context not opened");

    m_video_stream_idx = av_find_best_stream(m_fmt_ctx, AVMEDIA_TYPE_VIDEO,
                                              -1, -1, nullptr, 0);
    if (m_video_stream_idx < 0) {
        return Error::unsupported("No video stream found");
    }
    return m_video_stream_idx;
}

AVStream* FFmpegFormatContext::video_stream() const {
    assert(m_fmt_ctx && m_video_stream_idx >= 0);
    return m_fmt_ctx->streams[m_video_stream_idx];
}

AVCodecParameters* FFmpegFormatContext::video_codec_params() const {
    return video_stream()->codecpar;
}

int FFmpegFormatContext::find_audio_stream() {
    assert(m_fmt_ctx && "Format context not opened");

    m_audio_stream_idx = av_find_best_stream(m_fmt_ctx, AVMEDIA_TYPE_AUDIO,
                                              -1, -1, nullptr, 0);
    return m_audio_stream_idx;
}

AVStream* FFmpegFormatContext::audio_stream() const {
    if (m_audio_stream_idx < 0) return nullptr;
    return m_fmt_ctx->streams[m_audio_stream_idx];
}

AVCodecParameters* FFmpegFormatContext::audio_codec_params() const {
    AVStream* stream = audio_stream();
    return stream ? stream->codecpar : nullptr;
}

// FFmpegCodecContext implementation

FFmpegCodecContext::~FFmpegCodecContext() {
    if (m_codec_ctx) {
        avcodec_free_context(&m_codec_ctx);
    }
    if (m_hw_device_ctx) {
        av_buffer_unref(&m_hw_device_ctx);
    }
}

FFmpegCodecContext::FFmpegCodecContext(FFmpegCodecContext&& other) noexcept
    : m_codec_ctx(other.m_codec_ctx),
      m_hw_device_ctx(other.m_hw_device_ctx),
      m_hw_pix_fmt(other.m_hw_pix_fmt) {
    other.m_codec_ctx = nullptr;
    other.m_hw_device_ctx = nullptr;
    other.m_hw_pix_fmt = AV_PIX_FMT_NONE;
}

FFmpegCodecContext& FFmpegCodecContext::operator=(FFmpegCodecContext&& other) noexcept {
    if (this != &other) {
        if (m_codec_ctx) {
            avcodec_free_context(&m_codec_ctx);
        }
        if (m_hw_device_ctx) {
            av_buffer_unref(&m_hw_device_ctx);
        }
        m_codec_ctx = other.m_codec_ctx;
        m_hw_device_ctx = other.m_hw_device_ctx;
        m_hw_pix_fmt = other.m_hw_pix_fmt;
        other.m_codec_ctx = nullptr;
        other.m_hw_device_ctx = nullptr;
        other.m_hw_pix_fmt = AV_PIX_FMT_NONE;
    }
    return *this;
}

// Callback to negotiate hw pixel format
static AVPixelFormat get_hw_format(AVCodecContext* ctx, const AVPixelFormat* pix_fmts) {
    AVPixelFormat target_fmt = *static_cast<AVPixelFormat*>(ctx->opaque);

    for (const AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == target_fmt) {
            return *p;
        }
    }

    // Hw format not available, let ffmpeg pick software format
    return pix_fmts[0];
}

Result<void> FFmpegCodecContext::init(AVCodecParameters* params) {
    // 1. Find standard decoder
    const AVCodec* codec = avcodec_find_decoder(params->codec_id);
    if (!codec) {
        return Error::unsupported("No decoder for codec ID " + std::to_string(params->codec_id));
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // 2. Try to set up VideoToolbox hw acceleration
    if (codec_supports_videotoolbox(params->codec_id)) {
        auto hw_result = init_hw_device_ctx(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
        if (hw_result.is_ok()) {
            m_hw_device_ctx = hw_result.value();
            m_hw_pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        }
    }
#endif

    // 3. Allocate codec context
    m_codec_ctx = avcodec_alloc_context3(codec);
    if (!m_codec_ctx) {
        if (m_hw_device_ctx) av_buffer_unref(&m_hw_device_ctx);
        return Error::internal("Failed to allocate codec context");
    }

    int ret = avcodec_parameters_to_context(m_codec_ctx, params);
    if (ret < 0) {
        return ffmpeg_error(ret, "avcodec_parameters_to_context");
    }

    // 4. Configure hw acceleration if available
    if (m_hw_device_ctx) {
        m_codec_ctx->hw_device_ctx = av_buffer_ref(m_hw_device_ctx);
        m_codec_ctx->opaque = &m_hw_pix_fmt;
        m_codec_ctx->get_format = get_hw_format;
    }

    // 5. Open codec
    ret = avcodec_open2(m_codec_ctx, codec, nullptr);
    if (ret < 0) {
        return ffmpeg_error(ret, "avcodec_open2");
    }

    return Result<void>();
}

// FFmpegScaleContext implementation

FFmpegScaleContext::~FFmpegScaleContext() {
    if (m_sws_ctx) {
        sws_freeContext(m_sws_ctx);
    }
}

Result<void> FFmpegScaleContext::init(int src_width, int src_height, AVPixelFormat src_fmt,
                                       int dst_width, int dst_height) {
    m_dst_width = dst_width;
    m_dst_height = dst_height;

    m_sws_ctx = sws_getContext(
        src_width, src_height, src_fmt,
        dst_width, dst_height, AV_PIX_FMT_BGRA,
        SWS_BILINEAR, nullptr, nullptr, nullptr
    );

    if (!m_sws_ctx) {
        return Error::internal("Failed to create swscale context");
    }

    return Result<void>();
}

void FFmpegScaleContext::convert(AVFrame* src, uint8_t* dst_data, int dst_stride) {
    assert(m_sws_ctx && "Scale context not initialized");

    uint8_t* dst_planes[4] = {dst_data, nullptr, nullptr, nullptr};
    int dst_strides[4] = {dst_stride, 0, 0, 0};

    sws_scale(m_sws_ctx, src->data, src->linesize, 0, src->height,
              dst_planes, dst_strides);
}

// Utility functions

Rate av_rational_to_rate(AVRational r) {
    return Rate{r.num, r.den};
}

double stream_time_base_us(AVStream* stream) {
    // time_base is seconds per tick, convert to us per tick
    return (1000000.0 * stream->time_base.num) / stream->time_base.den;
}

int64_t us_to_stream_pts(TimeUS us, AVStream* stream) {
    // us / (us_per_tick) = pts
    AVRational time_base = stream->time_base;
    // pts = us * time_base.den / (time_base.num * 1000000)
    return av_rescale_q(us, {1, 1000000}, time_base);
}

TimeUS stream_pts_to_us(int64_t pts, AVStream* stream) {
    if (pts == AV_NOPTS_VALUE) {
        return 0;
    }
    AVRational time_base = stream->time_base;
    // us = pts * time_base.num * 1000000 / time_base.den
    return av_rescale_q(pts, time_base, {1, 1000000});
}

} // namespace impl
} // namespace emp
