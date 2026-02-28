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
    bool clips_changed = false;
    // Clips not in old list — need reader pre-warming during active playback
    std::vector<ClipInfo> clips_to_warm;
    {
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
        std::unordered_set<std::string> old_clip_ids;
        for (const auto& c : ts.clips) {
            old_clip_ids.insert(c.clip_id);
        }
        std::unordered_set<std::string> new_clip_ids;
        for (const auto& c : clips) {
            new_clip_ids.insert(c.clip_id);
            // Clip not in old list = needs reader pre-warming
            if (old_clip_ids.find(c.clip_id) == old_clip_ids.end()) {
                clips_to_warm.push_back(c);
            }
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

        // Clear EOF markers for removed clips (new clip list may have different durations)
        for (auto it = ts.clip_eof_frame.begin(); it != ts.clip_eof_frame.end(); ) {
            if (new_clip_ids.find(it->first) == new_clip_ids.end()) {
                it = ts.clip_eof_frame.erase(it);
            } else {
                ++it;
            }
        }

        ts.clips = clips;

        // Reset watermark buffer_end so REFILL re-evaluates from playhead.
        // Increment generation so stale in-flight REFILL aborts early.
        ts.video_buffer_end = -1;
        ts.audio_buffer_end = -1;
        ts.refill_generation++;
        clips_changed = true;
    }
    // tracks_lock released — submit REFILL if playback is active.
    // This replaces the old trigger_prebuffer_for_new_clips mechanism:
    // when Lua feeds new clips during playback, immediately begin filling
    // the buffer from the current playhead position.
    if (clips_changed) {
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0) {
            int64_t ph = m_playhead_frame.load(std::memory_order_relaxed);
            if (track.type == TrackType::Video) {
                submit_video_refill(track, ph, dir);
            } else if (m_seq_rate.num > 0 && m_audio_fmt.sample_rate > 0) {
                TimeUS ph_us = FrameTime::from_frame(ph, m_seq_rate).to_us();
                submit_audio_refill(track, ph_us, dir);
            }
            // Pre-warm readers for newly visible clips. NeedClips fires
            // 50-100 frames before boundary — ample time for async
            // MediaFile::Open + Reader::Create (~400ms for 4K VideoToolbox).
            for (const auto& c : clips_to_warm) {
                PreBufferJob warm;
                warm.type = PreBufferJob::READER_WARM;
                warm.track = track;
                warm.clip_id = c.clip_id;
                warm.media_path = c.media_path;
                submit_pre_buffer(warm);
            }
        }
    }
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

    // Direction change: reset watermark buffer_ends (buffer is invalid for new direction)
    if (direction != 0 && prev_direction != 0 && prev_direction != direction) {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        for (auto& [track, ts] : m_tracks) {
            ts.video_buffer_end = -1;
            ts.audio_buffer_end = -1;
        }
    }

    // Cold-start priming: on play start (0→nonzero), submit initial REFILL for each track
    if (direction != 0 && prev_direction == 0) {
        {
            std::lock_guard<std::mutex> lock(m_tracks_mutex);
            for (auto& [track, ts] : m_tracks) {
                ts.video_buffer_end = -1;
                ts.audio_buffer_end = -1;
            }
        }
        // Submit initial refills (no locks held — methods lock internally)
        std::vector<TrackId> tracks_to_prime;
        {
            std::lock_guard<std::mutex> lock(m_tracks_mutex);
            for (const auto& [track, ts] : m_tracks) {
                tracks_to_prime.push_back(track);
            }
        }
        for (const auto& track : tracks_to_prime) {
            if (track.type == TrackType::Video) {
                submit_video_refill(track, frame, direction);
            } else if (track.type == TrackType::Audio && m_seq_rate.num > 0 && m_audio_fmt.sample_rate > 0) {
                TimeUS playhead_us = FrameTime::from_frame(frame, m_seq_rate).to_us();
                submit_audio_refill(track, playhead_us, direction);
            }
        }
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

    // Update Reader prefetch targets and manage active/idle readers.
    // Watermark-driven REFILLs handle pre-buffer; this block only updates
    // prefetch targets and pauses idle readers.
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
            if (track.type == TrackType::Video) {
                int64_t source_frame = current->source_in +
                    static_cast<int64_t>((frame - current->timeline_start) * current->speed_ratio);
                auto key = std::make_pair(track, current->clip_id);
                std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
                auto it = m_readers.find(key);
                if (it != m_readers.end()) {
                    int64_t file_frame = source_frame - it->second.media_file->info().start_tc;
                    TimeUS t_us = FrameTime::from_frame(file_frame, current->rate()).to_us();
                    it->second.reader->UpdatePrefetchTarget(t_us);
                }
            }
        }
    }

    // Pause prefetch on idle readers, resume on active ones.
    // Only video readers have prefetch — audio readers skip StartPrefetch.
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

    // Compute source frame: source_in + (timeline_offset * speed_ratio)
    // speed_ratio < 1.0 = slow motion (fewer source frames than timeline frames)
    int64_t source_frame = clip->source_in +
        static_cast<int64_t>((timeline_frame - clip->timeline_start) * clip->speed_ratio);
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

        // Watermark check on cache hit during playback: trigger refill if buffer
        // is running low. Release tracks_lock before calling (locks internally).
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0) {
            tracks_lock.unlock();
            check_video_watermark(track, timeline_frame, dir);
        }
        return result;
    }

    // ── Cache miss: branch on Play vs Scrub/Park ──
    int direction = m_playhead_direction.load(std::memory_order_relaxed);

    if (direction != 0) {
        // ── Play mode: non-blocking. Return pending, submit async decode.
        // The caller (PlaybackController) decides what to display while waiting.
        // GPU surface retains its last frame — no stale-return needed here.

        // Copy clip locals under tracks_lock for job submission.
        // Use REMAINING frames (not total clip duration) to prevent the
        // batch from decoding past clip end into the next clip's region.
        std::string job_clip_id = clip->clip_id;
        std::string job_media_path = clip->media_path;
        Rate job_rate = clip->rate();
        int64_t remaining_frames = clip->timeline_end() - timeline_frame;
        float job_speed_ratio = clip->speed_ratio;
        int64_t job_source_in = clip->source_in;
        int64_t job_timeline_start = clip->timeline_start;

        // Check per-clip EOF: if a previous decode failed at or before this
        // source frame, don't submit another on-demand job (it will just fail).
        // Return gap (nullptr frame, not pending) so playback skips cleanly.
        auto eof_it = ts.clip_eof_frame.find(clip->clip_id);
        if (eof_it != ts.clip_eof_frame.end() && source_frame >= eof_it->second) {
            tracks_lock.unlock();
            // result.frame already nullptr, result.pending stays false
            return result;
        }

        // Release tracks_lock BEFORE acquiring pool_lock (lock ordering:
        // pool → tracks in worker, so main thread must not reverse it).
        tracks_lock.unlock();

        // Check offline registry — non-blocking (~1µs hashmap lookup).
        // Ensures Lua learns about offline clips during playback.
        {
            std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
            auto offline_it = m_offline.find(job_media_path);
            if (offline_it != m_offline.end()) {
                result.offline = true;
                result.error_msg = offline_it->second.message;
                result.frame = nullptr;
                return result;
            }
        }

        result.pending = true;
        // result.frame stays nullptr — caller holds current display
        // result.clip_id already set to CURRENT clip for transition detection

        // Watermark check on cache MISS too: during cold-start, every frame is
        // a miss. Without this, only cache HITs trigger refill. The 60Hz tick
        // loop calling GetVideoFrame would never trigger refill if the buffer
        // starts empty (no hits → no watermark check → no refill).
        check_video_watermark(track, timeline_frame, direction);

        // Submit async VIDEO decode job to worker pool
        PreBufferJob job{};
        job.type = PreBufferJob::VIDEO;
        job.track = track;
        job.clip_id = job_clip_id;
        job.media_path = job_media_path;
        job.source_frame = source_frame;
        job.timeline_frame = timeline_frame;
        job.rate = job_rate;
        job.direction = direction;
        job.clip_duration = remaining_frames;
        job.speed_ratio = job_speed_ratio;
        job.clip_source_in = job_source_in;
        job.clip_timeline_start = job_timeline_start;
        submit_pre_buffer(job);

        m_video_cache_misses.fetch_add(1, std::memory_order_relaxed);
        return result;
    }

    // ── Scrub/Park: synchronous decode ──

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
            result.error_msg = offline_it->second.message;
            return result;
        }
    }

    // Acquire reader and decode (TMB cache miss → Reader fallback)
    m_video_cache_misses.fetch_add(1, std::memory_order_relaxed);
    auto reader = acquire_reader(track, clip_id, media_path);
    if (!reader) {
        // acquire_reader registered the error in m_offline — fetch it
        result.offline = true;
        {
            std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
            auto err_it = m_offline.find(media_path);
            if (err_it != m_offline.end()) {
                result.error_msg = err_it->second.message;
            }
        }
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
    } else {
        // Decode failure: clip exists, reader opened, but frame can't be decoded
        // (corrupt media, unsupported codec, out-of-range seek). Must set offline
        // so the renderer shows the offline graphic, not skip to the next track.
        result.offline = true;
        result.error_msg = "Decode failed for " + media_path;
    }

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

    // Watermark check: trigger audio refill if buffer is running low.
    // Fires on both cache-hit and cache-miss (we want to stay ahead).
    int dir = m_playhead_direction.load(std::memory_order_relaxed);
    if (dir != 0) {
        check_audio_watermark(track, t0, dir);
    }

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
// Watermark-driven buffer management
// ============================================================================

