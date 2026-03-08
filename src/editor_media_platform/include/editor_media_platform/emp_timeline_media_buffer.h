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
#include <unordered_set>
#include <mutex>
#include <list>
#include <thread>
#include <condition_variable>
#include <atomic>
#include <functional>
#include <chrono>

namespace emp {

// Track type: video or audio (prevents ID collision between track kinds)
enum class TrackType { Video, Audio };

// Mix parameter for one audio track (volume already resolves solo/mute on Lua side)
struct MixTrackParam {
    int track_index;
    float volume;  // 0.0 = muted, 1.0 = full
};

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
    Rate rate() const {
        assert(rate_num > 0 && "ClipInfo::rate: rate_num must be positive");
        assert(rate_den > 0 && "ClipInfo::rate: rate_den must be positive");
        return Rate{rate_num, rate_den};
    }
};

// Video decode result (returned to Lua per track)
struct VideoResult {
    std::shared_ptr<Frame> frame; // nullptr = gap or offline
    std::string clip_id;
    std::string media_path;       // source file (for offline display, diagnostics)
    int rotation;
    int32_t par_num = 1;          // pixel aspect ratio (1:1 = square pixels)
    int32_t par_den = 1;
    int64_t source_frame;         // file-relative frame index
    int32_t clip_fps_num, clip_fps_den;
    int64_t clip_start_frame;     // timeline coords
    int64_t clip_end_frame;       // timeline coords
    bool offline;
    std::string error_msg;   // populated when offline=true (from m_offline Error)
    std::string error_code;  // structured code: "FileNotFound", "Unsupported", etc.
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

    // Append clips to a track. Dedup by clip_id, re-sort by timeline_start.
    // Does NOT invalidate existing readers (unlike SetTrackClips which replaces all).
    // Pre-warms readers for genuinely new clips only.
    void AddClips(TrackId track, std::vector<ClipInfo> clips);

    // Remove all clips on all tracks. Invalidates readers, clears caches.
    void ClearAllClips();

    // Transport hint for pre-buffer direction
    void SetPlayhead(int64_t frame, int direction, float speed);

    // Constant-time per-track video access.
    // cache_only=true: return cached frame or nullptr (no sync decode).
    // Play path uses cache_only=true — all decode on REFILL workers.
    // Park/Seek uses cache_only=false — sync decode on caller's thread.
    VideoResult GetVideoFrame(TrackId track, int64_t timeline_frame, bool cache_only = false);

    // Video track IDs with clips loaded, sorted descending (topmost first).
    // Thread-safe: acquires m_tracks_mutex internally.
    std::vector<int> GetVideoTrackIds();

    // Per-track audio access
    // Returns nullptr for gaps (Lua fills with silence)
    std::shared_ptr<PcmChunk> GetTrackAudio(TrackId track, TimeUS t0, TimeUS t1,
                                             const AudioFormat& fmt);

    // Sequence rate (required before GetTrackAudio — converts timeline frames to us)
    void SetSequenceRate(int32_t num, int32_t den);

    // Audio format for pre-buffer (call once before playback)
    void SetAudioFormat(const AudioFormat& fmt);

    // ── Autonomous pre-mixed audio ──

    // Tell TMB what tracks to pre-mix. Invalidates mixed cache.
    // Mix thread wakes and refills ahead of playhead.
    void SetAudioMixParams(const std::vector<MixTrackParam>& params, const AudioFormat& fmt);

    // Non-blocking cache read. Sync fallback on miss (startup/seek).
    // Returns nullptr if no mix params set.
    std::shared_ptr<PcmChunk> GetMixedAudio(TimeUS t0, TimeUS t1);

    // Configuration
    void SetMaxReaders(int max);

    // Probe file without buffering (for import)
    static Result<MediaFileInfo> ProbeFile(const std::string& path);

    // Diagnostics: count of GetVideoFrame calls that required a Reader decode
    // (TMB cache miss). Reset with ResetVideoCacheMissCount().
    int64_t GetVideoCacheMissCount() const { return m_video_cache_misses.load(); }
    void ResetVideoCacheMissCount() { m_video_cache_misses.store(0); }

    // Probe decode speed: returns measured ms-per-frame for a media path,
    // or -1.0f if that path has not been probed yet. Thread-safe.
    float GetProbeDecodeMs(const std::string& media_path) const;

    // Next clip after timeline_frame on a track. Returns true + populates out
    // if found. Thread-safe (locks internally).
    bool GetNextClipOnTrack(TrackId track, int64_t timeline_frame, ClipInfo& out) const;

    // Remove a path from the offline blacklist (called when FS watcher
    // detects a previously-missing file has reappeared).
    void ClearOffline(const std::string& path);

