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

        // Reset buffer_end so prefetch re-evaluates from playhead.
        // Increment generation so in-flight prefetch abandons early.
        ts.video_buffer_end = -1;
        ts.audio_buffer_end = -1;
        ts.prefetch_generation++;
        clips_changed = true;
    }
    // tracks_lock released — wake prefetch workers if playback is active.
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
            // SPEED_DETECT probes are NOT submitted here — that's SetPlayhead's
            // PROBE_WINDOW scan (once per file per session). SetTrackClips only warms readers.
            wake_prefetch_workers();
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
                    if (m_decode_speed_cache.find(c.media_path) == m_decode_speed_cache.end()) {
                        PreBufferJob probe;
                        probe.type = PreBufferJob::SPEED_DETECT;
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
    int64_t prev_frame = m_prev_playhead_frame.load(std::memory_order_relaxed);
    m_playhead_frame.store(frame, std::memory_order_relaxed);
    m_playhead_direction.store(direction, std::memory_order_relaxed);
    m_playhead_speed.store(speed, std::memory_order_relaxed);
    m_prev_playhead_frame.store(frame, std::memory_order_relaxed);

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

    // Cold-start priming: on play start (0→nonzero), reset buffers and wake prefetch
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
        // skips filling for the new position.
        {
            std::lock_guard<std::mutex> lock(m_mix_mutex);
            m_mixed_cache.clear();
        }
        // Wake prefetch workers — they self-direct what to fill
        m_audio_work_pending.store(true, std::memory_order_relaxed);
        wake_prefetch_workers();
    }

    // ── Playhead discontinuity detection ──
    // When audio-master engages (or any other correction), the playhead can jump
    // forward past the audio prefetch buffer. Detect jumps that exceed the
    // expected per-tick advance and reset audio buffers so the audio worker
    // re-fills from the new position immediately.
    if (direction != 0 && prev_frame >= 0) {
        int64_t delta = std::abs(frame - prev_frame);
        // Expected advance: speed * 1 frame/tick, with margin for jitter.
        // At 1x: threshold=3, at 4x: threshold=9, at 8x: threshold=17.
        float spd = std::max(1.0f, std::abs(speed));
        int64_t discontinuity_threshold = static_cast<int64_t>(spd * 2.0f) + 1;
        if (delta > discontinuity_threshold) {
            bool any_reset = false;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                for (auto& [tid, ts] : m_tracks) {
                    if (tid.type != TrackType::Audio) continue;
                    ts.audio_buffer_end = -1;
                    any_reset = true;
                }
            }
            if (any_reset) {
                m_audio_work_pending.store(true, std::memory_order_relaxed);
                wake_prefetch_workers();
            }
        }
    }

    // ── Steady-state audio buffer check ──
    // Even without discontinuity, wake the audio worker if any audio track
    // buffer is getting thin. Prevents underruns from slow cumulative drift.
    if (direction != 0 && m_seq_rate.num > 0) {
        TimeUS playhead_us = FrameTime::from_frame(frame, m_seq_rate).to_us();
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        for (const auto& [tid, ts] : m_tracks) {
            if (tid.type != TrackType::Audio) continue;
            if (is_audio_buffer_low(ts, playhead_us, direction)) {
                m_audio_work_pending.store(true, std::memory_order_relaxed);
                m_jobs_cv.notify_all();
                break;
            }
        }
    }

    // ── Probe scheduling: scan PROBE_WINDOW ahead for unprobed media paths ──
    // Submit SPEED_DETECT jobs so stride_map (m_decode_speed_cache) is populated well
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
                    if (m_decode_speed_cache.find(c.media_path) != m_decode_speed_cache.end()) continue;
                    if (m_offline.find(c.media_path) != m_offline.end()) continue;
                    probes.push_back({tid, c.clip_id, c.media_path,
                                      c.source_in, c.rate_num, c.rate_den});
                }
            }
        }
        for (const auto& p : probes) {
            PreBufferJob job{};
            job.type = PreBufferJob::SPEED_DETECT;
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
// Segment finders — replace find_clip_at / find_next_clip_after pairs.
// Returns explicit CLIP or GAP with bounds. No null-means-gap pattern.
// ============================================================================

Segment TimelineMediaBuffer::find_segment_at(const TrackState& ts, int64_t timeline_frame) const {
    // Check if timeline_frame falls inside any clip
    for (const auto& clip : ts.clips) {
        if (timeline_frame >= clip.timeline_start && timeline_frame < clip.timeline_end()) {
            return Segment{Segment::CLIP, clip.timeline_start, clip.timeline_end(), &clip};
        }
    }

    // Gap: find surrounding clip boundaries
    int64_t gap_start = std::numeric_limits<int64_t>::min();
    int64_t gap_end = std::numeric_limits<int64_t>::max();

    for (const auto& clip : ts.clips) {
        // Clips ending at or before this frame → gap starts after them
        if (clip.timeline_end() <= timeline_frame) {
            if (clip.timeline_end() > gap_start) {
                gap_start = clip.timeline_end();
            }
        }
        // Clips starting after this frame → gap ends at the nearest one
        if (clip.timeline_start > timeline_frame) {
            if (clip.timeline_start < gap_end) {
                gap_end = clip.timeline_start;
            }
        }
    }

    return Segment{Segment::GAP, gap_start, gap_end, nullptr};
}

// ============================================================================
// Compositing-aware obscured check (opaque only — no blend modes)
// ============================================================================

bool TimelineMediaBuffer::is_video_obscured(const TrackId& track, int64_t timeline_frame) const {
    assert(track.type == TrackType::Video && "is_video_obscured: called on non-video track");
    for (const auto& [tid, ts] : m_tracks) {
        if (tid.type != TrackType::Video) continue;
        if (tid.index <= track.index) continue;  // same or lower — not obscuring
        for (const auto& clip : ts.clips) {
            if (timeline_frame >= clip.timeline_start && timeline_frame < clip.timeline_end()) {
                return true;
            }
        }
    }
    return false;
}

// ============================================================================
// evict_video_cache_entry — LRU via insertion sequence number
// ============================================================================

void TimelineMediaBuffer::evict_video_cache_entry(TrackState& ts) const {
    assert(!ts.video_cache.empty() && "evict_video_cache_entry: cache is empty");

    // Each CachedFrame carries a monotonic insert_seq assigned at insertion.
    // Evict the entry with the lowest insert_seq (= oldest = least recently used).
    //
    // This is correct across seek boundaries: after a backward seek, old frames
    // from the previous position have lower insert_seq than newly-prefetched
    // frames, so they're evicted first regardless of their timeline_frame key.
    // O(n) on ~144 entries = ~microseconds.
    auto victim = ts.video_cache.begin();
    for (auto it = std::next(victim); it != ts.video_cache.end(); ++it) {
        if (it->second.insert_seq < victim->second.insert_seq) {
            victim = it;
        }
    }
    ts.video_cache.erase(victim);
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

    Segment seg = find_segment_at(ts, timeline_frame);
    if (seg.type == Segment::GAP) {
        // Gap: still wake prefetch so it pre-fills upcoming clips.
        char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
        EMP_LOG_DEBUG("GetVideoFrame gap: track %s frame %lld, %zu clips [%lld..%lld)",
            tbuf, (long long)timeline_frame,
            ts.clips.size(),
            ts.clips.empty() ? -1LL : (long long)ts.clips.front().timeline_start,
            ts.clips.empty() ? -1LL : (long long)ts.clips.back().timeline_end());
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0 && is_video_buffer_low(ts, timeline_frame, dir)) {
            tracks_lock.unlock();
            wake_prefetch_workers();
        }
        return result; // gap — no clip at this position
    }

    const ClipInfo* clip = seg.clip;
    assert(clip && "GetVideoFrame: CLIP segment has null clip pointer");

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

        // Wake prefetch if buffer running low during playback
        int dir = m_playhead_direction.load(std::memory_order_relaxed);
        if (dir != 0 && is_video_buffer_low(ts, timeline_frame, dir)) {
            tracks_lock.unlock();
            wake_prefetch_workers();
        }
        return result;
    }

    // ── Cache miss: nearest-frame fallback (cache_only) or sync decode ──

    // During playback (cache_only), prefetch adaptive stride may have decoded
    // a nearby frame but not this exact one. Search for the nearest cached
    // frame from the same clip in the playback direction.
    // Direction-aware: forward play only looks ahead, reverse only looks behind.
    // This prevents showing a frame the viewer already passed (visual reversal).
    // MAX_NEAREST_DISTANCE bounds the fallback: never show a frame from
    // hundreds of frames away (would display wrong content during stalls).
    static constexpr int64_t MAX_NEAREST_DISTANCE = 16;  // adaptive stride max (8) * 2
    if (cache_only) {
        const std::string& cid = clip->clip_id;
        auto lo = ts.video_cache.lower_bound(timeline_frame);
        const TrackState::CachedFrame* best = nullptr;
        int64_t best_dist = INT64_MAX;
        int dir = m_playhead_direction.load(std::memory_order_relaxed);

        // Check entry at or after timeline_frame (preferred for forward play)
        if (dir >= 0 && lo != ts.video_cache.end() && lo->second.clip_id == cid) {
            int64_t d = lo->first - timeline_frame;
            if (d < best_dist && d <= MAX_NEAREST_DISTANCE) { best = &lo->second; best_dist = d; }
        }
        // Check entry before timeline_frame (preferred for reverse play)
        if (dir <= 0 && lo != ts.video_cache.begin()) {
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

            if (dir != 0 && is_video_buffer_low(ts, timeline_frame, dir)) {
                tracks_lock.unlock();
                wake_prefetch_workers();
            }
            return result;
        }
    }

    int direction = m_playhead_direction.load(std::memory_order_relaxed);

    // Copy clip locals and release tracks_lock first (lock ordering).
    std::string media_path = clip->media_path;
    Rate clip_rate = clip->rate();
    std::string clip_id = clip->clip_id;
    size_t diag_cache_size = ts.video_cache.size();
    int64_t diag_buf_end = ts.video_buffer_end;
    tracks_lock.unlock();

    // Wake prefetch unconditionally on cache miss during playback
    if (direction != 0) {
        wake_prefetch_workers();
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
        char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
        EMP_LOG_DEBUG("CACHE MISS: %s tf=%lld sf=%lld cache=%zu buf_end=%lld",
            tbuf, (long long)timeline_frame, (long long)source_frame,
            diag_cache_size, diag_buf_end);
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

            while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                evict_video_cache_entry(tit->second);
            }

            cache[timeline_frame] = {clip_id, source_frame, result.frame,
                                     result.rotation, result.par_num, result.par_den,
                                     tit->second.video_cache_seq++};
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
// find_segment_at_us — microsecond segment finder (audio path)
// ============================================================================

