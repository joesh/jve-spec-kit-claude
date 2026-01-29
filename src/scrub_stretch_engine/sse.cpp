#include "sse.h"

#include <vector>
#include <cmath>
#include <cassert>
#include <algorithm>
#include <cstring>
#include <deque>

namespace sse {

// Constants
static constexpr int ANALYSIS_WINDOW_MS = 20;  // 20ms analysis window
static constexpr int OVERLAP_PERCENT = 75;     // 75% overlap
static constexpr float PI = 3.14159265358979f;

// Circular buffer for source PCM with time tracking
class SourceBuffer {
public:
    struct Chunk {
        std::vector<float> data;  // Interleaved
        int64_t start_time_us;
        int64_t frames;
    };

    SourceBuffer(int channels) : m_channels(channels), m_total_frames(0) {}

    void push(const float* data, int64_t frames, int64_t start_time_us, int sample_rate) {
        // Calculate new chunk's time range
        int64_t new_end_us = start_time_us + (frames * 1000000LL) / sample_rate;

        // Remove any existing chunks that overlap with the new chunk's time range
        // This prevents echo from duplicate/overlapping PCM data after seeks
        auto it = m_chunks.begin();
        while (it != m_chunks.end()) {
            int64_t chunk_end_us = it->start_time_us + (it->frames * 1000000LL) / sample_rate;

            // Check for overlap: ranges overlap if start1 < end2 AND start2 < end1
            bool overlaps = (it->start_time_us < new_end_us) && (start_time_us < chunk_end_us);

            if (overlaps) {
                m_total_frames -= it->frames;
                it = m_chunks.erase(it);
            } else {
                ++it;
            }
        }

        // Add the new chunk
        Chunk chunk;
        chunk.data.assign(data, data + frames * m_channels);
        chunk.start_time_us = start_time_us;
        chunk.frames = frames;
        m_chunks.push_back(std::move(chunk));
        m_total_frames += frames;
    }

    void clear() {
        m_chunks.clear();
        m_total_frames = 0;
    }

    // Get samples at a specific media time
    // Returns false if time is not in buffer
    bool get_samples(int64_t time_us, int sample_rate, float* out, int64_t frames) const {
        if (m_chunks.empty()) return false;

        // Find chunk containing start time
        for (const auto& chunk : m_chunks) {
            int64_t chunk_duration_us = (chunk.frames * 1000000LL) / sample_rate;
            int64_t chunk_end_us = chunk.start_time_us + chunk_duration_us;

            if (time_us >= chunk.start_time_us && time_us < chunk_end_us) {
                // Calculate offset into chunk
                int64_t offset_us = time_us - chunk.start_time_us;
                int64_t offset_samples = (offset_us * sample_rate) / 1000000LL;

                if (offset_samples + frames <= chunk.frames) {
                    std::memcpy(out, chunk.data.data() + offset_samples * m_channels,
                                frames * m_channels * sizeof(float));
                    return true;
                }
            }
        }
        return false;
    }

    // Get time range covered by buffer
    bool get_time_range(int64_t* min_us, int64_t* max_us, int sample_rate) const {
        if (m_chunks.empty()) return false;
        *min_us = m_chunks.front().start_time_us;
        const auto& last = m_chunks.back();
        *max_us = last.start_time_us + (last.frames * 1000000LL) / sample_rate;
        return true;
    }

    // Trim old chunks (before keep_after_us) to keep buffer size reasonable
    void trim(int64_t keep_after_us, int sample_rate) {
        while (!m_chunks.empty()) {
            const auto& chunk = m_chunks.front();
            int64_t chunk_end_us = chunk.start_time_us + (chunk.frames * 1000000LL) / sample_rate;
            if (chunk_end_us < keep_after_us) {
                m_total_frames -= chunk.frames;
                m_chunks.pop_front();
            } else {
                break;
            }
        }
    }

    // Trim chunks after keep_before_us (for reverse playback)
    void trim_after(int64_t keep_before_us, int sample_rate) {
        while (!m_chunks.empty()) {
            const auto& chunk = m_chunks.back();
            // If chunk starts after the threshold, remove it
            if (chunk.start_time_us > keep_before_us) {
                m_total_frames -= chunk.frames;
                m_chunks.pop_back();
            } else {
                break;
            }
        }
    }

