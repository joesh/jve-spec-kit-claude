#include <editor_media_platform/emp_timeline_media_buffer.h>
#include "impl/pcm_chunk_impl.h"
#include <cassert>
#include <algorithm>
#include <cmath>
#include <limits>

namespace emp {

// ============================================================================
// Construction / destruction
// ============================================================================

TimelineMediaBuffer::TimelineMediaBuffer() = default;

TimelineMediaBuffer::~TimelineMediaBuffer() {
    stop_workers();
    ReleaseAll();
}

std::unique_ptr<TimelineMediaBuffer> TimelineMediaBuffer::Create(int pool_threads) {
    auto tmb = std::unique_ptr<TimelineMediaBuffer>(new TimelineMediaBuffer());
    if (pool_threads > 0) {
        tmb->start_workers(pool_threads);
    }
    return tmb;
}

// ============================================================================
// Track clip layout
// ============================================================================

void TimelineMediaBuffer::SetTrackClips(int track_id, const std::vector<ClipInfo>& clips) {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto& ts = m_tracks[track_id];
    ts.clips = clips;
    ts.video_cache.clear();
    ts.audio_cache.clear();
}

// ============================================================================
// Playhead
// ============================================================================

void TimelineMediaBuffer::SetPlayhead(int64_t frame, int direction, float speed) {
    m_playhead_frame.store(frame, std::memory_order_relaxed);
    m_playhead_direction.store(direction, std::memory_order_relaxed);
    m_playhead_speed.store(speed, std::memory_order_relaxed);

    // Evaluate pre-buffer needs for each track
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    for (auto& [tid, ts] : m_tracks) {
        const ClipInfo* current = find_clip_at(ts, frame);
        if (!current) continue;

        // Check distance to boundary
        int64_t boundary = (direction >= 0) ? current->timeline_end() : current->timeline_start;
        int64_t distance = std::abs(frame - boundary);

        // Pre-buffer threshold: ~2 seconds of frames at assumed 24fps
        // (actual rate doesn't matter much — this is just a heuristic)
        constexpr int64_t PRE_BUFFER_THRESHOLD = 48;

        if (distance < PRE_BUFFER_THRESHOLD) {
            // Find next clip in playback direction
            const ClipInfo* next = nullptr;
            for (const auto& clip : ts.clips) {
                if (direction >= 0 && clip.timeline_start == current->timeline_end()) {
                    next = &clip;
                    break;
                } else if (direction < 0 && clip.timeline_end() == current->timeline_start) {
                    next = &clip;
                    break;
                }
            }

            if (next) {
                // Video pre-buffer
                int64_t entry_frame = (direction >= 0)
                    ? next->source_in
                    : next->source_in + next->duration - 1;
                int64_t entry_tl_frame = (direction >= 0)
                    ? next->timeline_start
                    : next->timeline_end() - 1;

                PreBufferJob video_job{};
                video_job.type = PreBufferJob::VIDEO;
                video_job.track_id = tid;
                video_job.clip_id = next->clip_id;
                video_job.media_path = next->media_path;
                video_job.source_frame = entry_frame;
                video_job.timeline_frame = entry_tl_frame;
                video_job.rate = next->rate();
                submit_pre_buffer(video_job);

                // Audio pre-buffer (~200ms from next clip's entry point)
                if (m_audio_fmt.sample_rate > 0 && m_seq_rate.num > 0) {
                    assert(next->rate_den > 0 && "SetPlayhead: audio pre-buffer clip has zero rate_den");
                    assert(next->speed_ratio > 0.0f && "SetPlayhead: audio pre-buffer clip has non-positive speed_ratio");
                    constexpr TimeUS AUDIO_PRE_BUFFER_US = 200000; // 200ms

                    TimeUS next_start_us = FrameTime::from_frame(
                        next->timeline_start, m_seq_rate).to_us();
                    TimeUS next_end_us = FrameTime::from_frame(
                        next->timeline_end(), m_seq_rate).to_us();

                    TimeUS tl_t0, tl_t1;
                    if (direction >= 0) {
                        tl_t0 = next_start_us;
                        tl_t1 = std::min(next_start_us + AUDIO_PRE_BUFFER_US, next_end_us);
                    } else {
                        tl_t1 = next_end_us;
                        tl_t0 = std::max(next_end_us - AUDIO_PRE_BUFFER_US, next_start_us);
                    }

                    if (tl_t1 > tl_t0) {
                        // Map timeline range to source range
                        TimeUS src_origin = FrameTime::from_frame(
                            next->source_in, next->rate()).to_us();
                        double sr = static_cast<double>(next->speed_ratio);
                        TimeUS src_t0 = src_origin +
                            static_cast<int64_t>((tl_t0 - next_start_us) * sr);
                        TimeUS src_t1 = src_origin +
                            static_cast<int64_t>((tl_t1 - next_start_us) * sr);

                        PreBufferJob audio_job{};
                        audio_job.type = PreBufferJob::AUDIO;
                        audio_job.track_id = tid;
                        audio_job.clip_id = next->clip_id;
                        audio_job.media_path = next->media_path;
                        audio_job.source_t0 = src_t0;
                        audio_job.source_t1 = src_t1;
                        audio_job.timeline_t0 = tl_t0;
                        audio_job.timeline_t1 = tl_t1;
                        audio_job.speed_ratio = next->speed_ratio;
                        submit_pre_buffer(audio_job);
                    }
                }
            }
        }
    }
}

// ============================================================================
// Find clip at timeline position
// ============================================================================

const ClipInfo* TimelineMediaBuffer::find_clip_at(const TrackState& ts, int64_t timeline_frame) const {
    for (const auto& clip : ts.clips) {
        if (timeline_frame >= clip.timeline_start && timeline_frame < clip.timeline_end()) {
            return &clip;
        }
    }
    return nullptr;
}

// ============================================================================
// GetVideoFrame
// ============================================================================

VideoResult TimelineMediaBuffer::GetVideoFrame(int track_id, int64_t timeline_frame) {
    VideoResult result{};
    result.frame = nullptr;
    result.offline = false;

    // Find track and clip
    std::unique_lock<std::mutex> tracks_lock(m_tracks_mutex);
    auto track_it = m_tracks.find(track_id);
    if (track_it == m_tracks.end()) {
        return result; // gap — no track data
    }
    auto& ts = track_it->second;

    const ClipInfo* clip = find_clip_at(ts, timeline_frame);
    if (!clip) {
        return result; // gap — no clip at this position
    }

    // Populate metadata
    result.clip_id = clip->clip_id;
    result.clip_fps_num = clip->rate_num;
    result.clip_fps_den = clip->rate_den;
    result.clip_start_frame = clip->timeline_start;
    result.clip_end_frame = clip->timeline_end();

    // Compute source frame: source_in + (timeline_frame - timeline_start)
    int64_t source_frame = clip->source_in + (timeline_frame - clip->timeline_start);
    result.source_frame = source_frame;

    // Check video cache (keyed by timeline_frame for this track)
    auto cache_it = ts.video_cache.find(timeline_frame);
    if (cache_it != ts.video_cache.end() &&
        cache_it->second.clip_id == clip->clip_id &&
        cache_it->second.source_frame == source_frame) {
        result.frame = cache_it->second.frame;
        return result;
    }

    // Release tracks lock before acquiring pool lock (avoid deadlock)
    std::string media_path = clip->media_path;
    Rate clip_rate = clip->rate();
    std::string clip_id = clip->clip_id;
    tracks_lock.unlock();

    // Check offline registry
    {
        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
        auto offline_it = m_offline.find(media_path);
        if (offline_it != m_offline.end()) {
            result.offline = true;
            return result;
        }
    }

    // Acquire reader and decode
    auto reader = acquire_reader(track_id, media_path);
    if (!reader) {
        result.offline = true;
        return result;
    }

    // Get media file info for start_tc and rotation
    const auto& info = reader->media_file()->info();
    result.rotation = info.rotation;

    // Subtract start_tc to get file-relative frame
    int64_t file_frame = source_frame - info.start_tc;

    // Decode at file-relative frame using clip rate
    FrameTime ft = FrameTime::from_frame(file_frame, clip_rate);
    auto decode_result = reader->DecodeAt(ft);

    if (decode_result.is_ok()) {
        result.frame = decode_result.value();

        // Cache the decoded frame
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track_id);
        if (tit != m_tracks.end()) {
            auto& cache = tit->second.video_cache;

            // Evict oldest if at capacity
            while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                cache.erase(cache.begin());
            }

            cache[timeline_frame] = {clip_id, source_frame, result.frame};
        }
    }
    // decode failure → frame stays nullptr (treated like offline by Lua)

    return result;
}

