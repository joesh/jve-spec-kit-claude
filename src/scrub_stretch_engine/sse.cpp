#include "sse.h"

#include <vector>
#include <cmath>
#include <cassert>
#include <algorithm>
#include <cstring>
#include <deque>

namespace sse {

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

// Snippet-based overlap-add scrub engine
// Algorithm: fetch source snippet at current time, linear-resample to output rate,
// apply Hann window, overlap-add with 50% hop. Produces varispeed scrub at all speeds.
// 1x uses direct passthrough (no windowing overhead).
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
        , m_xfade_remaining(0)
        , m_scrub_pos(0)
        , m_snippet_valid(false) {

        // Snippet geometry: 40ms snippet, 50% overlap → 20ms hop
        m_snippet_frames = (config.sample_rate * SNIPPET_MS) / 1000;
        m_hop_frames = m_snippet_frames / 2;

        // Max source frames needed: snippet_frames * MAX_SPEED_DECIMATE
        int max_fetch = static_cast<int>(m_snippet_frames * MAX_SPEED_DECIMATE) + 1;

        // Allocate buffers (interleaved: frames * channels)
        size_t snippet_size = static_cast<size_t>(m_snippet_frames * config.channels);
        m_snippet_a.resize(snippet_size, 0.0f);
        m_snippet_b.resize(snippet_size, 0.0f);
        m_fetch_buffer.resize(static_cast<size_t>(max_fetch * config.channels));
        m_xfade_buffer.resize(snippet_size);

        // Hann window over snippet_frames
        m_window.resize(static_cast<size_t>(m_snippet_frames));
        for (int i = 0; i < m_snippet_frames; i++) {
            m_window[i] = 0.5f * (1.0f - std::cos(2.0f * PI * i / (m_snippet_frames - 1)));
        }

        // Direction crossfade frames
        m_xfade_frames = (config.xfade_ms * config.sample_rate) / 1000;
    }

    void reset() {
        m_source_buffer.clear();
        m_current_time_us = 0;
        m_starved = false;
        m_last_direction = 0;
        m_xfade_remaining = 0;
        reset_snippet_state();
    }

    void set_target(int64_t t_us, float speed, QualityMode mode) {
        // Detect direction change
        int new_direction = (speed >= 0) ? 1 : -1;
        if (m_last_direction != 0 && new_direction != m_last_direction) {
            // Direction flip: initiate crossfade from current output
            m_xfade_remaining = m_xfade_frames;
            // Save current snippet_a as crossfade source (best approximation of last output)
            std::copy(m_snippet_a.begin(), m_snippet_a.end(), m_xfade_buffer.begin());
            reset_snippet_state();
        }
        m_last_direction = new_direction;

        m_current_time_us = t_us;
        m_speed = speed;
        m_quality = mode;

        // Clamp speed to valid range based on quality mode
        float abs_speed = std::abs(m_speed);
        if (mode == QualityMode::Q3_DECIMATE) {
            if (abs_speed > MAX_SPEED_DECIMATE) {
                m_speed = (m_speed >= 0) ? MAX_SPEED_DECIMATE : -MAX_SPEED_DECIMATE;
            }
        } else {
            float min_speed = (mode == QualityMode::Q1) ? m_config.min_speed_q1 : m_config.min_speed_q2;
            if (abs_speed < min_speed) {
                m_speed = (m_speed >= 0) ? min_speed : -min_speed;
            }
            if (abs_speed > MAX_SPEED_DECIMATE) {
                m_speed = (m_speed >= 0) ? MAX_SPEED_DECIMATE : -MAX_SPEED_DECIMATE;
            }
        }
    }

    void push_source(const float* data, int64_t frames, int64_t start_time_us) {
        m_source_buffer.push(data, frames, start_time_us, m_config.sample_rate);

        // Trim data far outside playhead to prevent unbounded memory growth
        int64_t keep_margin_us = 10000000;  // 10s (matches Lua AUDIO_CACHE_HALF_WINDOW_US)
        if (m_speed >= 0) {
            int64_t min_keep = m_current_time_us - keep_margin_us;
            if (min_keep > 0) {
                m_source_buffer.trim(min_keep, m_config.sample_rate);
            }
        } else {
            int64_t max_keep = m_current_time_us + keep_margin_us;
            m_source_buffer.trim_after(max_keep, m_config.sample_rate);
        }
    }

