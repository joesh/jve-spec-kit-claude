#pragma once

#include "emp_errors.h"
#include "emp_time.h"
#include <memory>
#include <cstdint>
#include <vector>

namespace emp {

// Sample format (v1: only F32)
enum class SampleFormat {
    F32  // 32-bit float, interleaved
};

// Audio format descriptor
struct AudioFormat {
    SampleFormat fmt;       // F32
    int32_t sample_rate;    // Device rate (typically 48000)
    int32_t channels;       // 2 (stereo) in v1
};

// Forward declaration for implementation
class PcmChunkImpl;

// PCM audio chunk (decoded audio data)
// Immutable, refcounted via shared_ptr
class PcmChunk {
public:
    ~PcmChunk();

    // Sample rate of this chunk
    int32_t sample_rate() const;

    // Number of channels (interleaved)
    int32_t channels() const;

    // Sample format
    SampleFormat format() const;

    // Media time of first sample (microseconds)
    int64_t start_time_us() const;

    // Number of sample-frames (samples per channel)
    int64_t frames() const;

    // Interleaved float32 data
    // Size: frames() * channels() floats
    const float* data_f32() const;

    // Internal: Constructor is public but PcmChunkImpl is opaque
    explicit PcmChunk(std::unique_ptr<PcmChunkImpl> impl);

private:
    std::unique_ptr<PcmChunkImpl> m_impl;
};

} // namespace emp