// ============================================================================
// SetSequenceRate
// ============================================================================

void TimelineMediaBuffer::SetSequenceRate(int32_t num, int32_t den) {
    assert(num > 0 && "SetSequenceRate: num must be positive");
    assert(den > 0 && "SetSequenceRate: den must be positive");
    m_seq_rate = Rate{num, den};
}

// ============================================================================
// SetAudioFormat
// ============================================================================

void TimelineMediaBuffer::SetAudioFormat(const AudioFormat& fmt) {
    assert(fmt.sample_rate > 0 && "SetAudioFormat: sample_rate must be positive");
    assert(fmt.channels > 0 && "SetAudioFormat: channels must be positive");
    m_audio_fmt = fmt;
}

// ============================================================================
// find_clip_at_us — microsecond-based clip search (audio path)
// ============================================================================

const ClipInfo* TimelineMediaBuffer::find_clip_at_us(const TrackState& ts, TimeUS t_us) const {
    assert(m_seq_rate.num > 0 && "find_clip_at_us: SetSequenceRate not called");
    for (const auto& clip : ts.clips) {
        assert(clip.rate_den > 0 && "find_clip_at_us: clip has zero rate_den");
        TimeUS start = FrameTime::from_frame(clip.timeline_start, m_seq_rate).to_us();
        TimeUS end = FrameTime::from_frame(clip.timeline_end(), m_seq_rate).to_us();
        if (t_us >= start && t_us < end) {
            return &clip;
        }
    }
    return nullptr;
}

