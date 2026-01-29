#include "aop.h"

#include <QAudioFormat>
#include <QAudioSink>
#include <QMediaDevices>
#include <QIODevice>
#include <QMutex>
#include <QMutexLocker>

#include <vector>
#include <atomic>
#include <cassert>
#include <cstring>

namespace aop {

// Ring buffer for audio data
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity_frames, int channels)
        : m_channels(channels)
        , m_capacity(capacity_frames * static_cast<size_t>(channels))
        , m_buffer(m_capacity)
        , m_read_pos(0)
        , m_write_pos(0)
        , m_count(0) {
    }

    // Write frames to buffer, returns frames written
    int64_t write(const float* data, int64_t frames) {
        QMutexLocker lock(&m_mutex);

        size_t samples = static_cast<size_t>(frames) * static_cast<size_t>(m_channels);
        size_t available = m_capacity - m_count;
        size_t to_write = std::min(samples, available);

        if (to_write == 0) return 0;

        // Write in two parts if wrapping
        size_t first_part = std::min(to_write, m_capacity - m_write_pos);
        std::memcpy(m_buffer.data() + m_write_pos, data, first_part * sizeof(float));

        size_t second_part = to_write - first_part;
        if (second_part > 0) {
            std::memcpy(m_buffer.data(), data + first_part, second_part * sizeof(float));
        }

        m_write_pos = (m_write_pos + to_write) % m_capacity;
        m_count += to_write;

        return static_cast<int64_t>(to_write / static_cast<size_t>(m_channels));
    }

    // Read frames from buffer, returns frames read
    int64_t read(float* data, int64_t frames) {
        QMutexLocker lock(&m_mutex);

        size_t samples = static_cast<size_t>(frames) * static_cast<size_t>(m_channels);
        size_t to_read = std::min(samples, m_count);

        if (to_read == 0) {
            // Underrun - fill with silence
            std::memset(data, 0, samples * sizeof(float));
            return 0;
        }

        // Read in two parts if wrapping
        size_t first_part = std::min(to_read, m_capacity - m_read_pos);
        std::memcpy(data, m_buffer.data() + m_read_pos, first_part * sizeof(float));

        size_t second_part = to_read - first_part;
        if (second_part > 0) {
            std::memcpy(data + first_part, m_buffer.data(), second_part * sizeof(float));
        }

        m_read_pos = (m_read_pos + to_read) % m_capacity;
        m_count -= to_read;

        // If we read less than requested, fill rest with silence
        if (to_read < samples) {
            std::memset(data + to_read, 0, (samples - to_read) * sizeof(float));
        }

        return static_cast<int64_t>(to_read / static_cast<size_t>(m_channels));
    }

    int64_t available_frames() const {
        QMutexLocker lock(&m_mutex);
        return static_cast<int64_t>(m_count / static_cast<size_t>(m_channels));
    }

    void clear() {
        QMutexLocker lock(&m_mutex);
        m_read_pos = 0;
        m_write_pos = 0;
        m_count = 0;
    }

private:
    int m_channels;
    size_t m_capacity;
    std::vector<float> m_buffer;
    size_t m_read_pos;
    size_t m_write_pos;
    size_t m_count;
    mutable QMutex m_mutex;
};

// QIODevice adapter for QAudioSink to read from ring buffer
class AudioIODevice : public QIODevice {
public:
    AudioIODevice(RingBuffer* buffer, int sample_rate, int channels, QObject* parent = nullptr)
        : QIODevice(parent)
        , m_buffer(buffer)
        , m_sample_rate(sample_rate)
        , m_channels(channels)
        , m_frames_read(0)
        , m_had_underrun(false) {
    }

    bool open(OpenMode mode) override {
        if (mode != ReadOnly) return false;
        return QIODevice::open(mode);
    }

    qint64 readData(char* data, qint64 maxlen) override {
        // Convert bytes to frames (float32 stereo = 8 bytes per frame)
        int64_t bytes_per_frame = static_cast<int64_t>(m_channels) * sizeof(float);
        int64_t frames = maxlen / bytes_per_frame;

        int64_t frames_read = m_buffer->read(reinterpret_cast<float*>(data), frames);

        if (frames_read < frames) {
            m_had_underrun.store(true, std::memory_order_relaxed);
        }

        m_frames_read.fetch_add(frames_read, std::memory_order_relaxed);

        return frames * bytes_per_frame;  // Always return requested amount (silence-padded)
    }

    qint64 writeData(const char*, qint64) override {
        return -1;  // Not writable
    }

    qint64 bytesAvailable() const override {
        return m_buffer->available_frames() * m_channels * sizeof(float);
    }

    int64_t playhead_us() const {
        int64_t frames = m_frames_read.load(std::memory_order_relaxed);
        return (frames * 1000000LL) / m_sample_rate;
    }

    bool had_underrun() const {
        return m_had_underrun.load(std::memory_order_relaxed);
    }

    void clear_underrun() {
        m_had_underrun.store(false, std::memory_order_relaxed);
    }

    void reset_playhead() {
        m_frames_read.store(0, std::memory_order_relaxed);
    }

private:
    RingBuffer* m_buffer;
    int m_sample_rate;
    int m_channels;
    std::atomic<int64_t> m_frames_read;
    std::atomic<bool> m_had_underrun;
};