    int64_t total_frames() const { return m_total_frames; }
    bool empty() const { return m_chunks.empty(); }

private:
    int m_channels;
    std::deque<Chunk> m_chunks;
    int64_t m_total_frames;
};

// WSOLA implementation
class ScrubStretchEngineImpl {
public:
    ScrubStretchEngineImpl(const SseConfig& config)
        : m_config(config)
        , m_source_buffer(config.channels)
        , m_current_time_us(0)
        , m_speed(1.0f)
        , m_quality(QualityMode::Q1)
        , m_starved(false)
        , m_last_direction(0)
        , m_xfade_remaining(0) {

        // Calculate window sizes
        m_analysis_frames = (config.sample_rate * ANALYSIS_WINDOW_MS) / 1000;
        m_hop_frames = m_analysis_frames * (100 - OVERLAP_PERCENT) / 100;

        // Allocate buffers
        m_analysis_buffer.resize(static_cast<size_t>(m_analysis_frames * config.channels));
        m_synthesis_buffer.resize(static_cast<size_t>(m_analysis_frames * config.channels));
        m_output_buffer.resize(static_cast<size_t>(m_analysis_frames * config.channels));
        m_xfade_buffer.resize(static_cast<size_t>(m_analysis_frames * config.channels));
        m_window.resize(static_cast<size_t>(m_analysis_frames));

        // Hann window
        for (int i = 0; i < m_analysis_frames; i++) {
            m_window[i] = 0.5f * (1.0f - std::cos(2.0f * PI * i / (m_analysis_frames - 1)));
        }

        // Calculate crossfade frames
        m_xfade_frames = (config.xfade_ms * config.sample_rate) / 1000;

        // Search range for correlation
        m_search_frames = m_hop_frames / 2;
    }

    void reset() {
        m_source_buffer.clear();
        m_current_time_us = 0;
        m_starved = false;
        m_last_direction = 0;
        m_xfade_remaining = 0;
        std::fill(m_output_buffer.begin(), m_output_buffer.end(), 0.0f);
    }

    void set_target(int64_t t_us, float speed, QualityMode mode) {
        // Detect direction change
        int new_direction = (speed >= 0) ? 1 : -1;
        if (m_last_direction != 0 && new_direction != m_last_direction) {
            // Direction flip - clear synthesis state to prevent stale window artifacts
            // The synthesis buffer holds residual from the previous window (chronologically
            // "later" in media time for reverse), which would bleed via overlap-add.
            std::fill(m_synthesis_buffer.begin(), m_synthesis_buffer.end(), 0.0f);

            // Initiate crossfade to smooth the transition
            m_xfade_remaining = m_xfade_frames;
            std::copy(m_output_buffer.begin(), m_output_buffer.end(), m_xfade_buffer.begin());
        }
        m_last_direction = new_direction;

        // ALWAYS set time - SetTarget is now only called on transport events
        // (start, seek, speed change), not during steady-state playback.
        // The old "m_needs_time_init" hack was needed when video called SetTarget
        // every frame, but audio_playback now handles time tracking via AOP playhead.
        m_current_time_us = t_us;

        m_speed = speed;
        m_quality = mode;

        // Clamp speed to valid range based on quality mode
        float abs_speed = std::abs(m_speed);
        if (mode == QualityMode::Q3_DECIMATE) {
            // Decimate mode: allow up to MAX_SPEED_DECIMATE (16x)
            // Assert invariants for decimate mode
            assert(abs_speed > MAX_SPEED_STRETCHED &&
                "Q3_DECIMATE should only be used for speeds > MAX_SPEED_STRETCHED (4x)");
            if (abs_speed > MAX_SPEED_DECIMATE) {
                m_speed = (m_speed >= 0) ? MAX_SPEED_DECIMATE : -MAX_SPEED_DECIMATE;
            }
        } else {
            // Q1/Q2: clamp to stretched range
            float min_speed = (mode == QualityMode::Q1) ? m_config.min_speed_q1 : m_config.min_speed_q2;
            if (abs_speed < min_speed) {
                m_speed = (m_speed >= 0) ? min_speed : -min_speed;
            }
            if (abs_speed > MAX_SPEED_STRETCHED) {
                m_speed = (m_speed >= 0) ? MAX_SPEED_STRETCHED : -MAX_SPEED_STRETCHED;
            }
        }
    }