// ============================================================================
// find_next_clip_at_us — first clip starting at or after t_us (boundary spanning)
// ============================================================================

const ClipInfo* TimelineMediaBuffer::find_next_clip_at_us(const TrackState& ts, TimeUS t_us) const {
    assert(m_seq_rate.num > 0 && "find_next_clip_at_us: SetSequenceRate not called");
    const ClipInfo* best = nullptr;
    TimeUS best_start = std::numeric_limits<TimeUS>::max();
    for (const auto& clip : ts.clips) {
        TimeUS start = FrameTime::from_frame(clip.timeline_start, m_seq_rate).to_us();
        if (start >= t_us && start < best_start) {
            best = &clip;
            best_start = start;
        }
    }
    return best;
}

// ============================================================================
// build_audio_output — trim decoded audio, conform (resample), rebase to timeline
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::build_audio_output(
        const std::shared_ptr<PcmChunk>& decoded,
        TimeUS source_t0, TimeUS source_t1,
        TimeUS timeline_t0, TimeUS timeline_t1,
        float speed_ratio, const AudioFormat& fmt) const {

    assert(decoded && "build_audio_output: decoded chunk is null");
    assert(source_t1 > source_t0 && "build_audio_output: inverted source range");
    assert(timeline_t1 > timeline_t0 && "build_audio_output: inverted timeline range");
    assert(fmt.sample_rate > 0 && "build_audio_output: sample_rate must be positive");
    assert(fmt.channels > 0 && "build_audio_output: channels must be positive");
    assert(speed_ratio > 0.0f && "build_audio_output: speed_ratio must be positive");

    const int32_t sr = fmt.sample_rate;
    const int32_t ch = fmt.channels;
    const float* src_data = decoded->data_f32();
    const int64_t src_frames = decoded->frames();
    const TimeUS src_start = decoded->start_time_us();

    // How many input samples to skip (decoder may have started before source_t0)
    int64_t skip = 0;
    if (src_start < source_t0) {
        skip = ((source_t0 - src_start) * sr) / 1000000;
    }
    if (skip >= src_frames) return nullptr;

    // How many input samples span [source_t0, source_t1]
    int64_t source_duration_us = source_t1 - source_t0;
    int64_t source_sample_count = (source_duration_us * sr) / 1000000;
    int64_t available = src_frames - skip;
    if (source_sample_count > available) {
        source_sample_count = available;
    }
    if (source_sample_count <= 0) return nullptr;

    // Output sample count (timeline duration)
    int64_t timeline_duration_us = timeline_t1 - timeline_t0;
    int64_t out_frames = (timeline_duration_us * sr) / 1000000;
    if (out_frames <= 0) return nullptr;

    std::vector<float> out_data(out_frames * ch);

    if (std::abs(speed_ratio - 1.0f) < 0.001f) {
        // No conform — direct copy (trim only)
        int64_t copy_frames = std::min(out_frames, source_sample_count);
        const float* src = src_data + skip * ch;
        std::copy(src, src + copy_frames * ch, out_data.data());
        // Zero-fill if we got fewer samples than requested
        if (copy_frames < out_frames) {
            std::fill(out_data.data() + copy_frames * ch,
                      out_data.data() + out_frames * ch, 0.0f);
        }
    } else {
        // Conform: linear interpolation from source_sample_count → out_frames
        const float* src = src_data + skip * ch;
        double ratio = static_cast<double>(source_sample_count) / out_frames;

        int64_t max_idx = source_sample_count - 1;
        for (int64_t i = 0; i < out_frames; ++i) {
            double src_pos = i * ratio;
            int64_t s0 = static_cast<int64_t>(src_pos);
            double frac = src_pos - s0;

            // Clamp both indices to valid range (float edge cases)
            if (s0 > max_idx) s0 = max_idx;
            int64_t s1 = std::min(s0 + 1, max_idx);

            for (int c = 0; c < ch; ++c) {
                float v0 = src[s0 * ch + c];
                float v1 = src[s1 * ch + c];
                out_data[i * ch + c] = static_cast<float>(v0 * (1.0 - frac) + v1 * frac);
            }
        }
    }

    auto impl = std::make_unique<PcmChunkImpl>(
        sr, ch, fmt.fmt, timeline_t0, std::move(out_data));
    return std::make_shared<PcmChunk>(std::move(impl));
}