SegmentUS TimelineMediaBuffer::find_segment_at_us(const TrackState& ts, TimeUS t_us) const {
    assert(m_seq_rate.num > 0 && "find_segment_at_us: SetSequenceRate not called");

    // Check if t_us falls inside any clip
    for (const auto& clip : ts.clips) {
        assert(clip.rate_den > 0 && "find_segment_at_us: clip has zero rate_den");
        TimeUS start = FrameTime::from_frame(clip.timeline_start, m_seq_rate).to_us();
        TimeUS end = FrameTime::from_frame(clip.timeline_end(), m_seq_rate).to_us();
        if (t_us >= start && t_us < end) {
            return SegmentUS{SegmentUS::CLIP, start, end, &clip};
        }
    }

    // Gap: find surrounding clip boundaries in microseconds
    TimeUS gap_start = std::numeric_limits<TimeUS>::min();
    TimeUS gap_end = std::numeric_limits<TimeUS>::max();

    for (const auto& clip : ts.clips) {
        TimeUS clip_end = FrameTime::from_frame(clip.timeline_end(), m_seq_rate).to_us();
        TimeUS clip_start = FrameTime::from_frame(clip.timeline_start, m_seq_rate).to_us();

        if (clip_end <= t_us) {
            if (clip_end > gap_start) gap_start = clip_end;
        }
        if (clip_start > t_us) {
            if (clip_start < gap_end) gap_end = clip_start;
        }
    }

    return SegmentUS{SegmentUS::GAP, gap_start, gap_end, nullptr};
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

    // Find segment at t0
    SegmentUS seg = find_segment_at_us(ts, t0);
    if (seg.type == SegmentUS::GAP) {
        return nullptr;
    }

    const ClipInfo* clip = seg.clip;
    assert(clip && "GetTrackAudio: CLIP segment has null clip pointer");
    assert(clip->rate_den > 0 && "GetTrackAudio: clip has zero rate_den");
    assert(clip->speed_ratio != 0.0f && "GetTrackAudio: clip has zero speed_ratio");

    // Clip boundaries from segment (already computed by find_segment_at_us)
    TimeUS clip_start_us = seg.start_us;
    TimeUS clip_end_us = seg.end_us;

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

    // Wake prefetch if audio buffer running low
    bool wake_needed = false;
    int dir = m_playhead_direction.load(std::memory_order_relaxed);
    if (dir != 0) {
        wake_needed = is_audio_buffer_low(ts, t0, dir);
    }

    // Copy locals before releasing lock
    std::string media_path = clip->media_path;
    float speed_ratio = clip->speed_ratio;
    TimeUS first_clip_end_us = clip_end_us;
    tracks_lock.unlock();

    if (wake_needed) {
        wake_prefetch_workers();
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

        SegmentUS next_seg = find_segment_at_us(tit->second, cursor);
        if (next_seg.type == SegmentUS::GAP) {
            // Skip past gap to next clip
            if (next_seg.end_us >= t1 || next_seg.end_us == std::numeric_limits<TimeUS>::max()) break;
            cursor = next_seg.end_us;
            continue;
        }

        const ClipInfo* next = next_seg.clip;
        assert(next && "GetTrackAudio: CLIP segment has null clip pointer");

        TimeUS next_start_us = next_seg.start_us;
        if (next_start_us >= t1) break;

        assert(next->rate_den > 0 && "GetTrackAudio: next clip has zero rate_den");
        assert(next->speed_ratio != 0.0f && "GetTrackAudio: next clip has zero speed_ratio");

        TimeUS next_end_us = next_seg.end_us;
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
// Prefetch buffer helpers
// ============================================================================

bool TimelineMediaBuffer::is_video_buffer_low(const TrackState& ts, int64_t playhead, int dir) const {
    if (ts.video_buffer_end < 0) return true;
    int64_t ahead = (dir > 0) ? (ts.video_buffer_end - playhead) : (playhead - ts.video_buffer_end);
    return ahead < VIDEO_PREFETCH_MIN;
}

bool TimelineMediaBuffer::is_audio_buffer_low(const TrackState& ts, TimeUS playhead_us, int dir) const {
    if (ts.audio_buffer_end < 0) return true;
    TimeUS ahead = (dir > 0) ? (ts.audio_buffer_end - playhead_us) : (playhead_us - ts.audio_buffer_end);
    return ahead < AUDIO_PREFETCH_MIN;
}

void TimelineMediaBuffer::wake_prefetch_workers() {
    m_jobs_cv.notify_all();
}

void TimelineMediaBuffer::discard_already_played_prefetch(const TrackId& track) {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto it = m_tracks.find(track);
    if (it == m_tracks.end()) return;
    auto& ts = it->second;

    int64_t playhead = m_playhead_frame.load(std::memory_order_relaxed);

    if (track.type == TrackType::Video) {
        if (ts.video_buffer_end < playhead) {
            ts.video_buffer_end = playhead;
        }
    } else {
        if (m_seq_rate.num > 0) {
            TimeUS playhead_us = FrameTime::from_frame(playhead, m_seq_rate).to_us();
            if (ts.audio_buffer_end < playhead_us) {
                ts.audio_buffer_end = playhead_us;
            }
        }
    }
}

bool TimelineMediaBuffer::frame_needed_for_composite(const TrackId& track, int64_t timeline_frame) const {
    // Caller must hold m_tracks_mutex
    return !is_video_obscured(track, timeline_frame);
}

std::unique_ptr<TimelineMediaBuffer::PrefetchClaimGuard>
TimelineMediaBuffer::claim_track_for_prefetch(
        const TrackId& track, std::unordered_set<TrackId, TrackIdHash>& set) {
    std::lock_guard<std::mutex> lock(m_jobs_mutex);
    // Try-claim: if another worker already claimed this track, back off.
    // Without this, multiple workers can pick the same track between
    // pick_video_track (snapshot) and claim (insert), causing duplicate
    // decodes on the same position — wasting all but one worker's effort.
    if (set.count(track)) return nullptr;
    set.insert(track);
    return std::make_unique<PrefetchClaimGuard>(&set, &m_jobs_mutex, track);
}

int TimelineMediaBuffer::stride_for_clip(const TrackId& track, const ClipInfo& clip) const {
    if (track.type == TrackType::Audio) return 1;

    assert(track.type == TrackType::Video && "stride_for_clip: unexpected track type");
    assert(clip.rate_num > 0 && clip.rate_den > 0 && "stride_for_clip: invalid clip rate");

    std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
    auto dit = m_decode_speed_cache.find(clip.media_path);
    if (dit == m_decode_speed_cache.end()) return 1;

    double frame_period_ms = 1000.0 * clip.rate_den / clip.rate_num;
    if (dit->second <= frame_period_ms * 1.5) return 1;

    // +1 padding: ceil gives the minimum stride to break even with decode cost.
    // Without padding, margin is ~20ms — any jitter causes permanent behind-ness.
    // With +1, margin is ~1 frame period (~40ms at 25fps), enough to absorb
    // I/O stalls, thread scheduling, and recover from brief deficits.
    int stride = static_cast<int>(std::ceil(dit->second / frame_period_ms)) + 1;
    return std::min(stride, MAX_STRIDE);
}

void TimelineMediaBuffer::set_already_fetched_video(const TrackId& track, int64_t pos) {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto it = m_tracks.find(track);
    if (it != m_tracks.end()) {
        // Use max() to never regress the watermark
        if (pos > it->second.video_buffer_end) {
            it->second.video_buffer_end = pos;
        }
    }
}

void TimelineMediaBuffer::set_already_fetched_audio(const TrackId& track, TimeUS pos) {
    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    auto it = m_tracks.find(track);
    if (it != m_tracks.end()) {
        if (pos > it->second.audio_buffer_end) {
            it->second.audio_buffer_end = pos;
        }
    }
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
    // 1. Stop playhead direction (idles prefetch workers + mix thread)
    m_playhead_direction.store(0, std::memory_order_relaxed);

    // 2. Clear pending decode-prep jobs, in-flight tracking, and prefetch claims.
    // Wake workers so they see direction==0 and park.
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        m_jobs.clear();
        m_pre_buffering.clear();
        m_video_prefetching.clear();
        m_audio_prefetching.clear();
    }
    m_jobs_cv.notify_all();

    // 3. Reset buffer_ends and per-clip EOF markers.
    // EOF markers must be cleared: they're an optimization to avoid repeated
    // decode attempts WITHIN a play session. Across sessions (stop → seek →
    // play), the playhead may be at a decodable position — stale EOF markers
    // would block GetVideoFrame's Play path (source_frame >= eof check).
    // Prefetch re-discovers the actual EOF boundary during the new session.
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
// Thread pool — continuous prefetch workers
// ============================================================================

void TimelineMediaBuffer::start_workers(int count) {
    m_shutdown.store(false);
    assert(count >= 2 && "start_workers: need >= 2 (at least 1 video + 1 audio worker)");
    // N-1 general workers (decode-prep + video prefetch) + 1 audio worker.
    // Audio can never be starved by a long video decode.
    for (int i = 0; i < count - 1; ++i) {
        m_workers.emplace_back(&TimelineMediaBuffer::prefetch_worker, this);
    }
    m_workers.emplace_back(&TimelineMediaBuffer::audio_prefetch_worker, this);
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
// SPEED_DETECT: "SPEED_DETECT:media_path" (one probe per file)
// READER_WARM: "V1:WARM:clip_id" (one warm per clip per track)
std::string TimelineMediaBuffer::job_key(const PreBufferJob& job) {
    if (job.type == PreBufferJob::SPEED_DETECT) {
        return "SPEED_DETECT:" + job.media_path;
    }
    char buf[8];
    snprintf(buf, sizeof(buf), "%c%d:",
             job.track.type == TrackType::Video ? 'V' : 'A',
             job.track.index);
    return std::string(buf) + "WARM:" + job.clip_id;
}

void TimelineMediaBuffer::submit_pre_buffer(const PreBufferJob& job) {
    std::lock_guard<std::mutex> lock(m_jobs_mutex);

    auto key = job_key(job);

    // Simple dedup: skip if same key is in-flight or queued
    if (m_pre_buffering.find(key) != m_pre_buffering.end()) return;

    for (const auto& j : m_jobs) {
        if (j.track == job.track && j.clip_id == job.clip_id &&
            j.type == job.type) return;
    }

    m_jobs.push_back(job);
    m_jobs.back().submitted_at = std::chrono::steady_clock::now();
    m_jobs_cv.notify_all();
}

// ============================================================================
// process_next_decode_prep_job — dequeue and execute one SPEED_DETECT or READER_WARM
// ============================================================================

bool TimelineMediaBuffer::process_next_decode_prep_job() {
    PreBufferJob job;
    std::string key;
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        if (m_jobs.empty()) return false;

        // Priority: SPEED_DETECT first, then READER_WARM
        int pick = -1;
        for (int i = static_cast<int>(m_jobs.size()) - 1; i >= 0; --i) {
            if (m_jobs[i].type == PreBufferJob::SPEED_DETECT) { pick = i; break; }
        }
        if (pick < 0) {
            for (int i = static_cast<int>(m_jobs.size()) - 1; i >= 0; --i) {
                if (m_jobs[i].type == PreBufferJob::READER_WARM) { pick = i; break; }
            }
        }
        if (pick < 0) return false;

        job = std::move(m_jobs[pick]);
        m_jobs.erase(m_jobs.begin() + pick);
        key = job_key(job);
        m_pre_buffering[key] = 0;
    }

    // RAII: remove from in-flight set when done
    auto guard = make_scope_exit([this, &key] {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        m_pre_buffering.erase(key);
    });

    if (job.type == PreBufferJob::SPEED_DETECT) {
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
                    m_decode_speed_cache[job.media_path] = record_ms;
                }
                EMP_LOG_DEBUG("SPEED_DETECT: %s clip=%.8s path=%s decode=%.1fms (wall=%.1fms)",
                    tbuf, job.clip_id.c_str(), job.media_path.c_str(), record_ms, wall_ms);
            } else {
                EMP_LOG_WARN("SPEED_DETECT: %s clip=%.8s decode failed", tbuf, job.clip_id.c_str());
            }
        }
    } else {
        // READER_WARM
        auto queue_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - job.submitted_at).count();
        if (queue_ms > WARM_QUEUE_WARN_MS) {
            EMP_LOG_WARN("WARM: queue wait %lldms for clip %s (threshold %dms)",
                    (long long)queue_ms, job.clip_id.c_str(), WARM_QUEUE_WARN_MS);
        }

        auto t0 = std::chrono::steady_clock::now();
        auto handle = acquire_reader(job.track, job.clip_id, job.media_path);
        auto acquire_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();

        if (!handle) {
            EMP_LOG_WARN("WARM: failed for clip %s path=%s (acquire=%lldms)",
                    job.clip_id.c_str(), job.media_path.c_str(), (long long)acquire_ms);
        }
        if (acquire_ms > WARM_ACQUIRE_WARN_MS) {
            EMP_LOG_WARN("WARM: acquire_reader took %lldms for clip %s (threshold %dms)",
                    (long long)acquire_ms, job.clip_id.c_str(), WARM_ACQUIRE_WARN_MS);
        }
    }
    return true;
}