// Implementation class
class AudioOutputImpl {
public:
    AudioOutputImpl(int sample_rate, int channels, int buffer_frames)
        : m_sample_rate(sample_rate)
        , m_channels(channels)
        , m_ring_buffer(static_cast<size_t>(buffer_frames), channels)
        , m_io_device(&m_ring_buffer, sample_rate, channels)
        , m_playing(false) {
    }

    ~AudioOutputImpl() {
        if (m_sink) {
            m_sink->stop();
        }
    }

    bool init(AopOpenReport* out_report) {
        // Set up audio format
        QAudioFormat format;
        format.setSampleRate(m_sample_rate);
        format.setChannelCount(m_channels);
        format.setSampleFormat(QAudioFormat::Float);

        // Get default output device
        QAudioDevice device = QMediaDevices::defaultAudioOutput();
        if (device.isNull()) {
            if (out_report) out_report->device_name = "No audio device";
            return false;
        }

        // Check format support
        if (!device.isFormatSupported(format)) {
            // Try to find supported format
            QAudioFormat nearestFormat = device.preferredFormat();
            nearestFormat.setSampleFormat(QAudioFormat::Float);
            if (!device.isFormatSupported(nearestFormat)) {
                if (out_report) out_report->device_name = "Format not supported";
                return false;
            }
            format = nearestFormat;
            m_sample_rate = format.sampleRate();
            m_channels = format.channelCount();
        }

        m_sink = std::make_unique<QAudioSink>(device, format);

        if (out_report) {
            out_report->actual_sample_rate = m_sample_rate;
            out_report->actual_channels = m_channels;
            out_report->actual_buffer_ms = static_cast<int32_t>(
                (m_ring_buffer.available_frames() * 1000) / m_sample_rate
            );
            out_report->device_name = device.description().toStdString();
        }

        return true;
    }

    void start() {
        if (!m_sink || m_playing) return;
        m_io_device.open(QIODevice::ReadOnly);
        m_sink->start(&m_io_device);
        m_playing = true;
    }

    void stop() {
        if (!m_sink || !m_playing) return;
        m_sink->stop();
        m_io_device.close();
        m_playing = false;
    }

    bool is_playing() const {
        return m_playing;
    }

    void flush() {
        m_ring_buffer.clear();
        m_io_device.reset_playhead();
    }

    int64_t write_f32(const float* data, int64_t frames) {
        return m_ring_buffer.write(data, frames);
    }

    int64_t buffered_frames() const {
        return m_ring_buffer.available_frames();
    }

    int64_t playhead_us() const {
        return m_io_device.playhead_us();
    }

    int64_t latency_frames() const {
        // Ring buffer frames + estimated device buffer
        int64_t device_latency_us = m_sink ? m_sink->elapsedUSecs() : 0;
        int64_t device_frames = (device_latency_us * m_sample_rate) / 1000000;
        return m_ring_buffer.available_frames() + device_frames;
    }

    bool had_underrun() const {
        return m_io_device.had_underrun();
    }

    void clear_underrun() {
        m_io_device.clear_underrun();
    }

    int sample_rate() const { return m_sample_rate; }
    int channels() const { return m_channels; }

private:
    int m_sample_rate;
    int m_channels;
    RingBuffer m_ring_buffer;
    AudioIODevice m_io_device;
    std::unique_ptr<QAudioSink> m_sink;
    bool m_playing;
};

// AudioOutput implementation

AudioOutput::AudioOutput(std::unique_ptr<AudioOutputImpl> impl)
    : m_impl(std::move(impl)) {
    assert(m_impl && "AudioOutput impl cannot be null");
}

AudioOutput::~AudioOutput() {
    Close();
}

std::unique_ptr<AudioOutput> AudioOutput::Open(const AopConfig& config, AopOpenReport* out_report) {
    int sample_rate = config.sample_rate > 0 ? config.sample_rate : 48000;
    int channels = config.channels > 0 ? config.channels : 2;
    int buffer_ms = config.target_buffer_ms > 0 ? config.target_buffer_ms : 100;

    // Calculate buffer size in frames
    int buffer_frames = (sample_rate * buffer_ms) / 1000;

    auto impl = std::make_unique<AudioOutputImpl>(sample_rate, channels, buffer_frames);

    if (!impl->init(out_report)) {
        return nullptr;
    }

    return std::unique_ptr<AudioOutput>(new AudioOutput(std::move(impl)));
}

void AudioOutput::Close() {
    if (m_impl) {
        m_impl->stop();
    }
}

int64_t AudioOutput::WriteF32(const float* interleaved, int64_t frames) {
    return m_impl->write_f32(interleaved, frames);
}

int64_t AudioOutput::BufferedFrames() const {
    return m_impl->buffered_frames();
}

int64_t AudioOutput::PlayheadTimeUS() const {
    return m_impl->playhead_us();
}

int64_t AudioOutput::LatencyFrames() const {
    return m_impl->latency_frames();
}

bool AudioOutput::HadUnderrun() const {
    return m_impl->had_underrun();
}

void AudioOutput::ClearUnderrunFlag() {
    m_impl->clear_underrun();
}

void AudioOutput::Start() {
    m_impl->start();
}

void AudioOutput::Stop() {
    m_impl->stop();
}

bool AudioOutput::IsPlaying() const {
    return m_impl->is_playing();
}

void AudioOutput::Flush() {
    m_impl->flush();
}

int32_t AudioOutput::SampleRate() const {
    return m_impl->sample_rate();
}

int32_t AudioOutput::Channels() const {
    return m_impl->channels();
}

} // namespace aop
