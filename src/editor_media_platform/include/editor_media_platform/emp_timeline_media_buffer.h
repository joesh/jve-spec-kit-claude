#pragma once

#include "emp_media_file.h"
#include "emp_reader.h"
#include "emp_frame.h"
#include "emp_audio.h"
#include "emp_errors.h"
#include "emp_time.h"

#include <cassert>
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <mutex>
#include <list>
#include <thread>
#include <condition_variable>
#include <atomic>
#include <functional>

namespace emp {

// Track type: video or audio (prevents ID collision between track kinds)
enum class TrackType { Video, Audio };

// Composite track identifier — uniquely identifies a track in TMB
struct TrackId {
    TrackType type;
    int index;

    bool operator==(const TrackId& o) const {
        return type == o.type && index == o.index;
    }
    bool operator!=(const TrackId& o) const { return !(*this == o); }
    bool operator<(const TrackId& o) const {
        if (type != o.type) return type < o.type;
        return index < o.index;
    }
};

struct TrackIdHash {
    size_t operator()(const TrackId& id) const {
        return std::hash<int>()(static_cast<int>(id.type)) ^ (std::hash<int>()(id.index) << 1);
    }
};

// Clip layout entry (passed from Lua per track)
struct ClipInfo {
    std::string clip_id;
    std::string media_path;
    int64_t timeline_start;       // timeline frames
    int64_t duration;             // timeline frames
    int64_t source_in;            // source frames (absolute TC space)
    int32_t rate_num, rate_den;   // clip rate (for frame→us conversion)
    float speed_ratio;            // conform: seq_fps / media_fps (1.0 = none)

    int64_t timeline_end() const { return timeline_start + duration; }
    Rate rate() const { return Rate{rate_num, rate_den}; }
};

// Video decode result (returned to Lua per track)
struct VideoResult {
    std::shared_ptr<Frame> frame; // nullptr = gap or offline
    std::string clip_id;
    std::string media_path;       // source file (for offline display, diagnostics)
    int rotation;
    int64_t source_frame;         // file-relative frame index
    int32_t clip_fps_num, clip_fps_den;
    int64_t clip_start_frame;     // timeline coords
    int64_t clip_end_frame;       // timeline coords
    bool offline;
};

// Timeline media buffer — owns readers and clip layout per track,
// provides constant-time access to decoded video frames and audio PCM.
class TimelineMediaBuffer {
public:
    static std::unique_ptr<TimelineMediaBuffer> Create(int pool_threads = 2);
    ~TimelineMediaBuffer();

    // Per-track clip layout (call incrementally as playhead moves).
    // Lua passes current clip + next 1-3 clips per track.
    void SetTrackClips(TrackId track, const std::vector<ClipInfo>& clips);

    // Transport hint for pre-buffer direction
    void SetPlayhead(int64_t frame, int direction, float speed);

    // Constant-time per-track video access
    VideoResult GetVideoFrame(TrackId track, int64_t timeline_frame);

    // Per-track audio access
    // Returns nullptr for gaps (Lua fills with silence)
    std::shared_ptr<PcmChunk> GetTrackAudio(TrackId track, TimeUS t0, TimeUS t1,
                                             const AudioFormat& fmt);

    // Sequence rate (required before GetTrackAudio — converts timeline frames to us)
    void SetSequenceRate(int32_t num, int32_t den);

    // Audio format for pre-buffer (call once before playback)
    void SetAudioFormat(const AudioFormat& fmt);

    // Configuration
    void SetMaxReaders(int max);

    // Probe file without buffering (for import)
    static Result<MediaFileInfo> ProbeFile(const std::string& path);

    // Diagnostics: count of GetVideoFrame calls that required a Reader decode
    // (TMB cache miss). Reset with ResetVideoCacheMissCount().
    int64_t GetVideoCacheMissCount() const { return m_video_cache_misses.load(); }
    void ResetVideoCacheMissCount() { m_video_cache_misses.store(0); }

    // Lifecycle
    void ReleaseTrack(TrackId track);
    void ReleaseAll();

private:
    TimelineMediaBuffer();

    // ── Reader Pool ──
    struct PoolEntry {
        std::string path;
        std::shared_ptr<MediaFile> media_file;
        std::shared_ptr<Reader> reader;
        TrackId track;       // which track opened this reader
        int64_t last_used;  // monotonic counter for LRU
        std::shared_ptr<std::mutex> use_mutex;  // exclusive access during decode
    };

    // RAII handle — holds reader + exclusive lock, released on destruction
    struct ReaderHandle {
        std::shared_ptr<Reader> reader;
        std::unique_lock<std::mutex> lock;

        bool valid() const { return reader != nullptr; }
        Reader* operator->() const {
            assert(reader && "ReaderHandle::operator->: dereferencing invalid handle");
            return reader.get();
        }
        explicit operator bool() const { return valid(); }
    };