// ============================================================================
// pick_video_track — find highest-index video track needing prefetch
// ============================================================================

bool TimelineMediaBuffer::pick_video_track(TrackId& out) {
    int direction = m_playhead_direction.load(std::memory_order_relaxed);
    if (direction == 0) return false;
    int64_t playhead = m_playhead_frame.load(std::memory_order_relaxed);

    std::unordered_set<TrackId, TrackIdHash> being_prefetched;
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        being_prefetched = m_video_prefetching;
    }

    // Fairness: pick the video track furthest behind playhead (most urgent).
    // Previous "highest index wins" caused permanent starvation of lower tracks
    // when the top track had slow decode (e.g. ProRes 4444 SW at 136ms/frame).
    TrackId most_urgent{TrackType::Video, -1};
    int64_t worst_buffer = std::numeric_limits<int64_t>::max();
    bool found = false;

    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    for (const auto& [tid, ts] : m_tracks) {
        if (tid.type != TrackType::Video) continue;
        if (ts.clips.empty()) continue;
        if (being_prefetched.count(tid)) continue;

        int64_t buffer_end = ts.video_buffer_end;
        if (buffer_end < 0) buffer_end = playhead;
        int64_t ahead = (direction > 0) ? (buffer_end - playhead) : (playhead - buffer_end);
        if (ahead >= VIDEO_PREFETCH_MAX) continue;  // this track is full

        if (ahead < worst_buffer) {
            most_urgent = tid;
            worst_buffer = ahead;
            found = true;
        }
    }

    if (found) out = most_urgent;
    return found;
}