    void push_source(const float* data, int64_t frames, int64_t start_time_us) {
        m_source_buffer.push(data, frames, start_time_us, m_config.sample_rate);

        // Trim data far outside playhead to prevent unbounded memory growth.
        // Keep 10 seconds in both directions to match Lua's audio cache window.
        // This allows reverse playback without constant re-pushing.
        int64_t keep_margin_us = 10000000;  // 10 seconds (matches Lua AUDIO_CACHE_HALF_WINDOW_US)
        if (m_speed >= 0) {
            // Forward: trim data far behind us (low times)
            int64_t min_keep = m_current_time_us - keep_margin_us;
            if (min_keep > 0) {
                m_source_buffer.trim(min_keep, m_config.sample_rate);
            }
        } else {
            // Reverse: trim data far ahead of us (high times)
            int64_t max_keep = m_current_time_us + keep_margin_us;
            m_source_buffer.trim_after(max_keep, m_config.sample_rate);
        }
    }

    int64_t render(float* out, int64_t out_frames) {
        if (std::abs(m_speed) < 0.001f) {
            // Essentially paused - output silence
            std::memset(out, 0, out_frames * m_config.channels * sizeof(float));
            return out_frames;
        }

        // Dispatch to decimate mode for Q3_DECIMATE (>4x speeds)
        if (m_quality == QualityMode::Q3_DECIMATE) {
            return render_decimate(out, out_frames);
        }

        // Standard WSOLA path for Q1/Q2
        int64_t frames_produced = 0;

        while (frames_produced < out_frames) {
            int64_t frames_needed = std::min(out_frames - frames_produced,
                                             static_cast<int64_t>(m_hop_frames));

            // Calculate fetch position - for reverse, we need to look back in time
            // to get the samples we'll reverse and output
            int64_t fetch_time_us = m_current_time_us;
            if (m_speed < 0) {
                // For reverse: fetch from (current - window_duration) so after reversing,
                // the first sample corresponds to current_time
                int64_t window_duration_us = (m_analysis_frames * 1000000LL) / m_config.sample_rate;
                fetch_time_us = m_current_time_us - window_duration_us;
            }

            // Try to get source samples
            bool have_source = m_source_buffer.get_samples(
                fetch_time_us, m_config.sample_rate,
                m_analysis_buffer.data(), m_analysis_frames
            );

            if (!have_source) {
                // Starved - output silence for remaining
                m_starved = true;
                std::memset(out + frames_produced * m_config.channels, 0,
                            (out_frames - frames_produced) * m_config.channels * sizeof(float));
                return out_frames;
            }

            // For reverse playback, reverse the samples so they play backwards
            if (m_speed < 0) {
                reverse_interleaved(m_analysis_buffer.data(), m_analysis_frames);
            }

            // WSOLA synthesis
            process_wsola_frame(frames_needed);

            // Copy to output with crossfade if needed
            for (int64_t i = 0; i < frames_needed; i++) {
                int64_t idx = (frames_produced + i) * m_config.channels;
                int64_t buf_idx = i * m_config.channels;

                for (int ch = 0; ch < m_config.channels; ch++) {
                    float sample = m_output_buffer[buf_idx + ch];

                    // Apply crossfade if transitioning
                    if (m_xfade_remaining > 0) {
                        float xfade_pos = static_cast<float>(m_xfade_remaining) / m_xfade_frames;
                        float old_sample = m_xfade_buffer[buf_idx + ch];
                        sample = sample * (1.0f - xfade_pos) + old_sample * xfade_pos;
                        m_xfade_remaining--;
                    }

                    out[idx + ch] = sample;
                }
            }

            frames_produced += frames_needed;

            // Advance time based on speed
            int64_t time_advance_us = (frames_needed * 1000000LL) / m_config.sample_rate;
            time_advance_us = static_cast<int64_t>(time_advance_us * m_speed);
            m_current_time_us += time_advance_us;
        }

        return frames_produced;
    }