    int64_t render(float* out, int64_t out_frames) {
        if (std::abs(m_speed) < 0.001f) {
            std::memset(out, 0, out_frames * m_config.channels * sizeof(float));
            return out_frames;
        }

        float abs_speed = std::abs(m_speed);

        // 1x passthrough: direct copy, no windowing
        if (abs_speed > 0.99f && abs_speed < 1.01f) {
            return render_passthrough(out, out_frames);
        }

        return render_scrub(out, out_frames);
    }

    bool starved() const { return m_starved; }
    void clear_starved() { m_starved = false; }
    int64_t current_time_us() const { return m_current_time_us; }

private:
    // ── Snippet state management ──

    void reset_snippet_state() {
        m_scrub_pos = 0;
        m_snippet_valid = false;
        std::fill(m_snippet_a.begin(), m_snippet_a.end(), 0.0f);
        std::fill(m_snippet_b.begin(), m_snippet_b.end(), 0.0f);
    }

    // ── Core scrub render: overlap-add with Hann windowed snippets ──

    int64_t render_scrub(float* out, int64_t out_frames) {
        int ch = m_config.channels;
        int64_t frames_produced = 0;

        while (frames_produced < out_frames) {
            // If we're at the start of a new hop, prepare the next snippet
            if (m_scrub_pos >= m_hop_frames || !m_snippet_valid) {
                if (!prepare_next_snippet()) {
                    // Starved - fill remaining with silence
                    m_starved = true;
                    std::memset(out + frames_produced * ch, 0,
                                (out_frames - frames_produced) * ch * sizeof(float));
                    return out_frames;
                }
                m_scrub_pos = 0;
            }

            // How many frames can we produce from the current snippet position?
            int64_t available = m_hop_frames - m_scrub_pos;
            int64_t to_produce = std::min(out_frames - frames_produced, available);

            // Overlap-add: snippet_a[pos] + snippet_b[pos + hop]
            for (int64_t i = 0; i < to_produce; i++) {
                int pos = m_scrub_pos + static_cast<int>(i);
                int pos_b = pos + m_hop_frames;  // snippet_b is offset by hop

                for (int c = 0; c < ch; c++) {
                    float sample = m_snippet_a[pos * ch + c];
                    if (pos_b < m_snippet_frames) {
                        sample += m_snippet_b[pos_b * ch + c];
                    }

                    // Apply direction crossfade if active
                    if (m_xfade_remaining > 0) {
                        float xfade_pos = static_cast<float>(m_xfade_remaining) / m_xfade_frames;
                        sample = sample * (1.0f - xfade_pos);
                        m_xfade_remaining--;
                    }

                    out[(frames_produced + i) * ch + c] = sample;
                }
            }

            m_scrub_pos += static_cast<int>(to_produce);
            frames_produced += to_produce;
        }

        return frames_produced;
    }

    // ── 1x passthrough: direct source copy ──

    int64_t render_passthrough(float* out, int64_t out_frames) {
        int ch = m_config.channels;

        // For reverse, fetch from (current - duration) so output starts at current_time
        int64_t fetch_time = m_current_time_us;
        if (m_speed < 0) {
            int64_t duration_us = (out_frames * 1000000LL) / m_config.sample_rate;
            fetch_time = m_current_time_us - duration_us;
        }

        bool have_source = m_source_buffer.get_samples(
            fetch_time, m_config.sample_rate, out, out_frames);

        if (!have_source) {
            m_starved = true;
            std::memset(out, 0, out_frames * ch * sizeof(float));
            return out_frames;
        }

        if (m_speed < 0) {
            reverse_interleaved(out, out_frames);
        }

        // Apply direction crossfade if active
        if (m_xfade_remaining > 0) {
            apply_direction_crossfade(out, out_frames);
        }

        advance_time(out_frames);
        return out_frames;
    }

    // ── Prepare next snippet: swap, fetch, resample, window, advance ──