// ============================================================================
// pick_audio_track — find audio track furthest behind playhead
// ============================================================================

bool TimelineMediaBuffer::pick_audio_track(TrackId& out) {
    int direction = m_playhead_direction.load(std::memory_order_relaxed);
    if (direction == 0) return false;
    if (m_seq_rate.num <= 0 || m_audio_fmt.sample_rate <= 0) return false;

    int64_t playhead = m_playhead_frame.load(std::memory_order_relaxed);
    TimeUS playhead_us = FrameTime::from_frame(playhead, m_seq_rate).to_us();

    std::unordered_set<TrackId, TrackIdHash> being_prefetched;
    {
        std::lock_guard<std::mutex> lock(m_jobs_mutex);
        being_prefetched = m_audio_prefetching;
    }

    TrackId most_urgent{TrackType::Audio, -1};
    TimeUS worst_buffer = std::numeric_limits<TimeUS>::max();
    bool found = false;

    std::lock_guard<std::mutex> lock(m_tracks_mutex);
    for (const auto& [tid, ts] : m_tracks) {
        if (tid.type != TrackType::Audio) continue;
        if (ts.clips.empty()) continue;
        if (being_prefetched.count(tid)) continue;

        TimeUS buffer_end = ts.audio_buffer_end;
        if (buffer_end < 0) buffer_end = playhead_us;
        TimeUS ahead = (direction > 0) ? (buffer_end - playhead_us) : (playhead_us - buffer_end);
        if (ahead >= AUDIO_PREFETCH_MAX) continue;  // this track is full

        if (ahead < worst_buffer) {
            most_urgent = tid;
            worst_buffer = ahead;
            found = true;
        }
    }

    if (found) out = most_urgent;
    return found;
}

