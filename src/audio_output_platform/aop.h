#pragma once

#include <memory>
#include <cstdint>
#include <string>

namespace aop {

// Configuration for audio output
struct AopConfig {
    int32_t sample_rate;       // Requested sample rate (default 48000)
    int32_t channels;          // Channel count (default 2, stereo)
    int32_t target_buffer_ms;  // Target buffer size in ms (default 100)
};

// Report from device open
struct AopOpenReport {
    int32_t actual_sample_rate;
    int32_t actual_channels;
    int32_t actual_buffer_ms;
    std::string device_name;
};

// Forward declaration for implementation
class AudioOutputImpl;

// Audio output device wrapper
// Thread-safe for WriteF32 from any thread
class AudioOutput {
public:
    ~AudioOutput();

    // Open the default audio output device
    // Returns nullptr on failure (check out_report for details)
    static std::unique_ptr<AudioOutput> Open(const AopConfig& config, AopOpenReport* out_report);

    // Close the audio output (called automatically by destructor)
    void Close();

    // Write PCM into ring buffer
    // Returns number of frames actually written (may be less than requested if buffer full)
    int64_t WriteF32(const float* interleaved, int64_t frames);

    // How many frames are currently buffered (approximate)
    int64_t BufferedFrames() const;

    // Device playhead in microseconds since Start() was called
    // This is the audio-master clock for sync
    int64_t PlayheadTimeUS() const;

    // Latency estimate (buffer + device) in frames
    int64_t LatencyFrames() const;

    // Check if device had underrun since last clear
    bool HadUnderrun() const;
    void ClearUnderrunFlag();

    // Start/stop playback
    void Start();
    void Stop();
    bool IsPlaying() const;

    // Flush buffer (for seeking)
    void Flush();

    // Internal constructor (public but impl is opaque)
    explicit AudioOutput(std::unique_ptr<AudioOutputImpl> impl);

private:
    std::unique_ptr<AudioOutputImpl> m_impl;
};

} // namespace aop
