#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <cassert>
#include <algorithm>
#include <cmath>

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
                int64_t entry_frame = (direction >= 0)
                    ? next->source_in
                    : next->source_in + next->duration - 1;
                int64_t entry_tl_frame = (direction >= 0)
                    ? next->timeline_start
                    : next->timeline_end() - 1;

                submit_pre_buffer({
                    tid,
                    next->clip_id,
                    next->media_path,
                    entry_frame,
                    entry_tl_frame,
                    next->rate()
                });
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
// GetTrackAudio (Phase 2b — stub for now)
// ============================================================================

std::shared_ptr<PcmChunk> TimelineMediaBuffer::GetTrackAudio(
        int track_id, TimeUS t0, TimeUS t1, const AudioFormat& fmt) {
    // Phase 2b will implement this
    (void)track_id; (void)t0; (void)t1; (void)fmt;
    return nullptr;
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

    // De-duplicate: don't submit if same (track_id, clip_id) already queued
    for (const auto& j : m_jobs) {
        if (j.track_id == job.track_id && j.clip_id == job.clip_id) {
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
    }
}

} // namespace emp