void TimelineMediaBuffer::check_video_watermark(TrackId track, int64_t playhead, int direction) {
    if (direction == 0) return;

    bool needs_refill = false;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto it = m_tracks.find(track);
        if (it == m_tracks.end()) return;
        auto& ts = it->second;

        if (ts.video_buffer_end < 0) {
            ts.video_buffer_end = playhead;
        }

        int64_t buffered_ahead = (direction > 0)
            ? (ts.video_buffer_end - playhead)
            : (playhead - ts.video_buffer_end);

        needs_refill = (buffered_ahead < VIDEO_LOW_WATER);
    }

    if (needs_refill) {
        submit_video_refill(track, playhead, direction);
    }
}

void TimelineMediaBuffer::submit_video_refill(TrackId track, int64_t playhead, int direction) {
    int64_t buffer_end;
    int64_t gen;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto it = m_tracks.find(track);
        if (it == m_tracks.end()) return;
        auto& ts = it->second;

        if (ts.video_buffer_end < 0) {
            ts.video_buffer_end = playhead;
        }
        buffer_end = ts.video_buffer_end;
        gen = ts.refill_generation;
    }

    // Compute refill range: [buffer_end, buffer_end + REFILL_SIZE], clamped to HIGH_WATER
    int64_t refill_from, max_end;
    if (direction > 0) {
        refill_from = buffer_end;
        max_end = playhead + VIDEO_HIGH_WATER;
    } else {
        // Reverse: fill backwards from buffer_end
        max_end = buffer_end;
        refill_from = std::max(playhead - VIDEO_HIGH_WATER, static_cast<int64_t>(0));
    }

    int refill_count;
    if (direction > 0) {
        refill_count = static_cast<int>(std::min(
            static_cast<int64_t>(VIDEO_REFILL_SIZE), max_end - refill_from));
    } else {
        refill_count = static_cast<int>(std::min(
            static_cast<int64_t>(VIDEO_REFILL_SIZE), max_end - refill_from));
        refill_from = max_end - refill_count;
    }
    if (refill_count <= 0) return;

    PreBufferJob job{};
    job.type = PreBufferJob::VIDEO_REFILL;
    job.track = track;
    job.direction = direction;
    job.refill_from_frame = refill_from;
    job.refill_count = refill_count;
    job.generation = gen;
    submit_pre_buffer(job);
}