// ============================================================================
// check_audio_cache — scan for pre-buffered PCM with full coverage
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::check_audio_cache(
        TrackState& ts, const std::string& clip_id,
        TimeUS seg_t0, TimeUS seg_t1, const AudioFormat& fmt) const {

    assert(seg_t1 > seg_t0 && "check_audio_cache: inverted time range");
    assert(fmt.sample_rate > 0 && "check_audio_cache: sample_rate must be positive");
    assert(fmt.channels > 0 && "check_audio_cache: channels must be positive");

    for (const auto& entry : ts.audio_cache) {
        if (entry.clip_id != clip_id) continue;
        // Full coverage: cached range must contain [seg_t0, seg_t1)
        if (entry.timeline_t0 > seg_t0 || entry.timeline_t1 < seg_t1) continue;

        assert(entry.pcm && "check_audio_cache: cached entry has null pcm");

        // Exact match — return as-is
        if (entry.timeline_t0 == seg_t0 && entry.timeline_t1 == seg_t1) {
            return entry.pcm;
        }

        // Sub-range extraction: trim cached PCM to [seg_t0, seg_t1)
        const float* data = entry.pcm->data_f32();
        int64_t total_frames = entry.pcm->frames();
        int32_t sr = fmt.sample_rate;
        int32_t ch = fmt.channels;

        int64_t skip_frames = ((seg_t0 - entry.timeline_t0) * sr) / 1000000;
        int64_t want_frames = ((seg_t1 - seg_t0) * sr) / 1000000;
        if (skip_frames + want_frames > total_frames) {
            want_frames = total_frames - skip_frames;
        }
        if (want_frames <= 0) continue;

        std::vector<float> sub(want_frames * ch);
        std::copy(data + skip_frames * ch,
                  data + (skip_frames + want_frames) * ch,
                  sub.data());

        auto impl = std::make_unique<PcmChunkImpl>(
            sr, ch, fmt.fmt, seg_t0, std::move(sub));
        return std::make_shared<PcmChunk>(std::move(impl));
    }
    return nullptr;
}