    // Stop all background decode work (REFILL workers + pre-buffer jobs).
    // Called on playback stop to release HW decoder sessions immediately.
    // REFILL is restarted on next play via SetPlayhead().
    void ParkReaders();

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
    void log_pool_state(const char* action, const TrackId& track,
                        const std::string& clip_id, bool is_hw);

    mutable std::mutex m_pool_mutex;
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
            int rotation = 0;
            int32_t par_num = 1;
            int32_t par_den = 1;
        };
        std::map<int64_t, CachedFrame> video_cache; // key = timeline_frame
        // Must hold at least 2 × VIDEO_HIGH_WATER (96) so current clip + next
        // clip pre-buffer don't thrash each other via eviction.
        static constexpr size_t MAX_VIDEO_CACHE = 144;

        // Audio PCM cache (pre-buffered at clip boundaries)
        struct CachedAudio {
            std::string clip_id;
            TimeUS timeline_t0;
            TimeUS timeline_t1;
            std::shared_ptr<PcmChunk> pcm;
        };
        std::vector<CachedAudio> audio_cache;
        // 2s of audio at AUDIO_REFILL_SIZE=200ms per chunk = 10 chunks.
        // 12 gives headroom for boundary overlaps.
        static constexpr size_t MAX_AUDIO_CACHE = 12;

        // Watermark buffer tracking: furthest timeline position with submitted decode.
        // -1 = cold (no refill submitted yet). Updated by REFILL worker, reset by
        // SetTrackClips (clip change), ParkReaders (stop), direction change.
        int64_t video_buffer_end = -1;    // timeline frame
        TimeUS audio_buffer_end = -1;     // microseconds

        // Generation counter: incremented by SetTrackClips on clip list change.
        // REFILL jobs capture the generation at submission; worker aborts early
        // on mismatch (stale REFILL from pre-SetTrackClips clip list).
        int64_t refill_generation = 0;

        // Per-clip EOF: first undecodeble source frame. When DecodeAt fails
        // (EOF, codec error), record clip_id → source_frame. GetVideoFrame
        // checks this before submitting on-demand jobs — avoids repeated
        // decode attempts for frames beyond the file's actual frame count.
        // Cleared on SetTrackClips (clip list may change).
        std::unordered_map<std::string, int64_t> clip_eof_frame;
    };

    mutable std::mutex m_tracks_mutex;
    std::unordered_map<TrackId, TrackState, TrackIdHash> m_tracks;

    // Find clip at timeline_frame in track's clip list
    const ClipInfo* find_clip_at(const TrackState& ts, int64_t timeline_frame) const;
    // Find first clip starting after timeline_frame (gap-skip for video REFILL)
    const ClipInfo* find_next_clip_after(const TrackState& ts, int64_t timeline_frame) const;

    // Find clip at timeline microsecond position (for audio path)
    // Requires m_seq_rate to be set
    const ClipInfo* find_clip_at_us(const TrackState& ts, TimeUS t_us) const;
    // Find first clip starting at or after t_us (gap-skip for audio REFILL)
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
        enum Type { DECODE_PROBE, VIDEO_REFILL, AUDIO_REFILL, READER_WARM };
        Type type = VIDEO_REFILL;

        TrackId track{TrackType::Video, 0};
        std::string clip_id;
        std::string media_path;

        int direction = 1;            // playback direction (+1 forward, -1 reverse)
        float speed_ratio = 1.0f;    // video: source_range/timeline_duration; audio: seq_fps/media_fps

        // VIDEO_REFILL fields (watermark-driven)
        int64_t refill_from_frame = 0;   // first timeline frame to decode
        int refill_count = 0;             // number of frames to decode

        // AUDIO_REFILL fields (watermark-driven)
        TimeUS refill_from_us = 0;       // start of refill range (timeline us)
        TimeUS refill_to_us = 0;         // end of refill range (timeline us)

        // DECODE_PROBE fields — single-frame decode to measure codec speed.
        // Highest priority: one frame, seeds m_decode_ms for predictive stride.
        int64_t probe_source_in = 0;
        int32_t probe_rate_num = 0;
        int32_t probe_rate_den = 1;

        // Generation counter — REFILL aborts if track's generation has advanced
        int64_t generation = 0;

        // WARM timing: set by submit_pre_buffer, checked by worker_loop
        std::chrono::steady_clock::time_point submitted_at{};
    };

    void start_workers(int count);
    void stop_workers();
    void worker_loop();
    void submit_pre_buffer(const PreBufferJob& job);
    static std::string job_key(const PreBufferJob& job);

    std::vector<std::thread> m_workers;
    std::mutex m_jobs_mutex;
    std::condition_variable m_jobs_cv;
    std::vector<PreBufferJob> m_jobs;
    // Keys of jobs currently being processed by workers (in-flight dedup).
    // Value = REFILL generation (allows new-gen REFILLs past stale in-flight).
    // Non-REFILL jobs use generation 0. Protected by m_jobs_mutex.
    std::unordered_map<std::string, int64_t> m_pre_buffering;
    std::atomic<bool> m_shutdown{false};

    // ── Sequence rate (for timeline frame → us conversion) ──
    Rate m_seq_rate{0, 1};

    // ── Audio format (for pre-buffer — set once before playback) ──
    AudioFormat m_audio_fmt{SampleFormat::F32, 0, 0};

    // ── Watermark-driven buffer constants ──
    // High water: stop filling when buffer_end is this far ahead of playhead
    static constexpr int64_t VIDEO_HIGH_WATER = 96;     // ~4s @24fps
    // Low water: trigger refill when buffer_end is only this far ahead
    static constexpr int64_t VIDEO_LOW_WATER = 48;      // ~2s @24fps
    // Max frames per REFILL worker job (bounds batch size)
    static constexpr int VIDEO_REFILL_SIZE = 48;

    static constexpr TimeUS AUDIO_HIGH_WATER = 2000000;  // 2s
    static constexpr TimeUS AUDIO_LOW_WATER = 500000;    // 0.5s
    static constexpr TimeUS AUDIO_REFILL_SIZE = 200000;  // 200ms

    // Probe window: scan this far ahead of playhead for unprobed media paths.
    // Must be >> HIGH_WATER so probes complete well before REFILL reaches the clip.
    static constexpr int64_t PROBE_WINDOW = 288;      // ~12s @24fps

    // WARM diagnostics: queue wait >200ms = workers starved by REFILL (software)
    //                   acquire >1000ms = drive I/O or codec init slow (environment)
    static constexpr int WARM_QUEUE_WARN_MS = 200;
    static constexpr int WARM_ACQUIRE_WARN_MS = 1000;

    // (PRE_BUFFER_THRESHOLD removed — watermark VIDEO_HIGH/LOW_WATER replaces it)

    // ── Watermark check + submit methods ──
    // Called from GetVideoFrame/GetTrackAudio cache-hit paths during playback.
    // Caller must NOT hold m_tracks_mutex (methods lock internally).
    void check_video_watermark(TrackId track, int64_t playhead, int direction);
    void submit_video_refill(TrackId track, int64_t playhead, int direction);
    void check_audio_watermark(TrackId track, TimeUS playhead_us, int direction);
    void submit_audio_refill(TrackId track, TimeUS playhead_us, int direction);

    // ── Playhead state ──
    std::atomic<int64_t> m_playhead_frame{0};
    std::atomic<int> m_playhead_direction{0};
    std::atomic<float> m_playhead_speed{1.0f};

    // ── Autonomous pre-mixed audio ──

    // Mixed audio cache (internal, protected by m_mix_mutex)
    struct MixedAudioCache {
        std::vector<float> data;  // interleaved samples
        TimeUS start_us = 0;
        TimeUS end_us = 0;
        int32_t sample_rate = 0;
        int32_t channels = 0;
        int direction = 0;        // direction cache was filled for

        bool covers(TimeUS t0, TimeUS t1) const;
        std::shared_ptr<PcmChunk> extract(TimeUS t0, TimeUS t1) const;
        void append(const std::shared_ptr<PcmChunk>& chunk, int dir);
        void evict_behind(TimeUS playhead_us, int dir);
        void clear();
    };

    // Execute mix for a time range (calls GetTrackAudio per track, sums with volume)
    // Thread-safe: does not hold m_mix_mutex
    std::shared_ptr<PcmChunk> execute_mix_range(
        const std::vector<MixTrackParam>& params,
        const AudioFormat& fmt, TimeUS t0, TimeUS t1);

    // Mix thread loop (autonomous pre-mixing)
    void mix_thread_loop();
    void start_mix_thread();
    void stop_mix_thread();

    std::thread m_mix_thread;
    std::mutex m_mix_mutex;
    std::condition_variable m_mix_cv;
    std::atomic<bool> m_mix_shutdown{false};

    // Protected by m_mix_mutex
    std::vector<MixTrackParam> m_audio_mix_params;
    AudioFormat m_audio_mix_fmt{SampleFormat::F32, 0, 0};
    bool m_mix_params_changed = false;
    MixedAudioCache m_mixed_cache;

    // ── Decode speed probing ──
    // Measured ms-per-frame keyed by media path. Populated by gap-probe
    // (single decode during gap-skip) and REFILL adaptive stride. Protected
    // by m_pool_mutex (colocated with reader pool — probing acquires a reader).
    std::unordered_map<std::string, float> m_decode_ms;

    // ── Diagnostics ──
    std::atomic<int64_t> m_video_cache_misses{0};
};

} // namespace emp
