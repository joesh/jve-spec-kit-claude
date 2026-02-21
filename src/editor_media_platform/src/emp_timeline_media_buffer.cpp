#include <editor_media_platform/emp_timeline_media_buffer.h>
#include "impl/pcm_chunk_impl.h"
#include <cassert>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <unordered_set>

// RAII scope guard — calls fn() on destruction (handles continue/break/return).
namespace {
template<typename F>
struct ScopeExit {
    F fn;
    ~ScopeExit() { fn(); }
};
template<typename F>
ScopeExit<F> make_scope_exit(F fn) { return {std::move(fn)}; }
} // namespace

// Logging — same env-var scheme as emp_reader.cpp
namespace {
inline int tmb_log_level() {
    static int level = -1;
    if (level < 0) {
        const char* env = std::getenv("EMP_LOG_LEVEL");
        level = env ? std::atoi(env) : 0;
    }
    return level;
}
} // namespace

#define EMP_LOG_WARN(...) do { if (tmb_log_level() >= 1) { fprintf(stderr, "[TMB WARN] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)
#define EMP_LOG_DEBUG(...) do { if (tmb_log_level() >= 2) { fprintf(stderr, "[TMB] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)

namespace emp {

// ============================================================================
// Construction / destruction
// ============================================================================

TimelineMediaBuffer::TimelineMediaBuffer() = default;

TimelineMediaBuffer::~TimelineMediaBuffer() {
    stop_mix_thread();
    stop_workers();
    ReleaseAll();
}

std::unique_ptr<TimelineMediaBuffer> TimelineMediaBuffer::Create(int pool_threads) {
    auto tmb = std::unique_ptr<TimelineMediaBuffer>(new TimelineMediaBuffer());
    if (pool_threads > 0) {
        tmb->start_workers(pool_threads);
    }
    tmb->start_mix_thread();
    return tmb;
}

// ============================================================================
// Track clip layout
// ============================================================================

void TimelineMediaBuffer::SetTrackClips(TrackId track, const std::vector<ClipInfo>& clips) {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto& ts = m_tracks[track];

    // Fast path: skip entirely if clip list is unchanged (called every tick)
    if (ts.clips.size() == clips.size()) {
        bool same = true;
        for (size_t i = 0; i < clips.size(); ++i) {
            const auto& a = ts.clips[i];
            const auto& b = clips[i];
            if (a.clip_id != b.clip_id ||
                a.timeline_start != b.timeline_start ||
                a.duration != b.duration ||
                a.source_in != b.source_in ||
                a.media_path != b.media_path ||
                a.rate_num != b.rate_num ||
                a.rate_den != b.rate_den ||
                a.speed_ratio != b.speed_ratio) {
                same = false;
                break;
            }
        }
        if (same) return;
    }

    // Clip list changed. Only evict cache entries for clips that were REMOVED.
    // Pre-buffered frames for clips still in the new list must survive —
    // the boundary crossing is exactly when we need them most.
    std::unordered_set<std::string> new_clip_ids;
    for (const auto& c : clips) {
        new_clip_ids.insert(c.clip_id);
    }

    for (auto it = ts.video_cache.begin(); it != ts.video_cache.end(); ) {
        if (new_clip_ids.find(it->second.clip_id) == new_clip_ids.end()) {
            it = ts.video_cache.erase(it);
        } else {
            ++it;
        }
    }

    for (auto it = ts.audio_cache.begin(); it != ts.audio_cache.end(); ) {
        if (new_clip_ids.find(it->clip_id) == new_clip_ids.end()) {
            it = ts.audio_cache.erase(it);
        } else {
            ++it;
        }
    }

    ts.clips = clips;
}

// ============================================================================
// Playhead
// ============================================================================

void TimelineMediaBuffer::SetPlayhead(int64_t frame, int direction, float speed) {
    int prev_direction = m_playhead_direction.load(std::memory_order_relaxed);
    m_playhead_frame.store(frame, std::memory_order_relaxed);
    m_playhead_direction.store(direction, std::memory_order_relaxed);
    m_playhead_speed.store(speed, std::memory_order_relaxed);

    // Wake mix thread on play start (0→nonzero) or direction flip
    if (direction != 0 && (prev_direction == 0 || prev_direction != direction)) {
        m_mix_cv.notify_one();
    }

    // Restart prefetch on play start (0→nonzero). ParkReaders() stopped all
    // prefetch threads; re-enable them now that playback is resuming.
    // Only video-track readers need prefetch (video frame decode-ahead).
    // Audio-track readers don't benefit from video prefetch threads.
    if (direction != 0 && prev_direction == 0) {
        std::vector<std::shared_ptr<Reader>> readers;
        {
            std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
            readers.reserve(m_readers.size());
            for (auto& [key, entry] : m_readers) {
                if (key.first.type == TrackType::Video) {
                    readers.push_back(entry.reader);
                }
            }
        }
        for (auto& reader : readers) {
            reader->StartPrefetch(direction);
        }
    }

    // Phase 1: evaluate tracks, update current reader targets, submit pre-buffer.
    // Collect active reader keys (current + next clip per track) for Phase 2.
    using ReaderKey = std::pair<TrackId, std::string>;
    std::vector<ReaderKey> active_keys;

    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        for (auto& [track, ts] : m_tracks) {
            const ClipInfo* current = find_clip_at(ts, frame);
            if (!current) continue;

            active_keys.push_back({track, current->clip_id});

            // Update Reader prefetch target for the current clip so its background
            // decoder stays ahead of the playhead (prevents main-thread cache stalls).
            {
                int64_t source_frame = current->source_in + (frame - current->timeline_start);
                auto key = std::make_pair(track, current->clip_id);
                std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
                auto it = m_readers.find(key);
                if (it != m_readers.end()) {
                    int64_t file_frame = source_frame - it->second.media_file->info().start_tc;
                    TimeUS t_us = FrameTime::from_frame(file_frame, current->rate()).to_us();
                    it->second.reader->UpdatePrefetchTarget(t_us);
                }
            }

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
                    active_keys.push_back({track, next->clip_id});

                    // Video pre-buffer
                    int64_t entry_frame = (direction >= 0)
                        ? next->source_in
                        : next->source_in + next->duration - 1;
                    int64_t entry_tl_frame = (direction >= 0)
                        ? next->timeline_start
                        : next->timeline_end() - 1;

                    PreBufferJob video_job{};
                    video_job.type = PreBufferJob::VIDEO;
                    video_job.track = track;
                    video_job.clip_id = next->clip_id;
                    video_job.media_path = next->media_path;
                    video_job.source_frame = entry_frame;
                    video_job.timeline_frame = entry_tl_frame;
                    video_job.rate = next->rate();
                    video_job.direction = direction;
                    video_job.clip_duration = next->duration;
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
                            audio_job.track = track;
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
    } // m_tracks_mutex released

    // Phase 2: pause prefetch on idle readers, resume on active ones.
    // Only video readers have prefetch — audio readers skip StartPrefetch.
    // This limits concurrent VT decode sessions to current+next clips only.
    if (direction != 0) {
        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
        for (auto& [key, entry] : m_readers) {
            if (key.first.type != TrackType::Video) continue;

            bool is_active = false;
            for (const auto& ak : active_keys) {
                if (ak == key) { is_active = true; break; }
            }

            if (is_active) {
                entry.reader->ResumePrefetch(direction);
            } else {
                entry.reader->PausePrefetch();
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

VideoResult TimelineMediaBuffer::GetVideoFrame(TrackId track, int64_t timeline_frame) {
    VideoResult result{};
    result.frame = nullptr;
    result.offline = false;

    // Find track and clip
    std::unique_lock<std::mutex> tracks_lock(m_tracks_mutex);
    auto track_it = m_tracks.find(track);
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
    result.media_path = clip->media_path;
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
        result.rotation = cache_it->second.rotation;
        result.par_num = cache_it->second.par_num;
        result.par_den = cache_it->second.par_den;
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

    // Acquire reader and decode (TMB cache miss → Reader fallback)
    m_video_cache_misses.fetch_add(1, std::memory_order_relaxed);
    auto reader = acquire_reader(track, clip_id, media_path);
    if (!reader) {
        result.offline = true;
        return result;
    }

    // Get media file info for start_tc, rotation, and PAR
    const auto& info = reader->media_file()->info();
    result.rotation = info.rotation;
    result.par_num = info.video_par_num;
    result.par_den = info.video_par_den;

    // Subtract start_tc to get file-relative frame
    int64_t file_frame = source_frame - info.start_tc;

    // Decode at file-relative frame using clip rate
    FrameTime ft = FrameTime::from_frame(file_frame, clip_rate);
    auto decode_result = reader->DecodeAt(ft);

    if (decode_result.is_ok()) {
        result.frame = decode_result.value();

        // Cache the decoded frame (including metadata for cache-hit path)
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track);
        if (tit != m_tracks.end()) {
            auto& cache = tit->second.video_cache;

            // Evict oldest if at capacity
            while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                cache.erase(cache.begin());
            }

            cache[timeline_frame] = {clip_id, source_frame, result.frame,
                                     result.rotation, result.par_num, result.par_den};
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

    // NSF-ACCEPT: nullptr returns below are legitimate edge cases — decoder may
    // return less audio than requested (e.g. near EOF). Callers treat nullptr as
    // "no audio available" (gap/silence), same as no-clip-at-position.

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

    // NSF-ACCEPT: Entries that don't fully cover [seg_t0, seg_t1) are skipped
    // (partial cache coverage = cache miss). Falls through to on-demand decode.
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
        TrackId track, TimeUS t0, TimeUS t1, const AudioFormat& fmt) {
    assert(t1 > t0 && "GetTrackAudio: t1 must be greater than t0");
    assert(m_seq_rate.num > 0 && "GetTrackAudio: SetSequenceRate not called");

    // Find track
    std::unique_lock<std::mutex> tracks_lock(m_tracks_mutex);
    auto track_it = m_tracks.find(track);
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
        auto reader = acquire_reader(track, clip_id, media_path);
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
        auto tit = m_tracks.find(track);
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

        // NSF-ACCEPT: Offline/decode failures in boundary spanning produce silence
        // gaps — correct behavior. Lua's audio pipeline zero-fills gaps. The first
        // clip's audio is still returned; only subsequent clips degrade gracefully.
        {
            std::lock_guard<std::mutex> plock(m_pool_mutex);
            if (m_offline.count(next_path)) { cursor = next_end_us; continue; }
        }

        auto next_reader = acquire_reader(track, next_clip_id, next_path);
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
        assert(seg.pcm && "GetTrackAudio: segment has null pcm");
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
// Autonomous pre-mixed audio: MixedAudioCache
// ============================================================================

bool TimelineMediaBuffer::MixedAudioCache::covers(TimeUS t0, TimeUS t1) const {
    return !data.empty() && start_us <= t0 && end_us >= t1;
}

std::shared_ptr<PcmChunk> TimelineMediaBuffer::MixedAudioCache::extract(
        TimeUS t0, TimeUS t1) const {
    assert(!data.empty() && "MixedAudioCache::extract: cache is empty");
    assert(sample_rate > 0 && channels > 0 && "MixedAudioCache::extract: invalid format");
    assert(t0 >= start_us && t1 <= end_us && "MixedAudioCache::extract: range not covered");

    int64_t total_frames = static_cast<int64_t>(data.size()) / channels;
    int64_t skip = ((t0 - start_us) * sample_rate) / 1000000;
    int64_t want = ((t1 - t0) * sample_rate) / 1000000;
    if (skip < 0) skip = 0;
    if (skip + want > total_frames) want = total_frames - skip;
    if (want <= 0) return nullptr;

    std::vector<float> out(want * channels);
    std::copy(data.data() + skip * channels,
              data.data() + (skip + want) * channels,
              out.data());
    auto impl = std::make_unique<PcmChunkImpl>(
        sample_rate, channels, SampleFormat::F32, t0, std::move(out));
    return std::make_shared<PcmChunk>(std::move(impl));
}

void TimelineMediaBuffer::MixedAudioCache::append(
        const std::shared_ptr<PcmChunk>& chunk, int dir) {
    assert(chunk && chunk->frames() > 0 && "MixedAudioCache::append: null/empty chunk");

    const float* src = chunk->data_f32();
    int64_t n = chunk->frames() * channels;
    TimeUS chunk_end = chunk->start_time_us() +
        (chunk->frames() * 1000000LL) / sample_rate;

    if (data.empty()) {
        start_us = chunk->start_time_us();
        end_us = chunk_end;
        data.assign(src, src + n);
        direction = dir;
        return;
    }

    if (dir > 0) {
        // Forward: append to end
        data.insert(data.end(), src, src + n);
        end_us = chunk_end;
    } else {
        // Reverse: prepend to start
        data.insert(data.begin(), src, src + n);
        start_us = chunk->start_time_us();
    }
}

void TimelineMediaBuffer::MixedAudioCache::evict_behind(TimeUS playhead_us, int dir) {
    if (data.empty() || sample_rate <= 0 || channels <= 0) return;

    constexpr TimeUS KEEP_BEHIND_US = 500000; // 0.5s margin behind playhead

    if (dir > 0) {
        TimeUS evict_before = playhead_us - KEEP_BEHIND_US;
        if (evict_before <= start_us) return;
        int64_t evict_frames = ((evict_before - start_us) * sample_rate) / 1000000;
        if (evict_frames <= 0) return;
        int64_t total = static_cast<int64_t>(data.size()) / channels;
        if (evict_frames >= total) { clear(); return; }
        data.erase(data.begin(), data.begin() + evict_frames * channels);
        start_us = evict_before;
    } else {
        TimeUS evict_after = playhead_us + KEEP_BEHIND_US;
        if (evict_after >= end_us) return;
        int64_t total = static_cast<int64_t>(data.size()) / channels;
        int64_t keep_frames = ((evict_after - start_us) * sample_rate) / 1000000;
        if (keep_frames <= 0) { clear(); return; }
        if (keep_frames >= total) return;
        data.resize(keep_frames * channels);
        end_us = evict_after;
    }
}

void TimelineMediaBuffer::MixedAudioCache::clear() {
    data.clear();
    start_us = end_us = 0;
    direction = 0;
}

// ============================================================================
// SetAudioMixParams
// ============================================================================

void TimelineMediaBuffer::SetAudioMixParams(
        const std::vector<MixTrackParam>& params, const AudioFormat& fmt) {
    assert(fmt.sample_rate > 0 && "SetAudioMixParams: sample_rate must be positive");
    assert(fmt.channels > 0 && "SetAudioMixParams: channels must be positive");

    {
        std::lock_guard<std::mutex> lock(m_mix_mutex);
        m_audio_mix_params = params;
        m_audio_mix_fmt = fmt;
        m_mixed_cache.clear();
        m_mixed_cache.sample_rate = fmt.sample_rate;
        m_mixed_cache.channels = fmt.channels;
        m_mix_params_changed = true;
    }
    m_mix_cv.notify_one();
}

// ============================================================================
// GetMixedAudio — cache read + sync fallback
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::GetMixedAudio(TimeUS t0, TimeUS t1) {
    assert(t1 > t0 && "GetMixedAudio: t1 must be greater than t0");

    std::unique_lock<std::mutex> lock(m_mix_mutex);
    if (m_audio_mix_params.empty()) return nullptr;

    // Cache hit
    if (m_mixed_cache.covers(t0, t1)) {
        return m_mixed_cache.extract(t0, t1);
    }

    // Sync fallback (startup/seek — cache cold)
    auto params = m_audio_mix_params;
    auto fmt = m_audio_mix_fmt;
    lock.unlock();

    return execute_mix_range(params, fmt, t0, t1);
}

// ============================================================================
// execute_mix_range — per-track decode + volume-weighted sum
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::execute_mix_range(
        const std::vector<MixTrackParam>& params,
        const AudioFormat& fmt, TimeUS t0, TimeUS t1) {

    assert(t1 > t0 && "execute_mix_range: inverted range");
    assert(fmt.sample_rate > 0 && fmt.channels > 0 && "execute_mix_range: invalid format");

    const int32_t sr = fmt.sample_rate;
    const int32_t ch = fmt.channels;
    int64_t out_frames = ((t1 - t0) * sr) / 1000000;
    if (out_frames <= 0) return nullptr;

    std::vector<float> mix_buf;
    bool has_audio = false;
    TimeUS actual_start = t0;

    for (const auto& param : params) {
        if (param.volume <= 0.0f) continue;

        TrackId track{TrackType::Audio, param.track_index};
        auto pcm = GetTrackAudio(track, t0, t1, fmt);
        if (!pcm || pcm->frames() == 0) continue;

        const float* src = pcm->data_f32();
        int64_t src_frames = pcm->frames();
        float vol = param.volume;

        if (!has_audio) {
            // First track: allocate and copy scaled
            mix_buf.resize(out_frames * ch, 0.0f);
            actual_start = pcm->start_time_us();
            int64_t copy_frames = std::min(src_frames, out_frames);
            int64_t n = copy_frames * ch;
            if (std::abs(vol - 1.0f) < 0.001f) {
                std::copy(src, src + n, mix_buf.data());
            } else {
                for (int64_t i = 0; i < n; ++i) {
                    mix_buf[i] = src[i] * vol;
                }
            }
            has_audio = true;
        } else {
            // Subsequent tracks: accumulate
            int64_t n = std::min(src_frames, out_frames) * ch;
            for (int64_t i = 0; i < n; ++i) {
                mix_buf[i] += src[i] * vol;
            }
        }
    }

    if (!has_audio) return nullptr;

    auto impl = std::make_unique<PcmChunkImpl>(
        sr, ch, fmt.fmt, actual_start, std::move(mix_buf));
    return std::make_shared<PcmChunk>(std::move(impl));
}

// ============================================================================
// Mix thread — autonomous pre-mixing
// ============================================================================

static constexpr emp::TimeUS MIX_LOOKAHEAD_US = 2000000;  // 2s ahead
static constexpr emp::TimeUS MIX_CHUNK_US = 200000;       // 200ms per chunk

void TimelineMediaBuffer::start_mix_thread() {
    m_mix_shutdown.store(false);
    m_mix_thread = std::thread(&TimelineMediaBuffer::mix_thread_loop, this);
}

void TimelineMediaBuffer::stop_mix_thread() {
    m_mix_shutdown.store(true);
    m_mix_cv.notify_one();
    if (m_mix_thread.joinable()) {
        m_mix_thread.join();
    }
}

void TimelineMediaBuffer::mix_thread_loop() {
    while (true) {
        // Wait for work: params change, direction change, or 50ms poll
        {
            std::unique_lock<std::mutex> lock(m_mix_mutex);
            m_mix_cv.wait_for(lock, std::chrono::milliseconds(50), [this] {
                return m_mix_shutdown.load() || m_mix_params_changed;
            });

            if (m_mix_shutdown.load()) break;
            m_mix_params_changed = false;
        }

        // Check preconditions (atomics, no lock needed)
        int direction = m_playhead_direction.load(std::memory_order_relaxed);
        if (direction == 0) continue;

        Rate seq_rate = m_seq_rate; // struct copy, written once before playback
        if (seq_rate.num <= 0) continue;

        // Read mix params under lock
        std::vector<MixTrackParam> params;
        AudioFormat fmt{SampleFormat::F32, 0, 0};
        {
            std::lock_guard<std::mutex> lock(m_mix_mutex);
            if (m_audio_mix_params.empty()) continue;
            params = m_audio_mix_params;
            fmt = m_audio_mix_fmt;
        }

        if (fmt.sample_rate <= 0) continue;

        // Compute playhead position in us
        int64_t ph_frame = m_playhead_frame.load(std::memory_order_relaxed);
        TimeUS playhead_us = FrameTime::from_frame(ph_frame, seq_rate).to_us();

        // Determine target range
        TimeUS target_start, target_end;
        if (direction > 0) {
            target_start = playhead_us;
            target_end = playhead_us + MIX_LOOKAHEAD_US;
        } else {
            target_start = std::max(static_cast<TimeUS>(0), playhead_us - MIX_LOOKAHEAD_US);
            target_end = playhead_us;
        }

        // Check cache state and compute chunk to mix
        TimeUS chunk_t0, chunk_t1;
        {
            std::lock_guard<std::mutex> lock(m_mix_mutex);

            // Direction flip → invalidate cache
            if (m_mixed_cache.direction != 0 && m_mixed_cache.direction != direction) {
                m_mixed_cache.clear();
                m_mixed_cache.sample_rate = fmt.sample_rate;
                m_mixed_cache.channels = fmt.channels;
            }

            if (direction > 0) {
                TimeUS cache_end = m_mixed_cache.data.empty()
                    ? playhead_us : m_mixed_cache.end_us;
                if (cache_end >= target_end) continue; // already far enough ahead
                chunk_t0 = cache_end;
                chunk_t1 = std::min(chunk_t0 + MIX_CHUNK_US, target_end);
            } else {
                TimeUS cache_start = m_mixed_cache.data.empty()
                    ? playhead_us : m_mixed_cache.start_us;
                if (cache_start <= target_start) continue;
                chunk_t1 = cache_start;
                chunk_t0 = std::max(chunk_t1 - MIX_CHUNK_US, target_start);
            }
        }

        if (chunk_t1 <= chunk_t0) continue;

        // Mix this chunk (no locks held — calls GetTrackAudio internally)
        auto pcm = execute_mix_range(params, fmt, chunk_t0, chunk_t1);

        if (pcm && pcm->frames() > 0) {
            std::lock_guard<std::mutex> lock(m_mix_mutex);
            m_mixed_cache.append(pcm, direction);
            m_mixed_cache.evict_behind(playhead_us, direction);
        }
    }
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
// ParkReaders — stop all background decode work
// ============================================================================

void TimelineMediaBuffer::ParkReaders() {
    // 1. Stop playhead direction (idles mix thread)
    m_playhead_direction.store(0, std::memory_order_relaxed);

    // 2. Clear pending pre-buffer jobs and in-flight tracking
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        m_jobs.clear();
        m_pre_buffering.clear();
    }

    // 3. Collect reader shared_ptrs under pool lock
    std::vector<std::shared_ptr<Reader>> readers;
    {
        std::lock_guard<std::mutex> lock(m_pool_mutex);
        readers.reserve(m_readers.size());
        for (auto& [key, entry] : m_readers) {
            readers.push_back(entry.reader);
        }
    }

    // 4. Signal all threads first (non-blocking), then join all.
    //    Parallel exit resolves HW decoder contention → fast join.
    for (auto& reader : readers) {
        reader->SignalPrefetchStop();
    }
    for (auto& reader : readers) {
        reader->JoinPrefetch();
    }
}

// ============================================================================
// Lifecycle
// ============================================================================

void TimelineMediaBuffer::ReleaseTrack(TrackId track) {
    // Remove track state
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        m_tracks.erase(track);
    }

    // Release readers for this track
    std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
    for (auto it = m_readers.begin(); it != m_readers.end(); ) {
        if (it->first.first == track) {
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
    {
        std::lock_guard<std::mutex> lock(m_mix_mutex);
        m_mixed_cache.clear();
    }
}

// ============================================================================
// Reader pool — LRU with per-(track, path) isolation
// ============================================================================

TimelineMediaBuffer::ReaderHandle TimelineMediaBuffer::acquire_reader(
        TrackId track, const std::string& clip_id, const std::string& path) {

    std::shared_ptr<Reader> reader;
    std::shared_ptr<std::mutex> use_mtx;
    bool need_prefetch = false;

    // Phase 1 (under lock ~1us): pool lookup + offline check
    {
        std::lock_guard<std::mutex> lock(m_pool_mutex);
        if (m_offline.count(path)) return ReaderHandle{};

        auto key = std::make_pair(track, clip_id);
        auto it = m_readers.find(key);
        if (it != m_readers.end()) {
            it->second.last_used = ++m_pool_clock;
            reader = it->second.reader;
            use_mtx = it->second.use_mutex;
        }
    }

    if (reader) {
        return ReaderHandle{reader, std::unique_lock<std::mutex>(*use_mtx)};
    }

    // Phase 2 (NO lock ~86ms on external drives): MediaFile::Open + Reader::Create
    // NSF-ACCEPT: Failed opens register in m_offline to prevent repeated
    // open attempts on the same path. Callers (GetVideoFrame, GetTrackAudio)
    // check the empty ReaderHandle and return offline/nullptr to Lua.
    auto mf_result = MediaFile::Open(path);
    if (mf_result.is_error()) {
        std::lock_guard<std::mutex> lock(m_pool_mutex);
        m_offline[path] = mf_result.error();
        return ReaderHandle{};
    }
    auto mf = mf_result.value();

    auto reader_result = Reader::Create(mf);
    if (reader_result.is_error()) {
        std::lock_guard<std::mutex> lock(m_pool_mutex);
        m_offline[path] = reader_result.error();
        return ReaderHandle{};
    }

    auto new_reader = reader_result.value();
    // TMB manages its own caching and pre-buffer — force Play decode path
    // so the Reader uses batch decode (maintains codec position, prevents
    // Park→Play cache clears that cause h264 re-seeks at boundaries).
    new_reader->SetDecodeModeOverride(DecodeMode::Play);
    auto new_use_mtx = std::make_shared<std::mutex>();

    // Phase 3 (under lock ~1us): install into pool or discard if another thread raced
    {
        std::lock_guard<std::mutex> lock(m_pool_mutex);

        auto key = std::make_pair(track, clip_id);
        auto it = m_readers.find(key);
        if (it != m_readers.end()) {
            // Race: another thread installed this key — use theirs, discard ours.
            // ~Reader() calls StopPrefetch() which is no-op (never started).
            it->second.last_used = ++m_pool_clock;
            reader = it->second.reader;
            use_mtx = it->second.use_mutex;
        } else {
            // Re-check offline (may have been registered between Phase 1 and 3)
            if (m_offline.count(path)) return ReaderHandle{};

            while (static_cast<int>(m_readers.size()) >= m_max_readers) {
                evict_lru_reader();
            }
            m_readers[key] = PoolEntry{path, mf, new_reader, track, ++m_pool_clock, new_use_mtx};
            reader = new_reader;
            use_mtx = new_use_mtx;
            need_prefetch = true;
        }
    }

    // Phase 4 (NO lock): start prefetch for newly installed video readers.
    // Audio-track readers don't benefit from video prefetch threads.
    // ParkReaders() has stopped all decode work — don't restart when parked.
    if (need_prefetch) {
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0 && track.type == TrackType::Video) {
            reader->StartPrefetch(dir);
        }
    }

    return ReaderHandle{reader, std::unique_lock<std::mutex>(*use_mtx)};
}

void TimelineMediaBuffer::release_reader(TrackId track, const std::string& clip_id) {
    std::lock_guard<std::mutex> lock(m_pool_mutex);
    m_readers.erase(std::make_pair(track, clip_id));
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
        m_pre_buffering.clear();
    }
}

// Build dedup key from job fields: "V1:clip_id:0" or "A3:clip_id:1"
std::string TimelineMediaBuffer::job_key(const PreBufferJob& job) {
    char buf[8];
    snprintf(buf, sizeof(buf), "%c%d:",
             job.track.type == TrackType::Video ? 'V' : 'A',
             job.track.index);
    return std::string(buf) + job.clip_id + ":" + std::to_string(static_cast<int>(job.type));
}

void TimelineMediaBuffer::submit_pre_buffer(const PreBufferJob& job) {
    std::lock_guard<std::mutex> lock(m_jobs_mutex);

    auto key = job_key(job);

    // De-duplicate: skip if same job is queued OR currently being processed by a worker
    if (m_pre_buffering.count(key)) return;
    for (const auto& j : m_jobs) {
        if (j.track == job.track && j.clip_id == job.clip_id && j.type == job.type) {
            return;
        }
    }

    m_jobs.push_back(job);
    m_jobs_cv.notify_one();
}

void TimelineMediaBuffer::worker_loop() {
    while (!m_shutdown.load()) {
        PreBufferJob job;
        std::string key;
        {
            std::unique_lock<std::mutex> lock(m_jobs_mutex);
            m_jobs_cv.wait(lock, [this] {
                return m_shutdown.load() || !m_jobs.empty();
            });
            if (m_shutdown.load()) break;
            if (m_jobs.empty()) continue;

            job = std::move(m_jobs.back());
            m_jobs.pop_back();
            key = job_key(job);
            m_pre_buffering.insert(key);
        }

        // RAII: remove from in-flight set when job processing completes
        // (handles all exit paths: continue, break, fall-through)
        auto guard = make_scope_exit([this, &key] {
            std::lock_guard<std::mutex> lock(m_jobs_mutex);
            m_pre_buffering.erase(key);
        });

        // Acquire reader (may open a new one)
        auto reader = acquire_reader(job.track, job.clip_id, job.media_path);
        if (!reader) continue;

        if (job.type == PreBufferJob::VIDEO) {
            // Pre-decode enough frames so the main thread NEVER hits a slow h264
            // decode at the clip boundary. The first ~16 frames after a seek often
            // include "co located POCs unavailable" batches that take 100ms+.
            // 48 frames (2s at 24fps) covers this plus margin.
            constexpr int PRE_BUFFER_BATCH = 48;
            int n = static_cast<int>(std::min(
                static_cast<int64_t>(PRE_BUFFER_BATCH), job.clip_duration));
            if (n <= 0) continue;

            const auto& info = reader->media_file()->info();
            int rotation = info.rotation;
            int32_t par_num = info.video_par_num;
            int32_t par_den = info.video_par_den;

            // Always decode in forward source order (h264 requires forward decode).
            // Forward playback: entry is clip start, decode [entry .. entry+N).
            // Reverse playback: entry is clip end, decode [entry-N+1 .. entry].
            int64_t start_sf = (job.direction >= 0)
                ? job.source_frame
                : job.source_frame - (n - 1);
            int64_t start_tf = (job.direction >= 0)
                ? job.timeline_frame
                : job.timeline_frame - (n - 1);

            // Decode and store INCREMENTALLY: each frame is cached immediately
            // so the main thread's GetVideoFrame hits the TMB cache and never
            // blocks on the reader's use_mutex.
            int frames_decoded = 0;
            for (int i = 0; i < n; ++i) {
                // Bail early if playback stopped or parked (avoids wasted 300ms+ decode)
                if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0) break;

                int64_t sf = start_sf + i;
                int64_t tf = start_tf + i;
                int64_t file_frame = sf - info.start_tc;
                FrameTime ft = FrameTime::from_frame(file_frame, job.rate);
                auto result = reader->DecodeAt(ft);
                if (result.is_ok()) {
                    // Store to TMB cache immediately (lock is brief: pointer copy only)
                    std::lock_guard<std::mutex> lock(m_tracks_mutex);
                    auto it = m_tracks.find(job.track);
                    if (it != m_tracks.end()) {
                        auto& cache = it->second.video_cache;
                        while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                            cache.erase(cache.begin());
                        }
                        cache[tf] = {job.clip_id, sf, result.value(),
                                     rotation, par_num, par_den};
                    } else {
                        // Track removed while worker was decoding — frame no longer needed.
                        EMP_LOG_DEBUG("Pre-buffer: track %c%d removed mid-job, discarding frame %lld",
                                job.track.type == TrackType::Video ? 'V' : 'A',
                                job.track.index, static_cast<long long>(tf));
                    }
                    frames_decoded++;
                } else {
                    // NSF-ACCEPT: Decode failures stop the batch — pre-buffer is best-effort.
                    // Main thread's GetVideoFrame handles on-demand decode if pre-buffer missed.
                    // EOF is expected (short clips); other errors are logged for diagnostics.
                    EMP_LOG_WARN("Pre-buffer: DecodeAt failed at source frame %lld for clip %s: %s",
                            static_cast<long long>(sf), job.clip_id.c_str(),
                            result.error().message.c_str());
                    break;
                }
            }
            EMP_LOG_DEBUG("Pre-buffer: %d/%d frames for clip %s on track %c%d",
                    frames_decoded, n, job.clip_id.c_str(),
                    job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);
        } else {
            // Pre-decode audio PCM.
            // NSF-ACCEPT: Decode failures continue to next job — pre-buffer is
            // best-effort. Main-thread GetTrackAudio handles on-demand decode
            // if pre-buffer missed.
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
            auto it = m_tracks.find(job.track);
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
