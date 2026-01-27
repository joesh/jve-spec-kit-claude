#pragma once

#include <editor_media_platform/emp_audio.h>
#include <vector>

namespace emp {

// Internal implementation of PcmChunk
class PcmChunkImpl {
public:
    PcmChunkImpl(int32_t sample_rate, int32_t channels, SampleFormat format,
                 int64_t start_time_us, std::vector<float> data);

    int32_t sample_rate;
    int32_t channels;
    SampleFormat format;
    int64_t start_time_us;
    std::vector<float> data;  // Interleaved float32
};

} // namespace emp