void TimelineMediaBuffer::check_audio_watermark(TrackId track, TimeUS playhead_us, int direction) {
    if (direction == 0) return;
    if (m_seq_rate.num <= 0 || m_audio_fmt.sample_rate <= 0) return;

    bool needs_refill = false;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto it = m_tracks.find(track);
        if (it == m_tracks.end()) return;
        auto& ts = it->second;

        if (ts.audio_buffer_end < 0) {
            ts.audio_buffer_end = playhead_us;
        }

        TimeUS buffered_ahead = (direction > 0)
            ? (ts.audio_buffer_end - playhead_us)
            : (playhead_us - ts.audio_buffer_end);

        needs_refill = (buffered_ahead < AUDIO_LOW_WATER);
    }

    if (needs_refill) {
        submit_audio_refill(track, playhead_us, direction);
    }
}

void TimelineMediaBuffer::submit_audio_refill(TrackId track, TimeUS playhead_us, int direction) {
    TimeUS buffer_end;
    int64_t gen;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto it = m_tracks.find(track);
        if (it == m_tracks.end()) return;
        auto& ts = it->second;

        if (ts.audio_buffer_end < 0) {
            ts.audio_buffer_end = playhead_us;
        }
        buffer_end = ts.audio_buffer_end;
        gen = ts.refill_generation;
    }

    TimeUS refill_from, refill_to;
    if (direction > 0) {
        refill_from = buffer_end;
        TimeUS max_end = playhead_us + AUDIO_HIGH_WATER;
        refill_to = std::min(refill_from + AUDIO_REFILL_SIZE, max_end);
    } else {
        refill_to = buffer_end;
        TimeUS min_start = std::max(playhead_us - AUDIO_HIGH_WATER, static_cast<TimeUS>(0));
        refill_from = std::max(refill_to - AUDIO_REFILL_SIZE, min_start);
    }
    if (refill_to <= refill_from) return;

    PreBufferJob job{};
    job.type = PreBufferJob::AUDIO_REFILL;
    job.track = track;
    job.direction = direction;
    job.refill_from_us = refill_from;
    job.refill_to_us = refill_to;
    job.generation = gen;
    submit_pre_buffer(job);
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

    // 2b. Reset watermark buffer_ends and per-clip EOF markers.
    // EOF markers must be cleared: they're an optimization to avoid repeated
    // decode attempts WITHIN a play session. Across sessions (stop → seek →
    // play), the playhead may be at a decodable position — stale EOF markers
    // would block GetVideoFrame's Play path (source_frame >= eof check).
    // REFILL re-discovers the actual EOF boundary during the new session.
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        for (auto& [track, ts] : m_tracks) {
            ts.video_buffer_end = -1;
            ts.audio_buffer_end = -1;
            ts.clip_eof_frame.clear();
        }
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