// ============================================================================
// GetTrackAudio
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::GetTrackAudio(
        int track_id, TimeUS t0, TimeUS t1, const AudioFormat& fmt) {
    assert(t1 > t0 && "GetTrackAudio: t1 must be greater than t0");
    assert(m_seq_rate.num > 0 && "GetTrackAudio: SetSequenceRate not called");

    // Find track
    std::unique_lock<std::mutex> tracks_lock(m_tracks_mutex);
    auto track_it = m_tracks.find(track_id);
    if (track_it == m_tracks.end()) return nullptr;
    auto& ts = track_it->second;

    // Find clip at t0
    const ClipInfo* clip = find_clip_at_us(ts, t0);
    if (!clip) return nullptr;

    assert(clip->rate_den > 0 && "GetTrackAudio: clip has zero rate_den");
    assert(clip->speed_ratio > 0.0f && "GetTrackAudio: clip has non-positive speed_ratio");

    // Clip boundaries in timeline microseconds
    TimeUS clip_start_us = FrameTime::from_frame(clip->timeline_start, m_seq_rate).to_us();
    TimeUS clip_end_us = FrameTime::from_frame(clip->timeline_end(), m_seq_rate).to_us();

    // Clamp request to first clip
    TimeUS clamped_t0 = std::max(t0, clip_start_us);
    TimeUS clamped_t1 = std::min(t1, clip_end_us);
    if (clamped_t1 <= clamped_t0) return nullptr;

    // Map timeline us → source us
    TimeUS source_origin_us = FrameTime::from_frame(clip->source_in, clip->rate()).to_us();
    double sr = static_cast<double>(clip->speed_ratio);
    TimeUS source_t0 = source_origin_us + static_cast<int64_t>((clamped_t0 - clip_start_us) * sr);
    TimeUS source_t1 = source_origin_us + static_cast<int64_t>((clamped_t1 - clip_start_us) * sr);

    // Check audio cache before decode
    std::string clip_id = clip->clip_id;
    auto cached = check_audio_cache(ts, clip_id, clamped_t0, clamped_t1, fmt);

    // Copy locals before releasing lock
    std::string media_path = clip->media_path;
    float speed_ratio = clip->speed_ratio;
    TimeUS first_clip_end_us = clip_end_us;
    tracks_lock.unlock();

    std::shared_ptr<PcmChunk> first_chunk;
    if (cached) {
        first_chunk = cached;
    } else {
        // Offline check
        {
            std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
            if (m_offline.count(media_path)) return nullptr;
        }

        // Acquire reader and decode first clip
        auto reader = acquire_reader(track_id, media_path);
        if (!reader) return nullptr;

        auto decode_result = reader->DecodeAudioRangeUS(source_t0, source_t1, fmt);
        if (decode_result.is_error()) return nullptr;

        auto chunk = decode_result.value();
        if (!chunk || chunk->frames() == 0) return nullptr;

        first_chunk = build_audio_output(chunk, source_t0, source_t1,
                                         clamped_t0, clamped_t1, speed_ratio, fmt);
    }

    // ── Fast path: request fully within first clip ──
    if (clamped_t1 >= t1 || !first_chunk) return first_chunk;

    // ── Boundary spanning: fill remainder from subsequent clips ──
    const int32_t sample_rate = fmt.sample_rate;
    const int32_t channels = fmt.channels;

    struct AudioSegment {
        std::shared_ptr<PcmChunk> pcm;
        TimeUS seg_t0;
    };
    std::vector<AudioSegment> segments;
    segments.push_back({first_chunk, clamped_t0});
    TimeUS output_end = clamped_t1;
    TimeUS cursor = first_clip_end_us;

    while (cursor < t1) {
        std::unique_lock<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track_id);
        if (tit == m_tracks.end()) break;

        const ClipInfo* next = find_next_clip_at_us(tit->second, cursor);
        if (!next) break;

        TimeUS next_start_us = FrameTime::from_frame(next->timeline_start, m_seq_rate).to_us();
        if (next_start_us >= t1) break;

        assert(next->rate_den > 0 && "GetTrackAudio: next clip has zero rate_den");
        assert(next->speed_ratio > 0.0f && "GetTrackAudio: next clip has non-positive speed_ratio");

        TimeUS next_end_us = FrameTime::from_frame(next->timeline_end(), m_seq_rate).to_us();
        TimeUS seg_t0 = std::max(cursor, next_start_us);
        TimeUS seg_t1 = std::min(t1, next_end_us);
        if (seg_t1 <= seg_t0) { cursor = next_end_us; continue; }

        // Check audio cache before decode
        std::string next_clip_id = next->clip_id;
        auto next_cached = check_audio_cache(tit->second, next_clip_id, seg_t0, seg_t1, fmt);
        if (next_cached) {
            segments.push_back({next_cached, seg_t0});
            if (seg_t1 > output_end) output_end = seg_t1;
            tlock.unlock();
            cursor = next_end_us;
            continue;
        }

        // Map to source coordinates
        TimeUS next_src_origin = FrameTime::from_frame(next->source_in, next->rate()).to_us();
        double next_sr = static_cast<double>(next->speed_ratio);
        TimeUS next_src_t0 = next_src_origin + static_cast<int64_t>((seg_t0 - next_start_us) * next_sr);
        TimeUS next_src_t1 = next_src_origin + static_cast<int64_t>((seg_t1 - next_start_us) * next_sr);

        std::string next_path = next->media_path;
        float next_speed = next->speed_ratio;
        tlock.unlock();

        // Offline check
        {
            std::lock_guard<std::mutex> plock(m_pool_mutex);
            if (m_offline.count(next_path)) { cursor = next_end_us; continue; }
        }

        auto next_reader = acquire_reader(track_id, next_path);
        if (!next_reader) { cursor = next_end_us; continue; }

        auto next_decoded = next_reader->DecodeAudioRangeUS(next_src_t0, next_src_t1, fmt);
        if (next_decoded.is_ok() && next_decoded.value() && next_decoded.value()->frames() > 0) {
            auto seg = build_audio_output(next_decoded.value(), next_src_t0, next_src_t1,
                                          seg_t0, seg_t1, next_speed, fmt);
            if (seg && seg->frames() > 0) {
                segments.push_back({seg, seg_t0});
                if (seg_t1 > output_end) output_end = seg_t1;
            }
        }

        cursor = next_end_us;
    }

    // Single segment: return it directly (no combining needed)
    if (segments.size() == 1) return first_chunk;

    // Combine segments into one output buffer (gaps are zero-filled)
    assert(output_end > t0 && "GetTrackAudio: output_end must exceed t0 when combining segments");
    int64_t total_frames = ((output_end - t0) * sample_rate) / 1000000;
    assert(total_frames > 0 && "GetTrackAudio: total_frames must be positive when combining segments");

    std::vector<float> combined(total_frames * channels, 0.0f);

    for (const auto& seg : segments) {
        int64_t offset = ((seg.seg_t0 - t0) * sample_rate) / 1000000;
        assert(offset >= 0 && "GetTrackAudio: segment offset must be non-negative");
        int64_t copy_frames = std::min(seg.pcm->frames(), total_frames - offset);
        assert(copy_frames > 0 && "GetTrackAudio: segment copy_frames must be positive");
        std::copy(seg.pcm->data_f32(),
                  seg.pcm->data_f32() + copy_frames * channels,
                  combined.data() + offset * channels);
    }

    auto impl = std::make_unique<PcmChunkImpl>(
        sample_rate, channels, fmt.fmt, t0, std::move(combined));
    return std::make_shared<PcmChunk>(std::move(impl));
}