// ============================================================================
// decode_into_cache — video: one frame decode + stride fill
// ============================================================================

void TimelineMediaBuffer::decode_into_cache(
        const TrackId& track, const Segment& seg, int64_t position, int stride,
        ReaderHandle& held_reader, std::string& held_clip_id,
        std::shared_ptr<Frame>& last_good_frame) {

    const ClipInfo* clip = seg.clip;
    assert(clip && "decode_into_cache: CLIP segment has null clip pointer");

    // Acquire reader only when clip changes (boundary crossing)
    if (clip->clip_id != held_clip_id || !held_reader) {
        held_reader = {};  // release old reader first
        held_reader = acquire_reader(track, clip->clip_id, clip->media_path);

        if (!held_reader) {
            // Undecodable clip — skip to clip end
            char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
            EMP_LOG_WARN("PREFETCH SKIP: %s clip=%.8s undecodable, advancing to %lld",
                tbuf, clip->clip_id.c_str(), (long long)clip->timeline_end());
            set_already_fetched_video(track, clip->timeline_end());
            held_clip_id.clear();
            return;
        }
        held_clip_id = clip->clip_id;
    }

    assert(clip->rate_num > 0 && "decode_into_cache: clip has zero rate_num");
    assert(clip->rate_den > 0 && "decode_into_cache: clip has zero rate_den");
    assert(clip->speed_ratio != 0.0f && "decode_into_cache: clip has zero speed_ratio");

    int64_t source_frame = clip->source_in +
        static_cast<int64_t>((position - clip->timeline_start) * clip->speed_ratio);

    // Retime duplicate: consecutive timeline frames can map to the same source
    // frame at slow speeds. Check if the previous timeline position already
    // cached this exact source frame + clip. Reuse it instead of re-decoding —
    // the decoder has already advanced past this PTS, so decode_frames_batch
    // would overshoot to the next frame, causing a 1-frame-ahead shift and
    // periodic backwards visual jumps at every duplicate-sf boundary.
    {
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track);
        if (tit != m_tracks.end()) {
            auto& cache = tit->second.video_cache;
            auto prev_it = cache.find(position - 1);
            if (prev_it != cache.end() &&
                prev_it->second.clip_id == clip->clip_id &&
                prev_it->second.source_frame == source_frame &&
                prev_it->second.frame) {
                // Reuse previous frame
                while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                    evict_video_cache_entry(tit->second);
                }
                const auto& info = held_reader->media_file()->info();
                TrackState::CachedFrame cf{clip->clip_id, source_frame,
                               prev_it->second.frame,
                               info.rotation, info.video_par_num, info.video_par_den,
                               tit->second.video_cache_seq++};
                cache[position] = cf;
                int fill_count = 1;
                for (int s = 1; s < stride; ++s) {
                    int64_t fill_tf = position + s;
                    if (fill_tf >= clip->timeline_end()) break;
                    while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                        evict_video_cache_entry(tit->second);
                    }
                    cf.insert_seq = tit->second.video_cache_seq++;
                    cache[fill_tf] = cf;
                    fill_count++;
                }
                {
                    char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
                    EMP_LOG_DEBUG("DECODE DUP: %s tf=%lld sf=%lld stride=%d filled=%d cache=%zu buf_end=%lld",
                        tbuf, (long long)position, (long long)source_frame,
                        stride, fill_count, cache.size(),
                        (long long)tit->second.video_buffer_end);
                }
                return;
            }
        }
    }

    const auto& info = held_reader->media_file()->info();
    int64_t file_frame = source_frame - info.start_tc;
    Rate clip_rate = clip->rate();
    FrameTime ft = FrameTime::from_frame(file_frame, clip_rate);

    auto result = held_reader->DecodeAt(ft);

    // Update decode speed cache (write-once: SPEED_DETECT is authoritative)
    float per_frame_ms = held_reader->LastBatchMsPerFrame();
    if (per_frame_ms > 0) {
        std::lock_guard<std::mutex> pool_lock(m_pool_mutex);
        if (m_decode_speed_cache.find(clip->media_path) == m_decode_speed_cache.end()) {
            m_decode_speed_cache[clip->media_path] = per_frame_ms;
        }
    }

    if (result.is_ok()) {
        last_good_frame = result.value();
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track);
        if (tit != m_tracks.end()) {
            auto& cache = tit->second.video_cache;
            while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                evict_video_cache_entry(tit->second);
            }
            TrackState::CachedFrame cf{clip->clip_id, source_frame, result.value(),
                           info.rotation, info.video_par_num, info.video_par_den,
                           tit->second.video_cache_seq++};
            cache[position] = cf;

            // Stride fill: populate cache at skipped positions with same frame
            int fill_count = 1;
            for (int s = 1; s < stride; ++s) {
                int64_t fill_tf = position + s;
                if (fill_tf >= clip->timeline_end()) break;
                while (cache.size() >= TrackState::MAX_VIDEO_CACHE) {
                    evict_video_cache_entry(tit->second);
                }
                cf.insert_seq = tit->second.video_cache_seq++;
                cache[fill_tf] = cf;
                fill_count++;
            }
            {
                char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
                EMP_LOG_DEBUG("DECODE OK: %s tf=%lld sf=%lld stride=%d filled=%d cache=%zu buf_end=%lld",
                    tbuf, (long long)position, (long long)source_frame,
                    stride, fill_count, cache.size(),
                    (long long)tit->second.video_buffer_end);
            }
        }
    } else {
        bool is_eof = (result.error().code == ErrorCode::EOFReached);
        EMP_LOG_WARN("PREFETCH: %s at tf=%lld sf=%lld clip=%s",
                is_eof ? "EOF" : "decode error",
                (long long)position, (long long)source_frame,
                clip->clip_id.c_str());

        if (is_eof) {
            std::lock_guard<std::mutex> tlock(m_tracks_mutex);
            auto tit = m_tracks.find(track);
            if (tit != m_tracks.end()) {
                auto& eof = tit->second.clip_eof_frame;
                auto eof_it = eof.find(clip->clip_id);
                if (eof_it == eof.end() || source_frame < eof_it->second) {
                    eof[clip->clip_id] = source_frame;
                }
                // Hold last good frame for remaining timeline frames
                if (last_good_frame) {
                    auto& cache = tit->second.video_cache;
                    int64_t clip_end = clip->timeline_end();
                    for (int64_t fill_tf = position; fill_tf < clip_end; ++fill_tf) {
                        if (cache.size() >= TrackState::MAX_VIDEO_CACHE) break;
                        int64_t fill_sf = clip->source_in +
                            static_cast<int64_t>((fill_tf - clip->timeline_start) * clip->speed_ratio);
                        cache[fill_tf] = {clip->clip_id, fill_sf,
                                          last_good_frame, info.rotation,
                                          info.video_par_num, info.video_par_den,
                                          tit->second.video_cache_seq++};
                    }
                }
                if (clip->timeline_end() > tit->second.video_buffer_end) {
                    tit->second.video_buffer_end = clip->timeline_end();
                }
            }
        }
    }
}

