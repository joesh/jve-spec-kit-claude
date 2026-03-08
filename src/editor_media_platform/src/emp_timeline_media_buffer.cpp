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

namespace {

// Reverse interleaved PCM samples in-place.
// For reverse clips: we decode the forward source range, then flip the audio.
static void reverse_interleaved(float* data, int64_t frames, int channels) {
    assert(data && "reverse_interleaved: data is null");
    assert(frames > 0 && "reverse_interleaved: frames must be positive");
    assert(channels > 0 && "reverse_interleaved: channels must be positive");
    for (int64_t i = 0; i < frames / 2; ++i) {
        int64_t j = frames - 1 - i;
        for (int ch = 0; ch < channels; ++ch)
            std::swap(data[i * channels + ch], data[j * channels + ch]);
    }
}

} // namespace

namespace emp {

// Format TrackId as "V1", "A2" etc. for log output
namespace {
const char* track_str(const TrackId& t, char* buf, size_t sz) {
    snprintf(buf, sz, "%c%d", t.type == TrackType::Video ? 'V' : 'A', t.index);
    return buf;
}
} // namespace

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

std::vector<int> TimelineMediaBuffer::GetVideoTrackIds() {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    std::vector<int> ids;
    for (const auto& [track_id, ts] : m_tracks) {
        if (track_id.type == TrackType::Video && !ts.clips.empty()) {
            ids.push_back(track_id.index);
        }
    }
    std::sort(ids.begin(), ids.end(), std::greater<int>());
    return ids;
}

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

        // WARM readers only during playback (dir!=0). At park time (app startup),
        // macOS VideoToolbox may not be fully initialized — WARM would create SW
        // readers that permanently occupy the pool slot, blocking HW decode.
        // waitForVideoCache() in Play() absorbs the cold-open cost at play start.
        if (dir != 0) {
            for (const auto& c : clips_to_warm) {
                PreBufferJob warm;
                warm.type = PreBufferJob::READER_WARM;
                warm.track = track;
                warm.clip_id = c.clip_id;
                warm.media_path = c.media_path;
                submit_pre_buffer(warm);
            }
            // Priority probe: submit DECODE_PROBE for un-probed video clips.
            // Runs before WARM/REFILL so predictive stride has data early.
            if (track.type == TrackType::Video) {
                std::vector<PreBufferJob> probes;
                {
                    std::lock_guard<std::mutex> plock(m_pool_mutex);
                    for (const auto& c : clips_to_warm) {
                        if (m_decode_ms.find(c.media_path) == m_decode_ms.end()) {
                            PreBufferJob probe;
                            probe.type = PreBufferJob::DECODE_PROBE;
                            probe.track = track;
                            probe.clip_id = c.clip_id;
                            probe.media_path = c.media_path;
                            probe.probe_source_in = c.source_in;
                            probe.probe_rate_num = c.rate_num;
                            probe.probe_rate_den = c.rate_den;
                            probes.push_back(std::move(probe));
                        }
                    }
                }
                for (const auto& p : probes) {
                    submit_pre_buffer(p);
                }
            }
        }
        if (dir != 0) {
            int64_t ph = m_playhead_frame.load(std::memory_order_relaxed);
            if (track.type == TrackType::Video) {
                submit_video_refill(track, ph, dir);
            } else if (m_seq_rate.num > 0 && m_audio_fmt.sample_rate > 0) {
                TimeUS ph_us = FrameTime::from_frame(ph, m_seq_rate).to_us();
                submit_audio_refill(track, ph_us, dir);
            }
        }
    }
}

void TimelineMediaBuffer::AddClips(TrackId track, std::vector<ClipInfo> clips) {
    if (clips.empty()) return;

    std::vector<ClipInfo> clips_to_warm;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto& ts = m_tracks[track];

        // Build set of existing clip_ids for dedup
        std::unordered_set<std::string> existing_ids;
        for (const auto& c : ts.clips) {
            existing_ids.insert(c.clip_id);
        }

        // Append genuinely new clips
        for (auto& c : clips) {
            if (existing_ids.find(c.clip_id) == existing_ids.end()) {
                existing_ids.insert(c.clip_id);
                clips_to_warm.push_back(c);
                ts.clips.push_back(std::move(c));
            }
        }

        if (clips_to_warm.empty()) return;  // all duplicates

        // Re-sort by timeline_start
        std::sort(ts.clips.begin(), ts.clips.end(),
            [](const ClipInfo& a, const ClipInfo& b) {
                return a.timeline_start < b.timeline_start;
            });
    }
    // New audio clips invalidate the mixed cache: the mix thread may have
    // already cached silence for ranges that now contain audio. Without
    // this, the pump reads stale silence from cache → beep never heard.
    if (track.type == TrackType::Audio) {
        std::lock_guard<std::mutex> lock(m_mix_mutex);
        m_mixed_cache.clear();
        m_mix_cv.notify_one();
    }

    // tracks_lock released — warm readers for new clips (only during playback).
    // Same VT rationale as SetTrackClips: at park time, VT may not be ready.
    int dir = m_playhead_direction.load(std::memory_order_relaxed);
    if (dir != 0) {
        for (const auto& c : clips_to_warm) {
            PreBufferJob warm;
            warm.type = PreBufferJob::READER_WARM;
            warm.track = track;
            warm.clip_id = c.clip_id;
            warm.media_path = c.media_path;
            submit_pre_buffer(warm);
        }
        // Priority probe for un-probed video clips.
        // Collect under m_pool_mutex, submit after releasing (lock ordering).
        if (track.type == TrackType::Video) {
            std::vector<PreBufferJob> probes;
            {
                std::lock_guard<std::mutex> plock(m_pool_mutex);
                for (const auto& c : clips_to_warm) {
                    if (m_decode_ms.find(c.media_path) == m_decode_ms.end()) {
                        PreBufferJob probe;
                        probe.type = PreBufferJob::DECODE_PROBE;
                        probe.track = track;
                        probe.clip_id = c.clip_id;
                        probe.media_path = c.media_path;
                        probe.probe_source_in = c.source_in;
                        probe.probe_rate_num = c.rate_num;
                        probe.probe_rate_den = c.rate_den;
                        probes.push_back(std::move(probe));
                    }
                }
            }
            for (const auto& p : probes) {
                submit_pre_buffer(p);
            }
        }
    }
}