    bool prepare_next_snippet() {
        int ch = m_config.channels;
        float abs_speed = std::abs(m_speed);

        // Swap: old snippet_a becomes snippet_b (it's the trailing overlap)
        std::swap(m_snippet_a, m_snippet_b);

        // Calculate how many source frames we need for this snippet
        int source_frames_needed = static_cast<int>(std::ceil(m_snippet_frames * abs_speed));
        if (source_frames_needed < 1) source_frames_needed = 1;

        // Fetch source at current time
        int64_t fetch_time = m_current_time_us;
        if (m_speed < 0) {
            // For reverse: fetch from (current - source_duration) so data corresponds
            // to the time region we're about to play through
            int64_t source_duration_us = (static_cast<int64_t>(source_frames_needed) * 1000000LL) / m_config.sample_rate;
            fetch_time = m_current_time_us - source_duration_us;
        }

        bool have_source = m_source_buffer.get_samples(
            fetch_time, m_config.sample_rate,
            m_fetch_buffer.data(), source_frames_needed);

        if (!have_source) {
            return false;
        }

        // Reverse the fetched source if playing backwards
        if (m_speed < 0) {
            reverse_interleaved(m_fetch_buffer.data(), source_frames_needed);
        }

        // Linear resample: source_frames_needed → m_snippet_frames
        linear_resample(m_fetch_buffer.data(), source_frames_needed,
                        m_snippet_a.data(), m_snippet_frames, ch);

        // Apply Hann window
        for (int i = 0; i < m_snippet_frames; i++) {
            for (int c = 0; c < ch; c++) {
                m_snippet_a[i * ch + c] *= m_window[i];
            }
        }

        m_snippet_valid = true;

        // Advance source time by hop duration (not snippet duration)
        advance_time(m_hop_frames);

        return true;
    }

    // ── Linear interpolation resample ──

    static void linear_resample(const float* in, int in_frames,
                                float* out, int out_frames, int channels) {
        if (in_frames <= 1) {
            // Degenerate: just copy the single frame (or zero)
            for (int i = 0; i < out_frames; i++) {
                for (int c = 0; c < channels; c++) {
                    out[i * channels + c] = (in_frames == 1) ? in[c] : 0.0f;
                }
            }
            return;
        }

        float ratio = static_cast<float>(in_frames - 1) / static_cast<float>(out_frames - 1);

        for (int i = 0; i < out_frames; i++) {
            float src_pos = i * ratio;
            int idx0 = static_cast<int>(src_pos);
            int idx1 = std::min(idx0 + 1, in_frames - 1);
            float frac = src_pos - idx0;

            for (int c = 0; c < channels; c++) {
                out[i * channels + c] = in[idx0 * channels + c] * (1.0f - frac)
                                      + in[idx1 * channels + c] * frac;
            }
        }
    }

    // ── Time advancement ──

    void advance_time(int64_t output_frames) {
        int64_t time_advance_us = (output_frames * 1000000LL) / m_config.sample_rate;
        time_advance_us = static_cast<int64_t>(time_advance_us * m_speed);
        m_current_time_us += time_advance_us;
    }

    // ── Utilities ──

    void reverse_interleaved(float* data, int64_t frames) {
        int channels = m_config.channels;
        for (int64_t i = 0; i < frames / 2; i++) {
            int64_t j = frames - 1 - i;
            for (int ch = 0; ch < channels; ch++) {
                std::swap(data[i * channels + ch], data[j * channels + ch]);
            }
        }
    }

    void apply_direction_crossfade(float* out, int64_t frames) {
        int ch = m_config.channels;
        for (int64_t i = 0; i < frames && m_xfade_remaining > 0; i++) {
            float xfade_pos = static_cast<float>(m_xfade_remaining) / m_xfade_frames;
            for (int c = 0; c < ch; c++) {
                out[i * ch + c] *= (1.0f - xfade_pos);
            }
            m_xfade_remaining--;
        }
    }

    // ── Member data ──

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

    // Snippet geometry
    int m_snippet_frames;   // 40ms = 1920 @ 48kHz
    int m_hop_frames;       // 50% overlap = 960 @ 48kHz

    // Snippet state
    int m_scrub_pos;        // Current position within the hop region
    bool m_snippet_valid;   // Whether snippet_a/b contain valid data

    // Buffers (all interleaved: frames * channels)
    std::vector<float> m_snippet_a;     // Current snippet (windowed)
    std::vector<float> m_snippet_b;     // Previous snippet (for overlap tail)
    std::vector<float> m_fetch_buffer;  // Raw source fetch (pre-resample)
    std::vector<float> m_xfade_buffer;  // Direction crossfade snapshot
    std::vector<float> m_window;        // Hann window (snippet_frames)
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
