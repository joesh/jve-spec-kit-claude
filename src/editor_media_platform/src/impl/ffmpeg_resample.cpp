#include "ffmpeg_resample.h"
#include "ffmpeg_context.h"
#include <cassert>

namespace emp {
namespace impl {

FFmpegResampleContext::~FFmpegResampleContext() {
    if (m_swr_ctx) {
        swr_free(&m_swr_ctx);
    }
}

FFmpegResampleContext::FFmpegResampleContext(FFmpegResampleContext&& other) noexcept
    : m_swr_ctx(other.m_swr_ctx),
      m_dst_sample_rate(other.m_dst_sample_rate),
      m_dst_channels(other.m_dst_channels) {
    other.m_swr_ctx = nullptr;
    other.m_dst_sample_rate = 0;
}

FFmpegResampleContext& FFmpegResampleContext::operator=(FFmpegResampleContext&& other) noexcept {
    if (this != &other) {
        if (m_swr_ctx) {
            swr_free(&m_swr_ctx);
        }
        m_swr_ctx = other.m_swr_ctx;
        m_dst_sample_rate = other.m_dst_sample_rate;
        m_dst_channels = other.m_dst_channels;
        other.m_swr_ctx = nullptr;
        other.m_dst_sample_rate = 0;
    }
    return *this;
}

Result<void> FFmpegResampleContext::init(int src_sample_rate, const AVChannelLayout* src_ch_layout,
                                          AVSampleFormat src_sample_fmt, int dst_sample_rate) {
    m_dst_sample_rate = dst_sample_rate;
    m_dst_channels = 2;  // Always stereo

    // Static stereo layout to avoid address-of-temporary
    static AVChannelLayout stereo_layout = AV_CHANNEL_LAYOUT_STEREO;

    int ret = swr_alloc_set_opts2(&m_swr_ctx,
        &stereo_layout,                               // Output: stereo
        AV_SAMPLE_FMT_FLT,                            // Output: float32
        dst_sample_rate,
        src_ch_layout,
        src_sample_fmt,
        src_sample_rate,
        0, nullptr);

    if (ret < 0) {
        return ffmpeg_error(ret, "swr_alloc_set_opts2");
    }

    ret = swr_init(m_swr_ctx);
    if (ret < 0) {
        swr_free(&m_swr_ctx);
        return ffmpeg_error(ret, "swr_init");
    }

    return Result<void>();
}

int64_t FFmpegResampleContext::convert(const uint8_t* const* src_data, int src_samples,
                                        float* dst_data, int64_t dst_max_samples) {
    assert(m_swr_ctx && "Resample context not initialized");

    uint8_t* dst_planes[1] = { reinterpret_cast<uint8_t*>(dst_data) };

    int ret = swr_convert(m_swr_ctx, dst_planes, static_cast<int>(dst_max_samples),
                          src_data, src_samples);

    if (ret < 0) {
        return 0;  // Conversion error
    }
    return ret;
}

int64_t FFmpegResampleContext::flush(float* dst_data, int64_t dst_max_samples) {
    assert(m_swr_ctx && "Resample context not initialized");

    uint8_t* dst_planes[1] = { reinterpret_cast<uint8_t*>(dst_data) };

    int ret = swr_convert(m_swr_ctx, dst_planes, static_cast<int>(dst_max_samples),
                          nullptr, 0);

    if (ret < 0) {
        return 0;
    }
    return ret;
}

void FFmpegResampleContext::reset() {
    if (!m_swr_ctx) {
        return;
    }
    // Close and re-init to clear internal FIFO buffers
    // This is the recommended way to reset SwrContext state
    swr_close(m_swr_ctx);
    swr_init(m_swr_ctx);
}

int64_t FFmpegResampleContext::get_out_samples(int in_samples) const {
    assert(m_swr_ctx && "Resample context not initialized");
    return swr_get_out_samples(m_swr_ctx, in_samples);
}

} // namespace impl
} // namespace emp
