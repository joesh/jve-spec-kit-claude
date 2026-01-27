#include <editor_media_platform/emp_audio.h>
#include "impl/pcm_chunk_impl.h"
#include <cassert>

namespace emp {

// PcmChunkImpl implementation
PcmChunkImpl::PcmChunkImpl(int32_t sample_rate_, int32_t channels_, SampleFormat format_,
                           int64_t start_time_us_, std::vector<float> data_)
    : sample_rate(sample_rate_)
    , channels(channels_)
    , format(format_)
    , start_time_us(start_time_us_)
    , data(std::move(data_)) {
}

// PcmChunk implementation
PcmChunk::PcmChunk(std::unique_ptr<PcmChunkImpl> impl)
    : m_impl(std::move(impl)) {
    assert(m_impl && "PcmChunk impl cannot be null");
}

PcmChunk::~PcmChunk() = default;

int32_t PcmChunk::sample_rate() const {
    return m_impl->sample_rate;
}

int32_t PcmChunk::channels() const {
    return m_impl->channels;
}

SampleFormat PcmChunk::format() const {
    return m_impl->format;
}

int64_t PcmChunk::start_time_us() const {
    return m_impl->start_time_us;
}

int64_t PcmChunk::frames() const {
    if (m_impl->channels == 0) return 0;
    return static_cast<int64_t>(m_impl->data.size()) / m_impl->channels;
}

const float* PcmChunk::data_f32() const {
    return m_impl->data.data();
}

} // namespace emp