// ============================================================================
// decode_audio_into_cache — one audio chunk decode
// ============================================================================

void TimelineMediaBuffer::decode_audio_into_cache(
        const TrackId& track, const SegmentUS& seg,
        TimeUS position, TimeUS chunk_end) {

    const ClipInfo* clip = seg.clip;
    assert(clip && "decode_audio_into_cache: CLIP segment has null clip pointer");
    assert(clip->rate_num > 0 && "decode_audio_into_cache: clip has zero rate_num");
    assert(clip->rate_den > 0 && "decode_audio_into_cache: clip has zero rate_den");
    assert(clip->speed_ratio != 0.0f && "decode_audio_into_cache: clip has zero speed_ratio");

    TimeUS src_origin = FrameTime::from_frame(clip->source_in, clip->rate()).to_us();
    double sr_d = static_cast<double>(clip->speed_ratio);
    TimeUS src_t0 = src_origin + static_cast<int64_t>((position - seg.start_us) * sr_d);
    TimeUS src_t1 = src_origin + static_cast<int64_t>((chunk_end - seg.start_us) * sr_d);
    bool chunk_reversed = (src_t0 > src_t1);
    if (chunk_reversed) std::swap(src_t0, src_t1);

    auto reader = acquire_reader(track, clip->clip_id, clip->media_path);
    if (!reader) return;

    auto decode_result = reader->DecodeAudioRangeUS(src_t0, src_t1, m_audio_fmt);
    if (decode_result.is_error() || !decode_result.value() || decode_result.value()->frames() == 0) {
        if (decode_result.is_error()) {
            char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
            EMP_LOG_WARN("AUDIO PREFETCH: decode error on %s clip=%.8s src=[%lld..%lld]",
                         tbuf, clip->clip_id.c_str(), (long long)src_t0, (long long)src_t1);
        }
        return;
    }

    auto pcm = build_audio_output(decode_result.value(), src_t0, src_t1,
                                  position, chunk_end, std::abs(clip->speed_ratio), m_audio_fmt);
    if (chunk_reversed && pcm && pcm->frames() > 0) {
        reverse_interleaved(pcm->mutable_data_f32(), pcm->frames(), m_audio_fmt.channels);
    }
    if (pcm && pcm->frames() > 0) {
        std::lock_guard<std::mutex> tlock(m_tracks_mutex);
        auto tit = m_tracks.find(track);
        if (tit != m_tracks.end()) {
            auto& cache = tit->second.audio_cache;
            while (cache.size() >= TrackState::MAX_AUDIO_CACHE) {
                cache.erase(cache.begin());
            }
            cache.push_back({clip->clip_id, position, chunk_end, pcm});
            // audio_buffer_end updated by caller via set_already_fetched_audio (monotonic max)
        }
    }
}