void TimelineMediaBuffer::ClearAllClips() {
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        m_tracks.clear();
    }
    // Invalidate watermarks is implicit — m_tracks is empty.
    // Mixed audio cache is stale too.
    {
        std::lock_guard<std::mutex> lock(m_mix_mutex);
        m_mixed_cache.clear();
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
        // Clear stale mixed cache from previous play session.
        // Without this, mix thread sees old cache_end >= target_end and
        // skips filling for the new position (dedup may have skipped
        // SetAudioMixParams, so no explicit clear happened).
        {
            std::lock_guard<std::mutex> lock(m_mix_mutex);
            m_mixed_cache.clear();
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

    // ── Probe scheduling: scan PROBE_WINDOW ahead for unprobed media paths ──
    // Submit DECODE_PROBE jobs so stride_map (m_decode_ms) is populated well
    // before REFILL reaches those clips. Only on play (direction != 0).
    if (direction != 0) {
        struct ProbeTarget { TrackId track; std::string clip_id, media_path;
                             int64_t source_in; int32_t rate_num, rate_den; };
        std::vector<ProbeTarget> probes;
        {
            std::lock_guard<std::mutex> tlock(m_tracks_mutex);
            std::lock_guard<std::mutex> plock(m_pool_mutex);
            int64_t scan_end = (direction > 0)
                ? frame + PROBE_WINDOW
                : std::max(frame - PROBE_WINDOW, int64_t(0));

            for (const auto& [tid, ts] : m_tracks) {
                if (tid.type != TrackType::Video) continue;
                for (const auto& c : ts.clips) {
                    // Check if clip overlaps [frame, scan_end] (forward) or [scan_end, frame] (reverse)
                    bool in_window = (direction > 0)
                        ? (c.timeline_start < scan_end && c.timeline_end() > frame)
                        : (c.timeline_start < frame && c.timeline_end() > scan_end);
                    if (!in_window) continue;
                    if (m_decode_ms.find(c.media_path) != m_decode_ms.end()) continue;
                    if (m_offline.find(c.media_path) != m_offline.end()) continue;
                    probes.push_back({tid, c.clip_id, c.media_path,
                                      c.source_in, c.rate_num, c.rate_den});
                }
            }
        }
        for (const auto& p : probes) {
            PreBufferJob job{};
            job.type = PreBufferJob::DECODE_PROBE;
            job.track = p.track;
            job.clip_id = p.clip_id;
            job.media_path = p.media_path;
            job.probe_source_in = p.source_in;
            job.probe_rate_num = p.rate_num;
            job.probe_rate_den = p.rate_den;
            submit_pre_buffer(job);
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

// find_next_clip_after — first clip starting after timeline_frame (gap-skip helper).
// Parallels find_next_clip_at_us but works in frame coordinates.
const ClipInfo* TimelineMediaBuffer::find_next_clip_after(const TrackState& ts, int64_t timeline_frame) const {
    const ClipInfo* best = nullptr;
    int64_t best_start = std::numeric_limits<int64_t>::max();
    for (const auto& clip : ts.clips) {
        if (clip.timeline_start > timeline_frame && clip.timeline_start < best_start) {
            best = &clip;
            best_start = clip.timeline_start;
        }
    }
    return best;
}

// ============================================================================
// GetVideoFrame
// ============================================================================

VideoResult TimelineMediaBuffer::GetVideoFrame(TrackId track, int64_t timeline_frame, bool cache_only) {
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
        // Gap: still check watermark so REFILL pre-fills upcoming clips.
        // Without this, gaps starve the watermark — no cache hits or misses
        // → no check_video_watermark → no REFILL until playhead enters a clip
        // → cold decode at clip boundary (black frames until REFILL catches up).
        char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
        EMP_LOG_DEBUG("GetVideoFrame gap: track %s frame %lld, %zu clips [%lld..%lld)",
            tbuf, (long long)timeline_frame,
            ts.clips.size(),
            ts.clips.empty() ? -1LL : (long long)ts.clips.front().timeline_start,
            ts.clips.empty() ? -1LL : (long long)ts.clips.back().timeline_end());
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0) {
            tracks_lock.unlock();
            check_video_watermark(track, timeline_frame, dir);
        }
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

    // ── Cache miss: nearest-frame fallback (cache_only) or sync decode ──

    // During playback (cache_only), REFILL's adaptive stride may have decoded
    // a nearby frame but not this exact one. Search for the nearest cached
    // frame from the same clip. O(log n) on ordered map.
    // MAX_NEAREST_DISTANCE bounds the fallback: never show a frame from
    // hundreds of frames away (would display wrong content during stalls).
    static constexpr int64_t MAX_NEAREST_DISTANCE = 16;  // adaptive stride max (8) * 2
    if (cache_only) {
        const std::string& cid = clip->clip_id;
        auto lo = ts.video_cache.lower_bound(timeline_frame);
        const TrackState::CachedFrame* best = nullptr;
        int64_t best_dist = INT64_MAX;

        // Check entry at or after timeline_frame
        if (lo != ts.video_cache.end() && lo->second.clip_id == cid) {
            int64_t d = lo->first - timeline_frame;
            if (d < best_dist && d <= MAX_NEAREST_DISTANCE) { best = &lo->second; best_dist = d; }
        }
        // Check entry before timeline_frame
        if (lo != ts.video_cache.begin()) {
            auto prev = std::prev(lo);
            if (prev->second.clip_id == cid) {
                int64_t d = timeline_frame - prev->first;
                if (d < best_dist && d <= MAX_NEAREST_DISTANCE) { best = &prev->second; best_dist = d; }
            }
        }
        if (best) {
            result.frame = best->frame;
            result.source_frame = best->source_frame;
            result.rotation = best->rotation;
            result.par_num = best->par_num;
            result.par_den = best->par_den;

            int dir = m_playhead_direction.load(std::memory_order_relaxed);
            if (dir != 0) {
                tracks_lock.unlock();
                check_video_watermark(track, timeline_frame, dir);
            }
            return result;
        }
    }

    int direction = m_playhead_direction.load(std::memory_order_relaxed);

    // Watermark check on cache miss during playback: during cold-start,
    // every frame is a miss. Without this, only cache HITs trigger refill.
    // Must copy clip locals and release tracks_lock first (lock ordering).
    std::string media_path = clip->media_path;
    Rate clip_rate = clip->rate();
    std::string clip_id = clip->clip_id;
    tracks_lock.unlock();

    if (direction != 0) {
        check_video_watermark(track, timeline_frame, direction);
    }

    // Check offline registry
    {
        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
        auto offline_it = m_offline.find(media_path);
        if (offline_it != m_offline.end()) {
            result.offline = true;
            result.error_msg = offline_it->second.message;
            result.error_code = error_code_to_string(offline_it->second.code);
            return result;
        }
    }

    // Diagnostics: count every cache miss regardless of cache_only
    m_video_cache_misses.fetch_add(1, std::memory_order_relaxed);

    // Play mode: cache-only. All decode on REFILL workers.
    // Metadata + offline already populated. Skip sync decode.
    if (cache_only) {
        return result;
    }

    // Acquire reader and decode (TMB cache miss → Reader fallback)
    auto reader = acquire_reader(track, clip_id, media_path);
    if (!reader) {
        // Empty ReaderHandle: FileNotFound (in m_offline), codec error (transient),
        // or reader busy (try_lock failed during Play). Check m_offline to distinguish.
        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
        auto err_it = m_offline.find(media_path);
        if (err_it != m_offline.end()) {
            result.offline = true;
            result.error_msg = err_it->second.message;
            result.error_code = error_code_to_string(err_it->second.code);
        }
        // else: transient error or reader busy — frame=nullptr, not offline
        return result;
    }

    // Cache re-check: REFILL worker may have populated our frame while we
    // waited for the reader's use_mutex. Avoid redundant decode.
    {
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track);
        if (tit != m_tracks.end()) {
            auto cache_it2 = tit->second.video_cache.find(timeline_frame);
            if (cache_it2 != tit->second.video_cache.end() &&
                cache_it2->second.clip_id == clip_id &&
                cache_it2->second.source_frame == source_frame) {
                result.frame = cache_it2->second.frame;
                result.rotation = cache_it2->second.rotation;
                result.par_num = cache_it2->second.par_num;
                result.par_den = cache_it2->second.par_den;
                return result;
            }
        }
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
        // Decode failure: file exists, reader works, but this frame couldn't be
        // decoded (corrupt frame, seek failure, codec glitch, slow SW decode).
        // NOT offline — return frame=nullptr so caller holds last frame or shows
        // gap. Transient: next frame or next seek may succeed.
        result.error_msg = decode_result.error().message;
        result.error_code = error_code_to_string(decode_result.error().code);
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
    assert(speed_ratio > 0.0f && "build_audio_output: speed_ratio must be positive (callers pass std::abs)");

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
    if (track_it == m_tracks.end()) {
        return nullptr;
    }
    auto& ts = track_it->second;

    // Find clip at t0
    const ClipInfo* clip = find_clip_at_us(ts, t0);
    if (!clip) {
        return nullptr;
    }

    assert(clip->rate_den > 0 && "GetTrackAudio: clip has zero rate_den");
    assert(clip->speed_ratio != 0.0f && "GetTrackAudio: clip has zero speed_ratio");

    // Clip boundaries in timeline microseconds
    TimeUS clip_start_us = FrameTime::from_frame(clip->timeline_start, m_seq_rate).to_us();
    TimeUS clip_end_us = FrameTime::from_frame(clip->timeline_end(), m_seq_rate).to_us();

    // Clamp request to first clip
    TimeUS clamped_t0 = std::max(t0, clip_start_us);
    TimeUS clamped_t1 = std::min(t1, clip_end_us);
    if (clamped_t1 <= clamped_t0) {
        return nullptr;
    }

    // Map timeline us → source us
    // For reverse clips (speed_ratio < 0), source_t0 > source_t1 after this formula.
    // We swap for forward-order decoding, then reverse PCM afterward.
    TimeUS source_origin_us = FrameTime::from_frame(clip->source_in, clip->rate()).to_us();
    double sr = static_cast<double>(clip->speed_ratio);
    TimeUS source_t0 = source_origin_us + static_cast<int64_t>((clamped_t0 - clip_start_us) * sr);
    TimeUS source_t1 = source_origin_us + static_cast<int64_t>((clamped_t1 - clip_start_us) * sr);
    bool reversed = (source_t0 > source_t1);
    if (reversed) std::swap(source_t0, source_t1);

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
            if (m_offline.count(media_path)) {
                return nullptr;
            }
        }

        // Acquire reader and decode first clip
        auto reader = acquire_reader(track, clip_id, media_path);
        if (!reader) {
            return nullptr;
        }

        auto decode_result = reader->DecodeAudioRangeUS(source_t0, source_t1, fmt);
        if (decode_result.is_error()) {
            return nullptr;
        }

        auto chunk = decode_result.value();
        if (!chunk || chunk->frames() == 0) {
            return nullptr;
        }

        first_chunk = build_audio_output(chunk, source_t0, source_t1,
                                         clamped_t0, clamped_t1, std::abs(speed_ratio), fmt);
        // Reverse PCM for reverse clips: audio was decoded forward, now flip it
        if (reversed && first_chunk && first_chunk->frames() > 0) {
            reverse_interleaved(first_chunk->mutable_data_f32(),
                                first_chunk->frames(), fmt.channels);
        }
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
        assert(next->speed_ratio != 0.0f && "GetTrackAudio: next clip has zero speed_ratio");

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

        // Map to source coordinates (may be inverted for reverse clips)
        TimeUS next_src_origin = FrameTime::from_frame(next->source_in, next->rate()).to_us();
        double next_sr = static_cast<double>(next->speed_ratio);
        TimeUS next_src_t0 = next_src_origin + static_cast<int64_t>((seg_t0 - next_start_us) * next_sr);
        TimeUS next_src_t1 = next_src_origin + static_cast<int64_t>((seg_t1 - next_start_us) * next_sr);
        bool next_reversed = (next_src_t0 > next_src_t1);
        if (next_reversed) std::swap(next_src_t0, next_src_t1);

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
                                          seg_t0, seg_t1, std::abs(next_speed), fmt);
            if (next_reversed && seg && seg->frames() > 0) {
                reverse_interleaved(seg->mutable_data_f32(), seg->frames(), fmt.channels);
            }
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

    // Compute refill range: [refill_from, refill_from + REFILL_SIZE], clamped to HIGH_WATER.
    // When playhead outruns buffer_end (slow codec), skip ahead to playhead —
    // frames behind the playhead are already consumed, decoding them is waste.
    // NOTE: we do NOT write video_buffer_end here. The REFILL worker is the sole
    // owner of buffer_end — it advances the watermark only after actually decoding
    // and caching frames. submit_pre_buffer dedup prevents redundant REFILL jobs.
    int64_t refill_from, max_end;
    if (direction > 0) {
        refill_from = std::max(buffer_end, playhead);
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
    if (m_audio_mix_params.empty()) {
        return nullptr;
    }

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
        if (!pcm || pcm->frames() == 0) {
            continue;
        }

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

    if (!has_audio) {
        return nullptr;
    }

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
            ts.audio_cache.clear();
        }
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

void TimelineMediaBuffer::ClearOffline(const std::string& path) {
    std::lock_guard<std::mutex> lock(m_pool_mutex);
    m_offline.erase(path);
}

float TimelineMediaBuffer::GetProbeDecodeMs(const std::string& media_path) const {
    std::lock_guard<std::mutex> lock(m_pool_mutex);
    auto it = m_decode_ms.find(media_path);
    return (it != m_decode_ms.end()) ? it->second : -1.0f;
}

bool TimelineMediaBuffer::GetNextClipOnTrack(TrackId track, int64_t timeline_frame, ClipInfo& out) const {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto tit = m_tracks.find(track);
    if (tit == m_tracks.end()) return false;
    const ClipInfo* next = find_next_clip_after(tit->second, timeline_frame);
    if (!next) return false;
    out = *next;
    return true;
}

// ============================================================================
// Reader pool — LRU with per-(track, path) isolation
// ============================================================================

TimelineMediaBuffer::ReaderHandle TimelineMediaBuffer::acquire_reader(
        TrackId track, const std::string& clip_id, const std::string& path) {

    std::shared_ptr<Reader> reader;
    std::shared_ptr<std::mutex> use_mtx;

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
    // Only FileNotFound errors register in m_offline (permanent blacklist until
    // ClearOffline). Other errors (Unsupported, Internal) are per-attempt — the
    // path is NOT blacklisted so TMB retries on next access (codec install, etc.).
    auto mf_result = MediaFile::Open(path);
    if (mf_result.is_error()) {
        auto& err = mf_result.error();
        if (err.code == ErrorCode::FileNotFound) {
            std::lock_guard<std::mutex> lock(m_pool_mutex);
            m_offline[path] = err;
        }
        EMP_LOG_WARN("acquire_reader: MediaFile::Open failed for %s: %s (%s)",
            path.c_str(), error_code_to_string(err.code), err.message.c_str());
        return ReaderHandle{};
    }
    auto mf = mf_result.value();

    auto reader_result = Reader::Create(mf);
    if (reader_result.is_error()) {
        auto err = reader_result.error();
        if (err.code == ErrorCode::Unsupported) {
            // Unsupported codec (e.g. BRAW, R3D) — permanent blacklist.
            // Registers in m_offline so GetVideoFrame sets offline=true
            // and the UI draws the red "codec unavailable" frame.
            std::lock_guard<std::mutex> lock(m_pool_mutex);
            m_offline[path] = err;
        }
        EMP_LOG_WARN("acquire_reader: Reader::Create failed for %s: %s (%s)",
            path.c_str(), error_code_to_string(err.code), err.message.c_str());
        return ReaderHandle{};
    }

    auto new_reader = reader_result.value();
    auto new_use_mtx = std::make_shared<std::mutex>();

    // Phase 3 (under lock ~1us): install into pool or discard if another thread raced
    {
        std::lock_guard<std::mutex> lock(m_pool_mutex);

        auto key = std::make_pair(track, clip_id);
        auto it = m_readers.find(key);
        if (it != m_readers.end()) {
            // SW→HW upgrade: if existing reader is SW and new reader got HW,
            // replace the pool entry. Handles WARM creating SW readers at app
            // startup before VT is ready — later creations (WARM retry, REFILL)
            // succeed with HW and upgrade the slot. Old reader remains valid
            // for any thread currently using it (shared_ptr refcount).
            bool existing_sw = !it->second.reader->IsHwAccelerated();
            bool new_hw = new_reader->IsHwAccelerated();
            if (existing_sw && new_hw) {
                it->second = PoolEntry{path, mf, new_reader, track, ++m_pool_clock, new_use_mtx};
                reader = new_reader;
                use_mtx = new_use_mtx;
                log_pool_state("UPGRADE", track, clip_id, true);
            } else {
                // Same tier or downgrade — keep existing, discard new.
                it->second.last_used = ++m_pool_clock;
                reader = it->second.reader;
                use_mtx = it->second.use_mutex;
            }
        } else {
            // Re-check offline (may have been registered between Phase 1 and 3)
            if (m_offline.count(path)) return ReaderHandle{};

            while (static_cast<int>(m_readers.size()) >= m_max_readers) {
                evict_lru_reader();
            }
            m_readers[key] = PoolEntry{path, mf, new_reader, track, ++m_pool_clock, new_use_mtx};
            reader = new_reader;
            use_mtx = new_use_mtx;

            // Log pool state — critical for diagnosing VT session exhaustion
            log_pool_state("NEW", track, clip_id, new_reader->IsHwAccelerated());
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
    char tbuf[8];
    EMP_LOG_WARN("POOL EVICT: track=%s clip=%s hw=%s path=%s",
                 track_str(oldest->first.first, tbuf, sizeof(tbuf)),
                 oldest->first.second.c_str(),
                 oldest->second.reader->IsHwAccelerated() ? "VT" : "SW",
                 oldest->second.path.c_str());
    m_readers.erase(oldest);
}

void TimelineMediaBuffer::log_pool_state(const char* action, const TrackId& track,
                                          const std::string& clip_id, bool is_hw) {
    // Must be called with m_pool_mutex held
    int hw_count = 0, sw_count = 0;
    for (const auto& [key, entry] : m_readers) {
        if (entry.reader->IsHwAccelerated()) ++hw_count; else ++sw_count;
    }
    int total = static_cast<int>(m_readers.size());

    char tbuf[8];
    EMP_LOG_WARN("POOL %s: track=%s clip=%s %s — %d/%d readers (VT=%d SW=%d)",
                 action, track_str(track, tbuf, sizeof(tbuf)), clip_id.c_str(),
                 is_hw ? "VT" : "SW",
                 total, m_max_readers, hw_count, sw_count);

    // Dump all readers when any SW reader exists — shows which ones are slow
    if (sw_count > 0) {
        for (const auto& [key, entry] : m_readers) {
            char tbuf2[8];
            EMP_LOG_WARN("  [%s] track=%s clip=%s %s lru=%lld path=%s",
                         entry.reader->IsHwAccelerated() ? "VT" : "SW",
                         track_str(key.first, tbuf2, sizeof(tbuf2)),
                         key.second.c_str(),
                         entry.reader->IsHwAccelerated() ? "" : "*** SLOW ***",
                         static_cast<long long>(entry.last_used),
                         entry.path.c_str());
        }
    }
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
// DECODE_PROBE: "PROBE:media_path" (keyed by media path, one probe per file)
// REFILL jobs: "V1:REFILL:2" or "A3:REFILL:3" (keyed by track+type, not clip)
// READER_WARM jobs: "V1:WARM:clip_id" (keyed by track+clip, one warm per clip)
std::string TimelineMediaBuffer::job_key(const PreBufferJob& job) {
    if (job.type == PreBufferJob::DECODE_PROBE) {
        return "PROBE:" + job.media_path;
    }
    char buf[8];
    snprintf(buf, sizeof(buf), "%c%d:",
             job.track.type == TrackType::Video ? 'V' : 'A',
             job.track.index);
    if (job.type == PreBufferJob::VIDEO_REFILL || job.type == PreBufferJob::AUDIO_REFILL) {
        return std::string(buf) + "REFILL:" + std::to_string(static_cast<int>(job.type));
    }
    // READER_WARM
    return std::string(buf) + "WARM:" + job.clip_id;
}

void TimelineMediaBuffer::submit_pre_buffer(const PreBufferJob& job) {
    std::lock_guard<std::mutex> lock(m_jobs_mutex);

    auto key = job_key(job);

    // De-duplicate against in-flight and queued jobs.
    //
    // REFILL jobs use generation-aware dedup: SetTrackClips increments
    // generation to abort stale REFILLs, but the stale worker lingers in
    // m_pre_buffering until it notices the mismatch. A new-generation
    // REFILL must pass through; the stale worker aborts in O(1).
    bool is_refill = (job.type == PreBufferJob::VIDEO_REFILL ||
                      job.type == PreBufferJob::AUDIO_REFILL);

    auto in_flight = m_pre_buffering.find(key);
    if (in_flight != m_pre_buffering.end()) {
        if (!is_refill) return;
        // REFILL: skip if same or newer generation already in-flight
        if (in_flight->second >= job.generation) {
            EMP_LOG_WARN("REFILL DEDUP(inflight): %c%d from=%lld gen=%lld",
                job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                (long long)job.refill_from_frame, (long long)job.generation);
            return;
        }
        // Stale generation in-flight → allow new REFILL through
    }

    for (auto& j : m_jobs) {
        if (is_refill) {
            if (j.track == job.track && j.type == job.type &&
                j.generation == job.generation) {
                // Update queued REFILL with latest start position (playhead chase).
                // The old start may be behind the playhead; decoding those frames
                // would be wasted work.
                EMP_LOG_WARN("REFILL DEDUP(queued): %c%d chase %lld→%lld",
                    job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                    (long long)j.refill_from_frame, (long long)job.refill_from_frame);
                j.refill_from_frame = job.refill_from_frame;
                j.refill_count = job.refill_count;
                return;
            }
        } else {
            if (j.track == job.track && j.clip_id == job.clip_id &&
                j.type == job.type) return;
        }
    }

    if (is_refill) {
        EMP_LOG_WARN("REFILL QUEUED: %c%d from=%lld count=%d gen=%lld",
            job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
            (long long)job.refill_from_frame, job.refill_count,
            (long long)job.generation);
    }
    m_jobs.push_back(job);
    m_jobs.back().submitted_at = std::chrono::steady_clock::now();
    m_jobs_cv.notify_all();
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

            // Priority pick: DECODE_PROBE > AUDIO_REFILL > VIDEO_REFILL > WARM/other.
            // Within each tier, newest-first (scan backward). Without priority,
            // LIFO lets WARM jobs starve REFILL when many clips trigger warmup.
            // DECODE_PROBE is highest: one frame, seeds predictive stride data.
            int pick = static_cast<int>(m_jobs.size()) - 1;
            bool found_priority = false;
            for (int i = static_cast<int>(m_jobs.size()) - 1; i >= 0; --i) {
                if (m_jobs[i].type == PreBufferJob::DECODE_PROBE) {
                    pick = i;
                    found_priority = true;
                    break;
                }
            }
            if (!found_priority) {
                for (int i = static_cast<int>(m_jobs.size()) - 1; i >= 0; --i) {
                    if (m_jobs[i].type == PreBufferJob::AUDIO_REFILL) {
                        pick = i;
                        found_priority = true;
                        break;
                    }
                }
            }
            if (!found_priority) {
                for (int i = static_cast<int>(m_jobs.size()) - 1; i >= 0; --i) {
                    if (m_jobs[i].type == PreBufferJob::VIDEO_REFILL) {
                        pick = i;
                        break;
                    }
                }
            }
            assert(pick >= 0 && pick < static_cast<int>(m_jobs.size())
                && "worker_loop: pick index out of range");
            job = std::move(m_jobs[pick]);
            m_jobs.erase(m_jobs.begin() + pick);
            key = job_key(job);
            m_pre_buffering[key] = job.generation;
        }

        // RAII: remove from in-flight set when job processing completes
        // (handles all exit paths: continue, break, fall-through)
        auto guard = make_scope_exit([this, &key] {
            std::lock_guard<std::mutex> lock(m_jobs_mutex);
            m_pre_buffering.erase(key);
        });

        if (job.type == PreBufferJob::DECODE_PROBE) {
            // ── Priority probe: single-frame decode to measure codec speed ──
            // Runs before REFILL/WARM so predictive stride has data early.
            auto probe_reader = acquire_reader(job.track, job.clip_id, job.media_path);
            if (probe_reader) {
                const auto& pinfo = probe_reader->media_file()->info();
                int64_t file_frame = job.probe_source_in - pinfo.start_tc;
                Rate probe_rate{job.probe_rate_num, job.probe_rate_den};
                FrameTime pft = FrameTime::from_frame(file_frame, probe_rate);

                auto pt0 = std::chrono::steady_clock::now();
                auto presult = probe_reader->DecodeAt(pft);
                float wall_ms = std::chrono::duration<float, std::milli>(
                    std::chrono::steady_clock::now() - pt0).count();

                char tbuf[8]; track_str(job.track, tbuf, sizeof(tbuf));
                if (presult.is_ok()) {
                    float per_frame_ms = probe_reader->LastBatchMsPerFrame();
                    float record_ms = (per_frame_ms > 0) ? per_frame_ms : wall_ms;

                    {
                        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
                        m_decode_ms[job.media_path] = record_ms;
                    }

                    EMP_LOG_DEBUG("PROBE: %s clip=%.8s path=%s decode=%.1fms (wall=%.1fms)",
                        tbuf, job.clip_id.c_str(), job.media_path.c_str(), record_ms, wall_ms);
                } else {
                    EMP_LOG_WARN("PROBE: %s clip=%.8s decode failed — timing not recorded",
                        tbuf, job.clip_id.c_str());
                }
            }

        } else if (job.type == PreBufferJob::VIDEO_REFILL) {
            // Probing is handled by SetPlayhead's PROBE_WINDOW scanning via
            // DECODE_PROBE jobs (highest priority). Gap probe (below) is a
            // fallback for clips not in the window at scan time.

            // ── Watermark-driven video refill: iterate timeline frames, acquire
            // readers per-clip, skip gaps. One batch spans clip boundaries.
            //
            // Hold the reader across consecutive frames in the same clip to
            // avoid repeated use_mutex acquire/release overhead.
            int frames_decoded = 0;
            std::string held_clip_id;
            ReaderHandle held_reader;
            std::shared_ptr<Frame> last_good_frame;     // for hold-on-EOF

            // Pre-lookup stride from stride_map for the first clip in range.
            // Without this, the first REFILL batch decodes at stride=1 until
            // the first frame's per_frame_ms triggers adaptive stride — wasting
            // time on a known-slow codec.
            int known_stride = 0;  // 0 = no pre-lookup, use per-frame adaptive
            {
                std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                auto tit = m_tracks.find(job.track);
                if (tit != m_tracks.end()) {
                    const ClipInfo* clip = find_clip_at(tit->second, job.refill_from_frame);
                    if (clip) {
                        std::lock_guard<std::mutex> plock(m_pool_mutex);
                        auto dit = m_decode_ms.find(clip->media_path);
                        if (dit != m_decode_ms.end()) {
                            double frame_period = 1000.0 * clip->rate_den / clip->rate_num;
                            if (dit->second > frame_period * 1.5) {
                                known_stride = std::min(
                                    static_cast<int>(std::ceil(dit->second / frame_period)),
                                    8);
                            }
                        }
                    }
                }
            }

            // Chase: if playhead has advanced past our start, skip to playhead.
            // The job was submitted with refill_from = max(buffer_end, playhead),
            // but playhead may have moved since submission.
            if (job.direction > 0) {
                int64_t current_ph = m_playhead_frame.load(std::memory_order_relaxed);
                if (job.refill_from_frame < current_ph) {
                    int64_t skip = current_ph - job.refill_from_frame;
                    job.refill_from_frame = current_ph;
                    job.refill_count = std::max(0, job.refill_count - static_cast<int>(skip));
                    if (job.refill_count == 0) {
                        EMP_LOG_DEBUG("REFILL SKIP: playhead outran buffer by %lld frames — no work",
                            (long long)skip);
                        break;  // Skip the entire REFILL — buffer completely stale
                    }
                }
            }

            EMP_LOG_WARN("REFILL START: %c%d from=%lld count=%d gen=%lld",
                job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                (long long)job.refill_from_frame, job.refill_count,
                (long long)job.generation);

            for (int i = 0; i < job.refill_count; ++i) {
                if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0) break;

                int64_t tf = job.refill_from_frame + i;

                // Find clip at this timeline frame (copy fields under tracks_lock)
                std::string clip_id, media_path;
                int64_t source_in = 0, timeline_start = 0, clip_duration = 0;
                int32_t rate_num = 0, rate_den = 1;
                float speed_ratio = 1.0f;
                bool is_gap = false;
                // Gap probe: populated under tracks_lock, decoded after release
                bool do_probe = false;
                std::string probe_path, probe_clip_id;
                int64_t probe_tf = 0, probe_src = 0;
                int32_t probe_rn = 0, probe_rd = 1;
                {
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit == m_tracks.end()) break;
                    // Stale REFILL: SetTrackClips advanced generation — abort so
                    // the new REFILL (with fresh clip list) can run promptly.
                    if (tit->second.refill_generation != job.generation) break;
                    const ClipInfo* clip = find_clip_at(tit->second, tf);
                    if (!clip) {
                        // Gap: skip to the next clip boundary on this track.
                        // Without this, REFILL crawls through gaps 48 frames at
                        // a time, each batch advancing buffer_end by REFILL_SIZE.
                        // A 374-frame gap takes ~8 batches (~16s of playback) to
                        // cross — by then it's too late for the next clip.
                        const ClipInfo* next = find_next_clip_after(tit->second, tf);
                        if (next) {
                            // Jump buffer_end and loop index to next clip
                            if (next->timeline_start > tit->second.video_buffer_end) {
                                tit->second.video_buffer_end = next->timeline_start;
                            }
                            int64_t skip = next->timeline_start - tf;

                            // Prepare probe: decode ONE frame of the upcoming clip
                            // after releasing tracks_lock. Seeds the cache and
                            // records decode speed per media path.
                            do_probe = true;
                            probe_path = next->media_path;
                            probe_clip_id = next->clip_id;
                            probe_tf = next->timeline_start;
                            probe_src = next->source_in;
                            probe_rn = next->rate_num;
                            probe_rd = next->rate_den;

                            i += static_cast<int>(skip - 1); // for-loop will ++i
                        } else {
                            // No more clips ahead — advance to end of refill range
                            int64_t end = job.refill_from_frame + job.refill_count;
                            if (end > tit->second.video_buffer_end) {
                                tit->second.video_buffer_end = end;
                            }
                            i = job.refill_count; // break
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

                    // Gap probe: decode one frame of the upcoming clip to seed the
                    // cache and learn decode speed. Done outside tracks_lock.
                    if (do_probe) {
                        auto probe_reader = acquire_reader(job.track, probe_clip_id, probe_path);
                        if (probe_reader) {
                            const auto& pinfo = probe_reader->media_file()->info();
                            int64_t file_frame = probe_src - pinfo.start_tc;
                            Rate probe_rate{probe_rn, probe_rd};
                            FrameTime pft = FrameTime::from_frame(file_frame, probe_rate);

                            auto presult = probe_reader->DecodeAt(pft);

                            // Use per-frame time, not wall-clock batch time.
                            float per_frame_ms = probe_reader->LastBatchMsPerFrame();

                            // Don't overwrite existing measurement — gap probe
                            // often hits reader cache after proactive probe.
                            {
                                std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
                                if (m_decode_ms.find(probe_path) == m_decode_ms.end() &&
                                    per_frame_ms > 0) {
                                    m_decode_ms[probe_path] = per_frame_ms;
                                }
                            }

                            if (presult.is_ok()) {
                                std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                                auto tit2 = m_tracks.find(job.track);
                                if (tit2 != m_tracks.end() &&
                                    tit2->second.refill_generation == job.generation) {
                                    auto& cache = tit2->second.video_cache;
                                    while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                                        cache.erase(cache.begin());
                                    }
                                    cache[probe_tf] = {probe_clip_id, probe_src, presult.value(),
                                                       pinfo.rotation, pinfo.video_par_num, pinfo.video_par_den};
                                }
                            }

                            char tbuf[8]; track_str(job.track, tbuf, sizeof(tbuf));
                            EMP_LOG_WARN("GAP PROBE: %s clip=%.8s per_frame=%.1fms",
                                tbuf, probe_clip_id.c_str(), per_frame_ms);
                        }
                    }

                    continue;
                }

                // Acquire reader only when clip changes (boundary crossing)
                if (clip_id != held_clip_id || !held_reader) {
                    held_reader = {};  // release old reader first
                    held_reader = acquire_reader(job.track, clip_id, media_path);
                    if (!held_reader) {
                        // Undecodable clip (unsupported codec, offline, etc.).
                        // Skip to clip end — same as audio REFILL does.
                        // Without this, REFILL loops 0/48 forever on e.g. .braw files.
                        int64_t clip_end = timeline_start + clip_duration;
                        {
                            std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                            auto tit = m_tracks.find(job.track);
                            if (tit != m_tracks.end() && clip_end > tit->second.video_buffer_end) {
                                tit->second.video_buffer_end = clip_end;
                            }
                        }
                        char tbuf3[8]; track_str(job.track, tbuf3, sizeof(tbuf3));
                        EMP_LOG_WARN("REFILL SKIP: %s clip=%.8s undecodable, advancing buffer_end to %lld",
                            tbuf3, clip_id.c_str(), (long long)clip_end);
                        int64_t skip = clip_end - tf;
                        if (skip > 1) i += static_cast<int>(skip - 1);
                        continue;
                    }
                    held_clip_id = clip_id;
                }

                assert(rate_num > 0 && "worker_loop VIDEO_REFILL: clip has zero rate_num");
                assert(rate_den > 0 && "worker_loop VIDEO_REFILL: clip has zero rate_den");
                assert(speed_ratio != 0.0f && "worker_loop VIDEO_REFILL: clip has zero speed_ratio");
                int64_t source_frame = source_in +
                    static_cast<int64_t>((tf - timeline_start) * speed_ratio);
                const auto& info = held_reader->media_file()->info();
                int64_t file_frame = source_frame - info.start_tc;
                Rate clip_rate{rate_num, rate_den};
                FrameTime ft = FrameTime::from_frame(file_frame, clip_rate);

                auto result = held_reader->DecodeAt(ft);

                // Use per-frame time from the reader's batch (codec throughput),
                // not wall-clock per-call (oscillates batch/0 on cache hits).
                // EMA smooths jitter while adapting to sustained speed changes.
                float per_frame_ms = held_reader->LastBatchMsPerFrame();
                if (per_frame_ms > 0) {
                    std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
                    auto it = m_decode_ms.find(media_path);
                    if (it == m_decode_ms.end()) {
                        m_decode_ms[media_path] = per_frame_ms;
                    } else {
                        // α=0.3: responsive to change but smooths single-frame spikes
                        it->second = 0.3f * per_frame_ms + 0.7f * it->second;
                    }
                }

                if (result.is_ok()) {
                    last_good_frame = result.value();
                    std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                    auto tit = m_tracks.find(job.track);
                    if (tit != m_tracks.end()) {
                        auto& cache = tit->second.video_cache;
                        while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                            cache.erase(cache.begin());
                        }
                        TrackState::CachedFrame cf{clip_id, source_frame, result.value(),
                                       info.rotation, info.video_par_num, info.video_par_den};
                        cache[tf] = cf;
                        // Use max() to avoid regressing watermark when on-demand
                        // has already advanced it past this REFILL's range.
                        if (tf + 1 > tit->second.video_buffer_end) {
                            tit->second.video_buffer_end = tf + 1;
                        }

                        // Adaptive stride: when decode is slower than real-time,
                        // skip frames so REFILL buffer advances ahead of playhead.
                        // Self-correcting: fast codec → skip=0, slow → proportional skip.
                        // Populate cache at ALL skipped positions so deliverFrame
                        // (cache_only) hits on any frame in the stride interval.
                        double frame_period_ms = 1000.0 * rate_den / rate_num;
                        static constexpr int MAX_ADAPTIVE_STRIDE = 8;

                        // Compute skip from measured per-frame time, OR use
                        // pre-looked-up known_stride from stride_map (whichever is larger).
                        int skip = 0;
                        if (per_frame_ms > frame_period_ms * 1.5) {
                            skip = std::min(
                                static_cast<int>(std::ceil(per_frame_ms / frame_period_ms)) - 1,
                                MAX_ADAPTIVE_STRIDE);
                        }
                        // known_stride is stride (decode every Nth), skip = stride - 1
                        if (known_stride > 1) {
                            skip = std::max(skip, known_stride - 1);
                        }
                        if (skip >= 1) {

                            // Fill skipped positions with same decoded frame.
                            // AVFrame is ref-counted — shared_ptr copies are cheap.
                            for (int s = 1; s <= skip; ++s) {
                                int64_t fill_tf = tf + s;
                                // Stop at clip boundary
                                if (fill_tf >= timeline_start + clip_duration) break;
                                while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                                    cache.erase(cache.begin());
                                }
                                cache[fill_tf] = cf;
                            }

                            int64_t skip_end = tf + skip + 1;
                            if (skip_end > tit->second.video_buffer_end) {
                                tit->second.video_buffer_end = skip_end;
                            }
                            i += skip;  // for-loop will ++i
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
            if (frames_decoded == 0 && job.refill_count > 0) {
                // Diagnostic: why did REFILL decode nothing? Log clip state.
                std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                auto tit = m_tracks.find(job.track);
                if (tit == m_tracks.end()) {
                    EMP_LOG_WARN("REFILL: 0/%d on %c%d — track not found in m_tracks",
                            job.refill_count,
                            job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);
                } else {
                    auto& ts = tit->second;
                    EMP_LOG_WARN("REFILL: 0/%d on %c%d — gen job=%lld cur=%lld, "
                            "%zu clips, range [%lld..%lld), buffer_end=%lld",
                            job.refill_count,
                            job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                            (long long)job.generation, (long long)ts.refill_generation,
                            ts.clips.size(),
                            (long long)job.refill_from_frame,
                            (long long)(job.refill_from_frame + job.refill_count),
                            (long long)ts.video_buffer_end);
                    if (!ts.clips.empty()) {
                        EMP_LOG_WARN("  clips: first=[%lld..%lld) last=[%lld..%lld)",
                                (long long)ts.clips.front().timeline_start,
                                (long long)ts.clips.front().timeline_end(),
                                (long long)ts.clips.back().timeline_start,
                                (long long)ts.clips.back().timeline_end());
                    }
                }
            } else {
                EMP_LOG_DEBUG("REFILL: %d/%d video frames on track %c%d",
                        frames_decoded, job.refill_count,
                        job.track.type == TrackType::Video ? 'V' : 'A', job.track.index);
            }

            // Log end state for diagnosis
            {
                std::lock_guard<std::mutex> tlock(m_tracks_mutex);
                auto tit = m_tracks.find(job.track);
                if (tit != m_tracks.end()) {
                    int64_t ph = m_playhead_frame.load(std::memory_order_relaxed);
                    EMP_LOG_WARN("REFILL END: %c%d decoded=%d buffer_end=%lld playhead=%lld ahead=%lld cache_size=%zu",
                        job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                        frames_decoded,
                        (long long)tit->second.video_buffer_end,
                        (long long)ph,
                        (long long)(tit->second.video_buffer_end - ph),
                        tit->second.video_cache.size());
                }
            }

        } else if (job.type == PreBufferJob::AUDIO_REFILL) {
            // ── Watermark-driven audio refill: decode chunks spanning clip boundaries.
            assert(job.refill_to_us > job.refill_from_us && "worker_loop: AUDIO_REFILL has inverted range");
            assert(m_seq_rate.num > 0 && "worker_loop: AUDIO_REFILL requires SetSequenceRate");

            EMP_LOG_WARN("REFILL START: A%d from_us=%lld to_us=%lld gen=%lld",
                job.track.index,
                (long long)job.refill_from_us, (long long)job.refill_to_us,
                (long long)job.generation);

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
                assert(speed_ratio != 0.0f && "worker_loop AUDIO_REFILL: clip has zero speed_ratio");
                TimeUS src_origin = FrameTime::from_frame(source_in, Rate{rate_num, rate_den}).to_us();
                double sr_d = static_cast<double>(speed_ratio);
                TimeUS src_t0 = src_origin + static_cast<int64_t>((chunk_t0 - clip_start_us) * sr_d);
                TimeUS src_t1 = src_origin + static_cast<int64_t>((chunk_t1 - clip_start_us) * sr_d);
                bool chunk_reversed = (src_t0 > src_t1);
                if (chunk_reversed) std::swap(src_t0, src_t1);

                // Acquire reader and decode (no locks held)
                auto reader = acquire_reader(job.track, clip_id, media_path);
                if (!reader) { cursor = clip_end_us; continue; }

                auto decode_result = reader->DecodeAudioRangeUS(src_t0, src_t1, m_audio_fmt);
                if (decode_result.is_error() || !decode_result.value() || decode_result.value()->frames() == 0) {
                    char tbuf[8]; track_str(job.track, tbuf, sizeof(tbuf));
                    if (decode_result.is_error()) {
                        EMP_LOG_WARN("AUDIO_REFILL: decode error on %s clip=%.8s src=[%lld..%lld]",
                                     tbuf, clip_id.c_str(), (long long)src_t0, (long long)src_t1);
                    }
                    cursor = clip_end_us;
                    continue;
                }

                auto pcm = build_audio_output(decode_result.value(), src_t0, src_t1,
                                              chunk_t0, chunk_t1, std::abs(speed_ratio), m_audio_fmt);
                if (chunk_reversed && pcm && pcm->frames() > 0) {
                    reverse_interleaved(pcm->mutable_data_f32(),
                                        pcm->frames(), m_audio_fmt.channels);
                }
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

            EMP_LOG_WARN("REFILL END: A%d cursor_us=%lld target_us=%lld",
                job.track.index,
                (long long)cursor, (long long)job.refill_to_us);

        } else if (job.type == PreBufferJob::READER_WARM) {
            // ── Reader pre-warming: create the reader (MediaFile::Open + Reader::Create)
            // asynchronously so it's in the pool before REFILL reaches this clip.
            // acquire_reader does the heavy work; we just drop the handle afterward.
            // The reader stays in the pool (keyed by track+clip_id), warm and ready.
            auto queue_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - job.submitted_at).count();
            if (queue_ms > WARM_QUEUE_WARN_MS) {
                EMP_LOG_WARN("WARM: queue wait %lldms for clip %s (threshold %dms)",
                        (long long)queue_ms, job.clip_id.c_str(), WARM_QUEUE_WARN_MS);
            }

            EMP_LOG_DEBUG("WARM: opening reader for clip %s on track %c%d (queued %lldms)",
                    job.clip_id.c_str(),
                    job.track.type == TrackType::Video ? 'V' : 'A', job.track.index,
                    (long long)queue_ms);

            auto t0 = std::chrono::steady_clock::now();
            auto handle = acquire_reader(job.track, job.clip_id, job.media_path);
            auto acquire_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();

            if (handle) {
                EMP_LOG_DEBUG("WARM: reader ready for clip %s (queue=%lldms acquire=%lldms)",
                        job.clip_id.c_str(), (long long)queue_ms, (long long)acquire_ms);
            } else {
                EMP_LOG_WARN("WARM: failed for clip %s path=%s (acquire=%lldms)",
                        job.clip_id.c_str(), job.media_path.c_str(), (long long)acquire_ms);
            }
            if (acquire_ms > WARM_ACQUIRE_WARN_MS) {
                EMP_LOG_WARN("WARM: acquire_reader took %lldms for clip %s (threshold %dms) "
                        "— check external drive latency or codec init time",
                        (long long)acquire_ms, job.clip_id.c_str(), WARM_ACQUIRE_WARN_MS);
            }
            // handle destructor releases use_mutex — reader remains in pool

        }
        // VIDEO and AUDIO on-demand types no longer submitted — watermark
        // REFILL handles batch decode, sync fallback handles immediate needs.
    }
}

} // namespace emp