    // Decimate mode rendering: no pitch correction, just sample skipping
    // Used for >4x speeds where WSOLA quality degrades
    int64_t render_decimate(float* out, int64_t out_frames) {
        float abs_speed = std::abs(m_speed);

        // Debug asserts for decimate mode invariants
        assert(abs_speed > MAX_SPEED_STRETCHED &&
            "render_decimate: abs(speed) must be > MAX_SPEED_STRETCHED (4x)");
        assert(abs_speed <= MAX_SPEED_DECIMATE &&
            "render_decimate: abs(speed) must be <= MAX_SPEED_DECIMATE (16x)");

        int64_t frames_produced = 0;

        while (frames_produced < out_frames) {
            // For decimate mode, we sample at intervals based on speed
            // At 8x, we take every 8th sample; at 16x, every 16th sample

            // Try to get source sample at current time
            // We only need 1 frame, but get_samples requires m_analysis_frames
            bool have_source = m_source_buffer.get_samples(
                m_current_time_us, m_config.sample_rate,
                m_analysis_buffer.data(), m_analysis_frames
            );

            if (!have_source) {
                // Starved - output silence for remaining
                m_starved = true;
                std::memset(out + frames_produced * m_config.channels, 0,
                            (out_frames - frames_produced) * m_config.channels * sizeof(float));
                return out_frames;
            }

            // Copy first frame from analysis buffer to output
            for (int ch = 0; ch < m_config.channels; ch++) {
                out[frames_produced * m_config.channels + ch] = m_analysis_buffer[ch];
            }

            frames_produced++;

            // Advance time based on speed (skip ahead proportionally)
            // Each output frame advances the source by speed frames
            int64_t time_advance_us = (1 * 1000000LL) / m_config.sample_rate;
            time_advance_us = static_cast<int64_t>(time_advance_us * m_speed);
            m_current_time_us += time_advance_us;
        }

        return frames_produced;
    }

    bool starved() const { return m_starved; }
    void clear_starved() { m_starved = false; }
    int64_t current_time_us() const { return m_current_time_us; }

private:
    // Reverse interleaved audio samples in-place
    void reverse_interleaved(float* data, int64_t frames) {
        int channels = m_config.channels;
        for (int64_t i = 0; i < frames / 2; i++) {
            int64_t j = frames - 1 - i;
            for (int ch = 0; ch < channels; ch++) {
                std::swap(data[i * channels + ch], data[j * channels + ch]);
            }
        }
    }

    void process_wsola_frame(int64_t hop_out_frames) {
        float abs_speed = std::abs(m_speed);

        // For speed=1.0, just copy through
        if (abs_speed > 0.99f && abs_speed < 1.01f) {
            std::copy(m_analysis_buffer.begin(),
                      m_analysis_buffer.begin() + hop_out_frames * m_config.channels,
                      m_output_buffer.begin());
            return;
        }

        // Calculate input hop based on speed ratio
        int input_hop = static_cast<int>(m_hop_frames * abs_speed);
        if (input_hop < 1) input_hop = 1;
        if (input_hop > m_analysis_frames / 2) input_hop = m_analysis_frames / 2;

        // Find best correlation offset
        int best_offset = find_best_correlation(input_hop);

        // Apply Hann window and overlap-add
        for (int i = 0; i < m_hop_frames && i < static_cast<int>(hop_out_frames); i++) {
            for (int ch = 0; ch < m_config.channels; ch++) {
                int src_idx = (best_offset + i) * m_config.channels + ch;
                int dst_idx = i * m_config.channels + ch;

                if (src_idx < static_cast<int>(m_analysis_buffer.size())) {
                    float windowed = m_analysis_buffer[src_idx] * m_window[i];

                    // Simple overlap-add synthesis
                    if (i < m_hop_frames / 4) {
                        // Overlap region - blend with previous
                        float blend = static_cast<float>(i) / (m_hop_frames / 4);
                        m_output_buffer[dst_idx] = m_synthesis_buffer[dst_idx] * (1.0f - blend) +
                                                   windowed * blend;
                    } else {
                        m_output_buffer[dst_idx] = windowed;
                    }

                    // Store for next overlap
                    m_synthesis_buffer[dst_idx] = m_analysis_buffer[src_idx] * m_window[m_hop_frames - 1 - i];
                }
            }
        }
    }

    int find_best_correlation(int target_hop) {
        // Simple correlation search around target position
        int best_offset = target_hop;
        float best_corr = -1.0f;

        int search_start = std::max(0, target_hop - m_search_frames);
        int search_end = std::min(m_analysis_frames - m_hop_frames, target_hop + m_search_frames);

        for (int offset = search_start; offset < search_end; offset++) {
            float corr = compute_correlation(offset);
            if (corr > best_corr) {
                best_corr = corr;
                best_offset = offset;
            }
        }

        return best_offset;
    }

    float compute_correlation(int offset) {
        // Simplified correlation - just sum of products
        float sum = 0.0f;
        float norm1 = 0.0f;
        float norm2 = 0.0f;

        int corr_length = m_hop_frames / 4;  // Only correlate overlap region

        for (int i = 0; i < corr_length; i++) {
            for (int ch = 0; ch < m_config.channels; ch++) {
                int idx1 = i * m_config.channels + ch;
                int idx2 = (offset + i) * m_config.channels + ch;

                if (idx2 < static_cast<int>(m_analysis_buffer.size())) {
                    float s1 = m_synthesis_buffer[idx1];
                    float s2 = m_analysis_buffer[idx2];
                    sum += s1 * s2;
                    norm1 += s1 * s1;
                    norm2 += s2 * s2;
                }
            }
        }

        if (norm1 > 0.0001f && norm2 > 0.0001f) {
            return sum / std::sqrt(norm1 * norm2);
        }
        return 0.0f;
    }