// ============================================================================
// ProbeFile (Phase 2e — implemented here since it's simple)
// ============================================================================

Result<MediaFileInfo> TimelineMediaBuffer::ProbeFile(const std::string& path) {
    auto result = MediaFile::Open(path);
    if (result.is_error()) {
        return result.error();
    }
    return result.value()->info();
}

// ============================================================================
// Configuration
// ============================================================================

void TimelineMediaBuffer::SetMaxReaders(int max) {
    std::lock_guard<std::mutex> lock(m_pool_mutex);
    m_max_readers = max;
    // Evict if over new limit
    while (static_cast<int>(m_readers.size()) > m_max_readers) {
        evict_lru_reader();
    }
}

// ============================================================================
// Lifecycle
// ============================================================================

void TimelineMediaBuffer::ReleaseTrack(int track_id) {
    // Remove track state
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        m_tracks.erase(track_id);
    }

    // Release readers for this track
    std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
    for (auto it = m_readers.begin(); it != m_readers.end(); ) {
        if (it->first.first == track_id) {
            it = m_readers.erase(it);
        } else {
            ++it;
        }
    }
}

void TimelineMediaBuffer::ReleaseAll() {
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        m_tracks.clear();
    }
    {
        std::lock_guard<std::mutex> lock(m_pool_mutex);
        m_readers.clear();
        m_offline.clear();
    }
}