// Build dedup key from job fields.
// Legacy per-clip jobs: "V1:clip_id:0" or "A3:clip_id:1"
// REFILL jobs: "V1:REFILL:2" or "A3:REFILL:3" (keyed by track+type, not clip)
// READER_WARM jobs: "V1:WARM:clip_id" (keyed by track+clip, one warm per clip)
std::string TimelineMediaBuffer::job_key(const PreBufferJob& job) {
    char buf[8];
    snprintf(buf, sizeof(buf), "%c%d:",
             job.track.type == TrackType::Video ? 'V' : 'A',
             job.track.index);
    if (job.type == PreBufferJob::VIDEO_REFILL || job.type == PreBufferJob::AUDIO_REFILL) {
        return std::string(buf) + "REFILL:" + std::to_string(static_cast<int>(job.type));
    }
    if (job.type == PreBufferJob::READER_WARM) {
        return std::string(buf) + "WARM:" + job.clip_id;
    }
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

        if (job.type == PreBufferJob::VIDEO_REFILL) {
            // ── Watermark-driven video refill: iterate timeline frames, acquire
            // readers per-clip, skip gaps. One batch spans clip boundaries.
            //
            // Hold the reader across consecutive frames in the same clip to
            // avoid use_mutex contention with Reader's prefetch thread.
            int frames_decoded = 0;
            std::string held_clip_id;
            ReaderHandle held_reader;
            std::shared_ptr<Frame> last_good_frame;     // for hold-on-EOF
            int64_t last_good_source_frame = 0;

            for (int i = 0; i < job.refill_count; ++i) {
                if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0) break;

                int64_t tf = job.refill_from_frame + i;

                // Find clip at this timeline frame (copy fields under tracks_lock)
                std::string clip_id, media_path;
                int64_t source_in = 0, timeline_start = 0, clip_duration = 0;
                int32_t rate_num = 0, rate_den = 1;
                float speed_ratio = 1.0f;
                bool is_gap = false;
                {
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit == m_tracks.end()) break;
                    // Stale REFILL: SetTrackClips advanced generation — abort so
                    // the new REFILL (with fresh clip list) can run promptly.
                    if (tit->second.refill_generation != job.generation) break;
                    const ClipInfo* clip = find_clip_at(tit->second, tf);
                    if (!clip) {
                        // Gap: advance buffer_end past it, continue to next frame
                        if (tf + 1 > tit->second.video_buffer_end) {
                            tit->second.video_buffer_end = tf + 1;
                        }
                        is_gap = true;
                    } else {
                        clip_id = clip->clip_id;
                        media_path = clip->media_path;
                        source_in = clip->source_in;
                        timeline_start = clip->timeline_start;
                        clip_duration = clip->duration;
                        rate_num = clip->rate_num;
                        rate_den = clip->rate_den;
                        speed_ratio = clip->speed_ratio;
                    }
                }
                if (is_gap) {
                    // Release held reader on gap (clip boundary)
                    held_reader = {};
                    held_clip_id.clear();
                    continue;
                }

                // Acquire reader only when clip changes (boundary crossing)
                if (clip_id != held_clip_id || !held_reader) {
                    held_reader = {};  // release old reader first
                    held_reader = acquire_reader(job.track, clip_id, media_path);
                    if (!held_reader) continue;
                    held_clip_id = clip_id;
                }

                assert(rate_num > 0 && "worker_loop VIDEO_REFILL: clip has zero rate_num");
                assert(rate_den > 0 && "worker_loop VIDEO_REFILL: clip has zero rate_den");
                assert(speed_ratio > 0.0f && "worker_loop VIDEO_REFILL: clip has non-positive speed_ratio");
                int64_t source_frame = source_in +
                    static_cast<int64_t>((tf - timeline_start) * speed_ratio);
                const auto& info = held_reader->media_file()->info();
                int64_t file_frame = source_frame - info.start_tc;
                Rate clip_rate{rate_num, rate_den};
                FrameTime ft = FrameTime::from_frame(file_frame, clip_rate);

                auto result = held_reader->DecodeAt(ft);
                if (result.is_ok()) {
                    last_good_frame = result.value();
                    last_good_source_frame = source_frame;
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit != m_tracks.end()) {
                        auto& cache = tit->second.video_cache;
                        while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                            cache.erase(cache.begin());
                        }
                        cache[tf] = {clip_id, source_frame, result.value(),
                                     info.rotation, info.video_par_num, info.video_par_den};
                        // Use max() to avoid regressing watermark when on-demand
                        // has already advanced it past this REFILL's range.
                        if (tf + 1 > tit->second.video_buffer_end) {
                            tit->second.video_buffer_end = tf + 1;
                        }
                    }
                    frames_decoded++;
                } else {
                    // Decode failed. Only record EOF marker for actual EOF —
                    // transient errors (codec glitch, seek failure) must not
                    // permanently poison the clip's decodability.
                    bool is_eof = (result.error().code == ErrorCode::EOFReached);
                    EMP_LOG_WARN("REFILL: %s at tf=%lld sf=%lld clip=%s — "
                            "%s for %lld remaining",
                            is_eof ? "EOF" : "decode error",
                            static_cast<long long>(tf), static_cast<long long>(source_frame),
                            clip_id.c_str(),
                            is_eof ? "holding last frame" : "stopping batch",
                            static_cast<long long>(timeline_start + clip_duration - tf));

                    if (is_eof) {
                        // EOF: clip duration overstates decodable range (common
                        // with DRP retimed clips). Hold last frame for remaining
                        // timeline frames (matches Resolve behavior).
                        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                        auto tit = m_tracks.find(job.track);
                        if (tit != m_tracks.end()) {
                            int64_t clip_end = timeline_start + clip_duration;
                            // Record EOF marker (within this play session only —
                            // ParkReaders clears all markers on stop).
                            auto& eof = tit->second.clip_eof_frame;
                            auto eof_it = eof.find(clip_id);
                            if (eof_it == eof.end() || source_frame < eof_it->second) {
                                eof[clip_id] = source_frame;
                            }
                            // Fill remaining frames with last good frame.
                            // Store each fill_tf's own computed source_frame so
                            // GetVideoFrame's cache check (source_frame match) hits.
                            if (last_good_frame) {
                                auto& cache = tit->second.video_cache;
                                for (int64_t fill_tf = tf; fill_tf < clip_end; ++fill_tf) {
                                    if (cache.size() >= TrackState::MAX_VIDEO_CACHE) break;
                                    int64_t fill_sf = source_in +
                                        static_cast<int64_t>((fill_tf - timeline_start) * speed_ratio);
                                    cache[fill_tf] = {clip_id, fill_sf,
                                                      last_good_frame, info.rotation,
                                                      info.video_par_num, info.video_par_den};
                                }
                            }
                            if (clip_end > tit->second.video_buffer_end) {
                                tit->second.video_buffer_end = clip_end;
                            }
                        }
                    }
                    // Both EOF and transient errors: stop this REFILL batch.
                    // For transient errors, the next REFILL cycle will retry.
                    break;
                }
            }
            EMP_LOG_DEBUG("REFILL: %d/%d video frames on track %c%d",
                    frames_decoded, job.refill_count,
                    job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);

        } else if (job.type == PreBufferJob::AUDIO_REFILL) {
            // ── Watermark-driven audio refill: decode chunks spanning clip boundaries.
            assert(job.refill_to_us > job.refill_from_us && "worker_loop: AUDIO_REFILL has inverted range");
            assert(m_seq_rate.num > 0 && "worker_loop: AUDIO_REFILL requires SetSequenceRate");

            TimeUS cursor = job.refill_from_us;
            while (cursor < job.refill_to_us) {
                if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0) break;

                // Find clip at cursor (copy fields under tracks_lock)
                std::string clip_id, media_path;
                TimeUS clip_start_us = 0, clip_end_us = 0;
                int64_t source_in = 0;
                int32_t rate_num = 0, rate_den = 1;
                float speed_ratio = 1.0f;
                bool found = false;
                {
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit == m_tracks.end()) break;
                    if (tit->second.refill_generation != job.generation) break;
                    const ClipInfo* clip = find_clip_at_us(tit->second, cursor);
                    if (!clip) {
                        // Gap: find next clip to skip past it
                        const ClipInfo* next = find_next_clip_at_us(tit->second, cursor);
                        if (next) {
                            TimeUS next_start = FrameTime::from_frame(next->timeline_start, m_seq_rate).to_us();
                            tit->second.audio_buffer_end = next_start;
                            cursor = next_start;
                        } else {
                            // No more clips — advance buffer_end to refill end
                            tit->second.audio_buffer_end = job.refill_to_us;
                            break;
                        }
                        continue;
                    }
                    clip_id = clip->clip_id;
                    media_path = clip->media_path;
                    source_in = clip->source_in;
                    rate_num = clip->rate_num;
                    rate_den = clip->rate_den;
                    speed_ratio = clip->speed_ratio;
                    clip_start_us = FrameTime::from_frame(clip->timeline_start, m_seq_rate).to_us();
                    clip_end_us = FrameTime::from_frame(clip->timeline_end(), m_seq_rate).to_us();
                    found = true;
                }
                if (!found) break;

                // Compute chunk range clamped to clip and refill bounds
                TimeUS chunk_t0 = cursor;
                TimeUS chunk_t1 = std::min({clip_end_us, job.refill_to_us,
                                            cursor + AUDIO_REFILL_SIZE});
                if (chunk_t1 <= chunk_t0) { cursor = clip_end_us; continue; }

                // Map to source coordinates
                assert(rate_num > 0 && "worker_loop AUDIO_REFILL: clip has zero rate_num");
                assert(rate_den > 0 && "worker_loop AUDIO_REFILL: clip has zero rate_den");
                assert(speed_ratio > 0.0f && "worker_loop AUDIO_REFILL: clip has non-positive speed_ratio");
                TimeUS src_origin = FrameTime::from_frame(source_in, Rate{rate_num, rate_den}).to_us();
                double sr = static_cast<double>(speed_ratio);
                TimeUS src_t0 = src_origin + static_cast<int64_t>((chunk_t0 - clip_start_us) * sr);
                TimeUS src_t1 = src_origin + static_cast<int64_t>((chunk_t1 - clip_start_us) * sr);

                // Acquire reader and decode (no locks held)
                auto reader = acquire_reader(job.track, clip_id, media_path);
                if (!reader) { cursor = clip_end_us; continue; }

                auto decode_result = reader->DecodeAudioRangeUS(src_t0, src_t1, m_audio_fmt);
                if (decode_result.is_error() || !decode_result.value() || decode_result.value()->frames() == 0) {
                    cursor = clip_end_us;
                    continue;
                }

                auto pcm = build_audio_output(decode_result.value(), src_t0, src_t1,
                                              chunk_t0, chunk_t1, speed_ratio, m_audio_fmt);
                if (pcm && pcm->frames() > 0) {
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit != m_tracks.end()) {
                        auto& cache = tit->second.audio_cache;
                        while (cache.size() >= TrackState::MAX_AUDIO_CACHE) {
                            cache.erase(cache.begin());
                        }
                        cache.push_back({clip_id, chunk_t0, chunk_t1, pcm});
                        tit->second.audio_buffer_end = chunk_t1;
                    }
                }
                cursor = chunk_t1;
            }

        } else if (job.type == PreBufferJob::READER_WARM) {
            // ── Reader pre-warming: create the reader (MediaFile::Open + Reader::Create)
            // asynchronously so it's in the pool before REFILL reaches this clip.
            // acquire_reader does the heavy work; we just drop the handle afterward.
            // The reader stays in the pool (keyed by track+clip_id), warm and ready.
            EMP_LOG_DEBUG("WARM: opening reader for clip %s on track %c%d",
                    job.clip_id.c_str(),
                    job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);
            auto handle = acquire_reader(job.track, job.clip_id, job.media_path);
            if (handle) {
                EMP_LOG_DEBUG("WARM: reader ready for clip %s", job.clip_id.c_str());
            } else {
                EMP_LOG_WARN("WARM: failed to open reader for clip %s path=%s",
                        job.clip_id.c_str(), job.media_path.c_str());
            }
            // handle destructor releases use_mutex — reader remains in pool

        } else if (job.type == PreBufferJob::VIDEO) {
            // ── On-demand single-clip video decode (safety net for cache misses
            // during Play mode — submitted by GetVideoFrame when cache is cold).
            // Batch size bounded by clip_duration, no cooperative yield needed
            // (REFILL handles bulk decode; this is a targeted catch-up).

            auto reader = acquire_reader(job.track, job.clip_id, job.media_path);
            if (!reader) continue;

            int n = static_cast<int>(std::min(
                static_cast<int64_t>(VIDEO_REFILL_SIZE), job.clip_duration));
            if (n <= 0) continue;

            const auto& info = reader->media_file()->info();
            int rotation = info.rotation;
            int32_t par_num = info.video_par_num;
            int32_t par_den = info.video_par_den;

            int64_t start_tf = (job.direction >= 0)
                ? job.timeline_frame
                : job.timeline_frame - (n - 1);

            int frames_decoded = 0;
            for (int i = 0; i < n; ++i) {
                if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0) break;

                int64_t tf = start_tf + i;
                // Per-frame source computation: speed_ratio maps timeline offset → source offset
                int64_t sf = job.clip_source_in +
                    static_cast<int64_t>((tf - job.clip_timeline_start) * job.speed_ratio);
                int64_t file_frame = sf - info.start_tc;
                FrameTime ft = FrameTime::from_frame(file_frame, job.rate);
                auto result = reader->DecodeAt(ft);
                if (result.is_ok()) {
                    std::lock_guard<std::mutex> lock(m_tracks_mutex);
                    auto it = m_tracks.find(job.track);
                    if (it != m_tracks.end()) {
                        auto& cache = it->second.video_cache;
                        while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                            cache.erase(cache.begin());
                        }
                        cache[tf] = {job.clip_id, sf, result.value(),
                                     rotation, par_num, par_den};
                        // Advance watermark so REFILL starts PAST on-demand's range.
                        // Without this, REFILL overlaps on-demand (same reader lock,
                        // same frame range → redundant decode + reader contention).
                        if (tf + 1 > it->second.video_buffer_end) {
                            it->second.video_buffer_end = tf + 1;
                        }
                    }
                    frames_decoded++;
                } else {
                    bool is_eof = (result.error().code == ErrorCode::EOFReached);
                    EMP_LOG_WARN("On-demand: %s at sf=%lld clip=%s: %s",
                            is_eof ? "EOF" : "decode error",
                            static_cast<long long>(sf), job.clip_id.c_str(),
                            result.error().message.c_str());
                    // Only record EOF marker for actual EOF — transient errors
                    // must not permanently block decodable frames.
                    if (is_eof) {
                        std::lock_guard<std::mutex> lock(m_tracks_mutex);
                        auto it = m_tracks.find(job.track);
                        if (it != m_tracks.end()) {
                            auto& eof = it->second.clip_eof_frame;
                            auto eof_it = eof.find(job.clip_id);
                            if (eof_it == eof.end() || sf < eof_it->second) {
                                eof[job.clip_id] = sf;
                            }
                        }
                    }
                    break;
                }
            }
            // Only log partial completions (EOF, shutdown, error) — full batches
            // are normal steady-state and generate excessive noise at DEBUG level.
            if (frames_decoded < n) {
                EMP_LOG_DEBUG("On-demand: %d/%d frames for clip %s on track %c%d",
                        frames_decoded, n, job.clip_id.c_str(),
                        job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);
            }
        }
        // AUDIO type jobs no longer submitted — watermark AUDIO_REFILL replaces them
    }
}

} // namespace emp