    SseConfig m_config;
    SourceBuffer m_source_buffer;

    // Current state
    int64_t m_current_time_us;
    float m_speed;
    QualityMode m_quality;
    bool m_starved;

    // Direction change handling
    int m_last_direction;
    int m_xfade_remaining;
    int m_xfade_frames;

    // WSOLA parameters
    int m_analysis_frames;
    int m_hop_frames;
    int m_search_frames;

    // Buffers
    std::vector<float> m_analysis_buffer;
    std::vector<float> m_synthesis_buffer;
    std::vector<float> m_output_buffer;
    std::vector<float> m_xfade_buffer;
    std::vector<float> m_window;
};

// ScrubStretchEngine implementation

ScrubStretchEngine::ScrubStretchEngine(std::unique_ptr<ScrubStretchEngineImpl> impl)
    : m_impl(std::move(impl)) {
    assert(m_impl && "SSE impl cannot be null");
}

ScrubStretchEngine::~ScrubStretchEngine() = default;

std::unique_ptr<ScrubStretchEngine> ScrubStretchEngine::Create(const SseConfig& config) {
    // NSF: Validate config - fail fast on invalid parameters
    assert(config.sample_rate > 0 &&
           "SSE::Create: sample_rate must be positive");
    assert(config.channels > 0 &&
           "SSE::Create: channels must be positive");
    assert(config.block_frames > 0 &&
           "SSE::Create: block_frames must be positive");
    assert(config.min_speed_q1 > 0.0f &&
           "SSE::Create: min_speed_q1 must be positive");
    assert(config.min_speed_q2 > 0.0f &&
           "SSE::Create: min_speed_q2 must be positive");
    assert(config.max_speed > 0.0f &&
           "SSE::Create: max_speed must be positive");
    assert(config.max_speed >= config.min_speed_q1 &&
           "SSE::Create: max_speed must be >= min_speed_q1");
    assert(config.max_speed >= config.min_speed_q2 &&
           "SSE::Create: max_speed must be >= min_speed_q2");
    assert(config.xfade_ms >= 0 &&
           "SSE::Create: xfade_ms cannot be negative");
    assert(config.lookahead_ms_q1 >= 0 &&
           "SSE::Create: lookahead_ms_q1 cannot be negative");
    assert(config.lookahead_ms_q2 >= 0 &&
           "SSE::Create: lookahead_ms_q2 cannot be negative");

    auto impl = std::make_unique<ScrubStretchEngineImpl>(config);
    return std::unique_ptr<ScrubStretchEngine>(new ScrubStretchEngine(std::move(impl)));
}

void ScrubStretchEngine::Reset() {
    m_impl->reset();
}

void ScrubStretchEngine::SetTarget(int64_t t_us, float speed, QualityMode mode) {
    m_impl->set_target(t_us, speed, mode);
}

void ScrubStretchEngine::PushSourcePcm(const float* interleaved, int64_t frames, int64_t start_time_us) {
    // NSF: Validate inputs
    assert((frames == 0 || interleaved != nullptr) &&
           "SSE::PushSourcePcm: interleaved cannot be null when frames > 0");
    assert(frames >= 0 &&
           "SSE::PushSourcePcm: frames cannot be negative");

    if (frames == 0) return;  // No-op is valid
    m_impl->push_source(interleaved, frames, start_time_us);
}

int64_t ScrubStretchEngine::Render(float* out_interleaved, int64_t out_frames) {
    // NSF: Validate inputs
    assert((out_frames == 0 || out_interleaved != nullptr) &&
           "SSE::Render: out_interleaved cannot be null when out_frames > 0");
    assert(out_frames >= 0 &&
           "SSE::Render: out_frames cannot be negative");

    if (out_frames == 0) return 0;
    return m_impl->render(out_interleaved, out_frames);
}

bool ScrubStretchEngine::Starved() const {
    return m_impl->starved();
}

void ScrubStretchEngine::ClearStarvedFlag() {
    m_impl->clear_starved();
}

int64_t ScrubStretchEngine::CurrentTimeUS() const {
    return m_impl->current_time_us();
}

} // namespace sse
