#pragma once

// FFmpeg headers - ONLY allowed in impl/ directory
extern "C" {
#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/opt.h>
}

#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_audio.h>
#include <vector>

namespace emp {
namespace impl {

// SwrContext wrapper for audio resampling
// Converts any input format to float32 stereo at target sample rate
class FFmpegResampleContext {
public:
    FFmpegResampleContext() = default;
    ~FFmpegResampleContext();

    // Non-copyable
    FFmpegResampleContext(const FFmpegResampleContext&) = delete;
    FFmpegResampleContext& operator=(const FFmpegResampleContext&) = delete;

    // Move semantics
    FFmpegResampleContext(FFmpegResampleContext&& other) noexcept;
    FFmpegResampleContext& operator=(FFmpegResampleContext&& other) noexcept;

    // Initialize for conversion from source format to output format
    // Output is always float32 interleaved stereo
    Result<void> init(int src_sample_rate, const AVChannelLayout* src_ch_layout,
                      AVSampleFormat src_sample_fmt, int dst_sample_rate);

    // Resample audio data
    // Returns number of output samples per channel
    // Output buffer must be large enough for worst-case expansion
    int64_t convert(const uint8_t* const* src_data, int src_samples,
                    float* dst_data, int64_t dst_max_samples);

    // Flush any remaining samples in the resampler
    int64_t flush(float* dst_data, int64_t dst_max_samples);

    // Reset internal state (call after discontinuous seeks)
    // Clears internal FIFO buffers without changing configuration
    void reset();

    // Calculate output sample count for given input
    int64_t get_out_samples(int in_samples) const;

    SwrContext* get() const { return m_swr_ctx; }

private:
    SwrContext* m_swr_ctx = nullptr;
    int m_dst_sample_rate = 0;
    int m_dst_channels = 2;  // Always stereo output
};

} // namespace impl
} // namespace emp