    ReaderHandle acquire_reader(TrackId track, const std::string& clip_id,
                                const std::string& path);
    void release_reader(TrackId track, const std::string& clip_id);
    void evict_lru_reader();

    std::mutex m_pool_mutex;
    // Key: (track, clip_id) → each clip gets its own reader/decode session
    // (avoids cache thrashing when two clips from the same file have different source positions)
    std::map<std::pair<TrackId, std::string>, PoolEntry> m_readers;
    int m_max_readers = 16;
    int64_t m_pool_clock = 0;  // monotonic counter for LRU ordering

    // Paths that failed to open (offline media)
    std::unordered_map<std::string, Error> m_offline;

    // ── Per-track state ──
    struct TrackState {
        std::vector<ClipInfo> clips;
        // Video frame cache: source_frame → decoded frame (per clip_id)
        struct CachedFrame {
            std::string clip_id;
            int64_t source_frame;
            std::shared_ptr<Frame> frame;
        };
        std::map<int64_t, CachedFrame> video_cache; // key = timeline_frame
        static constexpr size_t MAX_VIDEO_CACHE = 72;

        // Audio PCM cache (pre-buffered at clip boundaries)
        struct CachedAudio {
            std::string clip_id;
            TimeUS timeline_t0;
            TimeUS timeline_t1;
            std::shared_ptr<PcmChunk> pcm;
        };
        std::vector<CachedAudio> audio_cache;
        static constexpr size_t MAX_AUDIO_CACHE = 4;
    };

    std::mutex m_tracks_mutex;
    std::unordered_map<TrackId, TrackState, TrackIdHash> m_tracks;

    // Find clip at timeline_frame in track's clip list
    const ClipInfo* find_clip_at(const TrackState& ts, int64_t timeline_frame) const;

    // Find clip at timeline microsecond position (for audio path)
    // Requires m_seq_rate to be set
    const ClipInfo* find_clip_at_us(const TrackState& ts, TimeUS t_us) const;

    // Find first clip starting at or after t_us (for boundary spanning)
    const ClipInfo* find_next_clip_at_us(const TrackState& ts, TimeUS t_us) const;

    // Check audio cache for pre-buffered PCM covering [seg_t0, seg_t1) for clip_id
    // Returns sub-range PcmChunk on hit (full coverage required), nullptr on miss
    std::shared_ptr<PcmChunk> check_audio_cache(
        TrackState& ts, const std::string& clip_id,
        TimeUS seg_t0, TimeUS seg_t1, const AudioFormat& fmt) const;

    // Build output PcmChunk: trim decoded audio to source range, conform, rebase to timeline
    std::shared_ptr<PcmChunk> build_audio_output(
        const std::shared_ptr<PcmChunk>& decoded,
        TimeUS source_t0, TimeUS source_t1,
        TimeUS timeline_t0, TimeUS timeline_t1,
        float speed_ratio, const AudioFormat& fmt) const;

    // ── Pre-buffer thread pool ──
    struct PreBufferJob {
        enum Type { VIDEO, AUDIO };
        Type type = VIDEO;

        TrackId track{TrackType::Video, 0};
        std::string clip_id;
        std::string media_path;

        // VIDEO fields
        int64_t source_frame = 0;
        int64_t timeline_frame = 0;
        Rate rate{0, 1};
        int direction = 1;            // playback direction (+1 forward, -1 reverse)
        int64_t clip_duration = 0;    // clip length in frames (bounds batch size)

        // AUDIO fields
        TimeUS source_t0 = 0;
        TimeUS source_t1 = 0;
        TimeUS timeline_t0 = 0;
        TimeUS timeline_t1 = 0;
        float speed_ratio = 1.0f;
    };

    void start_workers(int count);
    void stop_workers();
    void worker_loop();
    void submit_pre_buffer(const PreBufferJob& job);

    std::vector<std::thread> m_workers;
    std::mutex m_jobs_mutex;
    std::condition_variable m_jobs_cv;
    std::vector<PreBufferJob> m_jobs;
    std::atomic<bool> m_shutdown{false};

    // ── Sequence rate (for timeline frame → us conversion) ──
    Rate m_seq_rate{0, 1};

    // ── Audio format (for pre-buffer — set once before playback) ──
    AudioFormat m_audio_fmt{SampleFormat::F32, 0, 0};

    // ── Playhead state ──
    std::atomic<int64_t> m_playhead_frame{0};
    std::atomic<int> m_playhead_direction{0};
    std::atomic<float> m_playhead_speed{1.0f};

    // ── Diagnostics ──
    std::atomic<int64_t> m_video_cache_misses{0};
};

} // namespace emp