// ============================================================================
// Reader pool — LRU with per-(track, path) isolation
// ============================================================================

std::shared_ptr<Reader> TimelineMediaBuffer::acquire_reader(
        int track_id, const std::string& path) {

    std::lock_guard<std::mutex> lock(m_pool_mutex);

    auto key = std::make_pair(track_id, path);
    auto it = m_readers.find(key);
    if (it != m_readers.end()) {
        it->second.last_used = ++m_pool_clock;
        return it->second.reader;
    }

    // Not in pool — open new reader
    // Evict if at capacity
    while (static_cast<int>(m_readers.size()) >= m_max_readers) {
        evict_lru_reader();
    }

    // Open media file
    auto mf_result = MediaFile::Open(path);
    if (mf_result.is_error()) {
        // Mark offline
        m_offline[path] = mf_result.error();
        return nullptr;
    }

    auto mf = mf_result.value();

    // Create reader
    auto reader_result = Reader::Create(mf);
    if (reader_result.is_error()) {
        m_offline[path] = reader_result.error();
        return nullptr;
    }

    auto reader = reader_result.value();
    m_readers[key] = PoolEntry{path, mf, reader, track_id, ++m_pool_clock};
    return reader;
}

void TimelineMediaBuffer::release_reader(int track_id, const std::string& path) {
    std::lock_guard<std::mutex> lock(m_pool_mutex);
    m_readers.erase(std::make_pair(track_id, path));
}

