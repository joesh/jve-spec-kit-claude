#pragma once

// FFmpeg headers - ONLY allowed in impl/ directory
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/display.h>
#include <libswscale/swscale.h>
}

#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>
#include <string>

namespace emp {
namespace impl {

// Convert FFmpeg error code to EMP Error
Error ffmpeg_error(int errnum, const std::string& context);

// FFmpeg format context wrapper (for Asset)
class FFmpegFormatContext {
public:
    FFmpegFormatContext() = default;
    ~FFmpegFormatContext();

    // Non-copyable
    FFmpegFormatContext(const FFmpegFormatContext&) = delete;
    FFmpegFormatContext& operator=(const FFmpegFormatContext&) = delete;

    // Move semantics
    FFmpegFormatContext(FFmpegFormatContext&& other) noexcept;
    FFmpegFormatContext& operator=(FFmpegFormatContext&& other) noexcept;

    // Open a file
    Result<void> open(const std::string& path);

    // Find video stream
    Result<int> find_video_stream();

    // Find audio stream (returns -1 if no audio, does not error)
    int find_audio_stream();

    AVFormatContext* get() const { return m_fmt_ctx; }
    int video_stream_index() const { return m_video_stream_idx; }
    int audio_stream_index() const { return m_audio_stream_idx; }
    AVStream* video_stream() const;
    AVStream* audio_stream() const;
    AVCodecParameters* video_codec_params() const;
    AVCodecParameters* audio_codec_params() const;

private:
    AVFormatContext* m_fmt_ctx = nullptr;
    int m_video_stream_idx = -1;
    int m_audio_stream_idx = -1;
};

// FFmpeg codec context wrapper (for Reader)
// Supports hardware-accelerated decoding when available
class FFmpegCodecContext {
public:
    FFmpegCodecContext() = default;
    ~FFmpegCodecContext();

    // Non-copyable
    FFmpegCodecContext(const FFmpegCodecContext&) = delete;
    FFmpegCodecContext& operator=(const FFmpegCodecContext&) = delete;

    // Move semantics
    FFmpegCodecContext(FFmpegCodecContext&& other) noexcept;
    FFmpegCodecContext& operator=(FFmpegCodecContext&& other) noexcept;

    // Initialize from codec parameters
    // Automatically tries hardware decoder first, falls back to software
    Result<void> init(AVCodecParameters* params);

    AVCodecContext* get() const { return m_codec_ctx; }

    // True if using hardware-accelerated decoder
    bool is_hw_accelerated() const { return m_hw_device_ctx != nullptr; }

    // Hardware pixel format (AV_PIX_FMT_NONE if software decode)
    AVPixelFormat hw_pix_fmt() const { return m_hw_pix_fmt; }

private:
    AVCodecContext* m_codec_ctx = nullptr;
    AVBufferRef* m_hw_device_ctx = nullptr;
    AVPixelFormat m_hw_pix_fmt = AV_PIX_FMT_NONE;
};

// SwScale context wrapper (for format conversion)
class FFmpegScaleContext {
public:
    FFmpegScaleContext() = default;
    ~FFmpegScaleContext();

    // Non-copyable
    FFmpegScaleContext(const FFmpegScaleContext&) = delete;
    FFmpegScaleContext& operator=(const FFmpegScaleContext&) = delete;

    // Initialize for BGRA32 output
    Result<void> init(int src_width, int src_height, AVPixelFormat src_fmt,
                      int dst_width, int dst_height);

    // Convert frame to BGRA32
    void convert(AVFrame* src, uint8_t* dst_data, int dst_stride);

    SwsContext* get() const { return m_sws_ctx; }

private:
    SwsContext* m_sws_ctx = nullptr;
    int m_dst_width = 0;
    int m_dst_height = 0;
};

// Convert AVRational to our Rate
Rate av_rational_to_rate(AVRational r);

// Get time base of stream in microseconds per tick
double stream_time_base_us(AVStream* stream);

// Convert microseconds to stream time base
int64_t us_to_stream_pts(TimeUS us, AVStream* stream);

// Convert stream PTS to microseconds
TimeUS stream_pts_to_us(int64_t pts, AVStream* stream);

} // namespace impl
} // namespace emp