// ============================================================================
// fill_prefetch — core prefetch loop (unified A/V, one frame per iteration)
// ============================================================================

void TimelineMediaBuffer::fill_prefetch(const TrackId& track) {
    // Claim this track so pick_*_track won't select it while we're filling
    auto& claim_set = (track.type == TrackType::Video)
        ? m_video_prefetching : m_audio_prefetching;
    auto claim_guard = claim_track_for_prefetch(track, claim_set);
    if (!claim_guard) return;  // another worker already filling this track

    // Capture generation at entry
    int64_t entry_gen;
    {
        std::lock_guard<std::mutex> lock(m_tracks_mutex);
        auto it = m_tracks.find(track);
        if (it == m_tracks.end()) return;
        entry_gen = it->second.prefetch_generation;
    }

    // Video: locals that persist across frames in the same clip
    ReaderHandle held_reader;
    std::string held_clip_id;
    std::shared_ptr<Frame> last_good_frame;

    if (track.type == TrackType::Video) {
        // ── Video prefetch: decode ONE frame then return ──
        // The worker loop re-picks the most urgent track each iteration,
        // so returning after each decode gives fair interleaving between
        // tracks with different decode speeds (e.g. V2 ProRes 4444 at
        // 136ms/frame vs V1 H264 at 12ms/frame).
        {
            int64_t diag_be;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(track);
                diag_be = (it != m_tracks.end()) ? it->second.video_buffer_end : -999;
            }
            char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
            int64_t ph = m_playhead_frame.load(std::memory_order_relaxed);
            EMP_LOG_DEBUG("fill_prefetch ENTER: %s buf_end=%lld playhead=%lld gen=%lld",
                tbuf, (long long)diag_be, (long long)ph, (long long)entry_gen);
        }
        while (true) {
            if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0)
                return;

            // Check generation
            int64_t current_gen;
            int64_t buffer_end;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(track);
                if (it == m_tracks.end()) return;
                current_gen = it->second.prefetch_generation;
                buffer_end = it->second.video_buffer_end;
            }
            if (current_gen != entry_gen) return;

            int64_t playhead = m_playhead_frame.load(std::memory_order_relaxed);
            if (buffer_end < 0) buffer_end = playhead;
            if (buffer_end >= playhead + VIDEO_PREFETCH_MAX) return;  // full

            // Find segment at buffer_end
            // Deep-copy ClipInfo under lock — seg.clip points into ts.clips vector
            // which can be reallocated by concurrent SetTrackClips after lock release.
            Segment seg;
            ClipInfo clip_copy;
            bool obscured = false;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(track);
                if (it == m_tracks.end()) return;
                seg = find_segment_at(it->second, buffer_end);
                if (seg.type == Segment::CLIP) {
                    assert(seg.clip && "fill_prefetch: CLIP segment has null clip pointer");
                    clip_copy = *seg.clip;
                    seg.clip = &clip_copy;
                    obscured = !frame_needed_for_composite(track, buffer_end);
                }
            }

            if (seg.type == Segment::GAP) {
                // Advance past gap
                if (seg.end < std::numeric_limits<int64_t>::max()) {
                    set_already_fetched_video(track, seg.end);
                } else {
                    set_already_fetched_video(track, playhead + VIDEO_PREFETCH_MAX);
                    return;
                }
                held_reader = {};
                held_clip_id.clear();
                continue;  // skip gaps without yielding (O(1), no decode)
            }

            if (obscured) {
                set_already_fetched_video(track, buffer_end + 1);
                continue;  // skip obscured without yielding (O(1), no decode)
            }

            // Decode one frame, then return to let worker re-pick most urgent track
            int stride = stride_for_clip(track, *seg.clip);
            {
                char tbuf[8]; track_str(track, tbuf, sizeof(tbuf));
                EMP_LOG_DEBUG("PREFETCH: %s tf=%lld stride=%d playhead=%lld clip=%.8s",
                    tbuf, (long long)buffer_end, stride, (long long)playhead,
                    seg.clip->clip_id.c_str());
            }
            decode_into_cache(track, seg, buffer_end, stride,
                              held_reader, held_clip_id, last_good_frame);
            set_already_fetched_video(track, buffer_end + stride);
            return;  // yield — worker re-picks
        }
    } else {
        // ── Audio prefetch loop ──
        assert(m_seq_rate.num > 0 && "fill_prefetch: audio requires SetSequenceRate");

        while (true) {
            if (m_shutdown.load() || m_playhead_direction.load(std::memory_order_relaxed) == 0)
                break;

            // Check generation
            int64_t current_gen;
            TimeUS buffer_end;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(track);
                if (it == m_tracks.end()) break;
                current_gen = it->second.prefetch_generation;
                buffer_end = it->second.audio_buffer_end;
            }
            if (current_gen != entry_gen) break;

            int64_t playhead = m_playhead_frame.load(std::memory_order_relaxed);
            TimeUS playhead_us = FrameTime::from_frame(playhead, m_seq_rate).to_us();
            if (buffer_end < 0) buffer_end = playhead_us;
            if (buffer_end >= playhead_us + AUDIO_PREFETCH_MAX) break;  // full

            // Find segment at buffer_end
            // Deep-copy ClipInfo under lock — seg.clip points into ts.clips vector
            // which can be reallocated by concurrent SetTrackClips after lock release.
            SegmentUS seg;
            ClipInfo clip_copy;
            {
                std::lock_guard<std::mutex> lock(m_tracks_mutex);
                auto it = m_tracks.find(track);
                if (it == m_tracks.end()) break;
                seg = find_segment_at_us(it->second, buffer_end);
                if (seg.type == SegmentUS::CLIP) {
                    assert(seg.clip && "fill_prefetch: audio CLIP segment has null clip pointer");
                    clip_copy = *seg.clip;
                    seg.clip = &clip_copy;
                }
            }

            if (seg.type == SegmentUS::GAP) {
                if (seg.end_us < std::numeric_limits<TimeUS>::max()) {
                    set_already_fetched_audio(track, seg.end_us);
                } else {
                    set_already_fetched_audio(track, playhead_us + AUDIO_PREFETCH_MAX);
                    break;
                }
                continue;
            }

            // Compute chunk range clamped to clip boundary
            TimeUS chunk_end = std::min(seg.end_us, buffer_end + AUDIO_REFILL_SIZE);
            if (chunk_end <= buffer_end) {
                set_already_fetched_audio(track, seg.end_us);
                continue;
            }

            decode_audio_into_cache(track, seg, buffer_end, chunk_end);
            set_already_fetched_audio(track, chunk_end);
        }
    }
}