void TimelineMediaBuffer::evict_lru_reader() {
    // Must be called with m_pool_mutex held
    if (m_readers.empty()) return;

    auto oldest = m_readers.begin();
    for (auto it = m_readers.begin(); it != m_readers.end(); ++it) {
        if (it->second.last_used < oldest->second.last_used) {
            oldest = it;
        }
    }
    m_readers.erase(oldest);
}

// ============================================================================
// Thread pool for pre-buffering
// ============================================================================

void TimelineMediaBuffer::start_workers(int count) {
    m_shutdown.store(false);
    for (int i = 0; i < count; ++i) {
        m_workers.emplace_back(&TimelineMediaBuffer::worker_loop, this);
    }
}

void TimelineMediaBuffer::stop_workers() {
    m_shutdown.store(true);
    m_jobs_cv.notify_all();
    for (auto& w : m_workers) {
        if (w.joinable()) w.join();
    }
    m_workers.clear();
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        m_jobs.clear();
    }
}

void TimelineMediaBuffer::submit_pre_buffer(const PreBufferJob& job) {
    std::lock_guard<std::mutex> lock(m_jobs_mutex);

    // De-duplicate: don't submit if same (track_id, clip_id, type) already queued
    for (const auto& j : m_jobs) {
        if (j.track_id == job.track_id && j.clip_id == job.clip_id && j.type == job.type) {
            return;
        }
    }

    m_jobs.push_back(job);
    m_jobs_cv.notify_one();
}

void TimelineMediaBuffer::worker_loop() {
    while (!m_shutdown.load()) {
        PreBufferJob job;
        {
            std::unique_lock<std::mutex> lock(m_jobs_mutex);
            m_jobs_cv.wait(lock, [this] {
                return m_shutdown.load() || !m_jobs.empty();
            });
            if (m_shutdown.load()) break;
            if (m_jobs.empty()) continue;

            job = std::move(m_jobs.back());
            m_jobs.pop_back();
        }

        // Acquire reader (may open a new one)
        auto reader = acquire_reader(job.track_id, job.media_path);
        if (!reader) continue;

        if (job.type == PreBufferJob::VIDEO) {
            // Pre-decode video frame
            const auto& info = reader->media_file()->info();
            int64_t file_frame = job.source_frame - info.start_tc;
            FrameTime ft = FrameTime::from_frame(file_frame, job.rate);
            auto result = reader->DecodeAt(ft);

            if (result.is_ok()) {
                // Store in track's video cache
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(job.track_id);
                if (it != m_tracks.end()) {
                    auto& cache = it->second.video_cache;
                    while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                        cache.erase(cache.begin());
                    }
                    cache[job.timeline_frame] = {
                        job.clip_id, job.source_frame, result.value()
                    };
                }
            }
        } else {
            // Pre-decode audio PCM
            assert(job.source_t1 > job.source_t0 && "worker_loop: AUDIO job has inverted source range");
            assert(job.timeline_t1 > job.timeline_t0 && "worker_loop: AUDIO job has inverted timeline range");
            auto decode_result = reader->DecodeAudioRangeUS(
                job.source_t0, job.source_t1, m_audio_fmt);
            if (decode_result.is_error()) continue;

            auto decoded = decode_result.value();
            if (!decoded || decoded->frames() == 0) continue;

            auto pcm = build_audio_output(decoded, job.source_t0, job.source_t1,
                                          job.timeline_t0, job.timeline_t1,
                                          job.speed_ratio, m_audio_fmt);
            if (!pcm || pcm->frames() == 0) continue;

            // Store in track's audio cache
            std::lock_guard<std::mutex> lock(m_tracks_mutex);
            auto it = m_tracks.find(job.track_id);
            if (it != m_tracks.end()) {
                auto& cache = it->second.audio_cache;
                // Evict oldest if at capacity
                while (cache.size() >= TrackState::MAX_AUDIO_CACHE) {
                    cache.erase(cache.begin());
                }
                cache.push_back({job.clip_id, job.timeline_t0, job.timeline_t1, pcm});
            }
        }
    }
}

} // namespace emp