// ============================================================================
// prefetch_worker — handles decode-prep jobs + video prefetch
// ============================================================================

void TimelineMediaBuffer::prefetch_worker() {
    while (!m_shutdown.load()) {
        // Priority 1: decode-prep jobs (SPEED_DETECT, READER_WARM)
        if (process_next_decode_prep_job()) continue;

        // Priority 2: video prefetch
        // No discard_already_played_prefetch for video. discard forces the reader
        // to decode N intermediate frames to reach the snapped-forward target —
        // O(gap) per call. Sequential decode from buf_end is O(1 frame) per call.
        // The "wasted" behind-playhead entries are evicted naturally.
        TrackId target{TrackType::Video, 0};
        if (pick_video_track(target)) {
            fill_prefetch(target);
            continue;
        }

        // Nothing to do — sleep on CV with 100ms timeout
        {
            std::unique_lock<std::mutex> lock(m_jobs_mutex);
            m_jobs_cv.wait_for(lock, std::chrono::milliseconds(100), [this] {
                return m_shutdown.load() || !m_jobs.empty();
            });
        }
    }
}

// ============================================================================
// audio_prefetch_worker — handles audio prefetch only
// ============================================================================

void TimelineMediaBuffer::audio_prefetch_worker() {
    while (!m_shutdown.load()) {
        TrackId target{TrackType::Audio, 0};
        if (pick_audio_track(target)) {
            m_audio_work_pending.store(false, std::memory_order_relaxed);
            discard_already_played_prefetch(target);
            fill_prefetch(target);
            continue;
        }

        // Nothing to do — sleep on CV until woken by SetPlayhead (discontinuity,
        // low buffer, or cold start) or shutdown. 50ms timeout as safety net.
        m_audio_work_pending.store(false, std::memory_order_relaxed);
        {
            std::unique_lock<std::mutex> lock(m_jobs_mutex);
            m_jobs_cv.wait_for(lock, std::chrono::milliseconds(50), [this] {
                return m_shutdown.load() ||
                       m_audio_work_pending.load(std::memory_order_relaxed);
            });
        }
    }
}

} // namespace emp
