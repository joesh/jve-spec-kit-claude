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

// TC origin override for a media file (FR-004).
// When a media file's container TC doesn't match the displayed TC
// (Resolve "Set Timecode" override), the caller provides the correct
// first_frame_tc and first_sample_tc to use instead of the probed values.
struct TcOverride {
    int64_t first_frame_tc;   // video: frames at media rate
    int64_t first_sample_tc;  // audio: samples at sample rate
};

// Clip layout entry (passed from Lua per track)
struct ClipInfo {
    std::string clip_id;
    std::string media_path;
    int64_t sequence_start;       // timeline frames
    int64_t duration;             // timeline frames
    int64_t source_in;            // source frames (absolute TC space)
    int32_t rate_num, rate_den;   // clip rate (for frame→us conversion)
    float speed_ratio;            // conform: seq_fps / media_fps (1.0 = none)
    bool offline = false;         // true = media file not found, generate beep
    float volume = 1.0f;         // clip gain (linear): applied before track fader
    int32_t source_channel = -1; // audio: which file channel this clip decodes,
                                 // 0-based. -1 = composite (downmix all channels,
                                 // the "Adaptive" default). >=0 = extract that one
                                 // channel, duplicated to both stereo outputs.

    int64_t sequence_end() const { return sequence_start + duration; }
    Rate rate() const {
        assert(rate_num > 0 && "ClipInfo::rate: rate_num must be positive");
        assert(rate_den > 0 && "ClipInfo::rate: rate_den must be positive");
        return Rate{rate_num, rate_den};
    }

    // True when `other` produces identical decode output for this clip.
    // Used by SetTrackClips to skip redundant replace cycles when Lua
    // re-posts the same clip list every tick.
    //
    // MUST include every field whose change affects decode or playback:
    // adding a field to ClipInfo without adding it here silently breaks
    // the refresh path (Joe's "reconnect → audio keeps beeping" repro
    // was caused by `offline` and `volume` being omitted). Adding the
    // field in exactly one place keeps the invariant local.
    bool has_same_decode_inputs(const ClipInfo& other) const {
        return clip_id       == other.clip_id
            && media_path    == other.media_path
            && sequence_start == other.sequence_start
            && duration      == other.duration
            && source_in     == other.source_in
            && rate_num      == other.rate_num
            && rate_den      == other.rate_den
            && speed_ratio   == other.speed_ratio
            && offline       == other.offline
            && volume        == other.volume
            && source_channel == other.source_channel;
    }
};

// Segment: a contiguous region of the timeline, either a clip or a gap.
// Every timeline position belongs to exactly one segment.
struct Segment {
    enum Type { CLIP, GAP };
    Type type;
    int64_t start;            // timeline frame (inclusive)
    int64_t end;              // timeline frame (exclusive)
    const ClipInfo* clip;     // non-null iff type == CLIP
};

// Microsecond variant (audio path)
struct SegmentUS {
    enum Type { CLIP, GAP };
    Type type;
    TimeUS start_us;          // timeline microseconds (inclusive)
    TimeUS end_us;            // timeline microseconds (exclusive)
    const ClipInfo* clip;     // non-null iff type == CLIP
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
    // FCP7-ladder boundary: above this speed, the engine treats playback as
    // shuttle (free-running video, sparse cache, widened consumer bound).
    // Single owner — PlaybackController consumes this same constant.
    static constexpr float SHUTTLE_FREE_RUN_SPEED = 2.0f;

    // Explicit pool sizing: 0 = synchronous (no workers), or >= 3 (1 prep + 1 video + 1 audio).
    // See start_workers() for the rationale on the 3-thread minimum.
    static std::unique_ptr<TimelineMediaBuffer> Create(int pool_threads);

    // No-arg convenience overload: picks the smallest valid async pool. The default lives
    // in the .cpp next to start_workers() so the invariant and the default update together.
    // Callers who want sync-mode (tests, headless tooling) must pass 0 explicitly.
    static std::unique_ptr<TimelineMediaBuffer> Create();
    ~TimelineMediaBuffer();

    // Per-track clip layout (call incrementally as playhead moves).
    // Lua passes current clip + next 1-3 clips per track.
    void SetTrackClips(TrackId track, const std::vector<ClipInfo>& clips);

    // Append clips to a track. Dedup by clip_id, re-sort by sequence_start.
    // Does NOT invalidate existing readers (unlike SetTrackClips which replaces all).
    // Pre-warms readers for genuinely new clips only.
    void AddClips(TrackId track, std::vector<ClipInfo> clips);

    // Remove all clips on all tracks. Invalidates readers, clears caches.
    void ClearAllClips();

    // Transport hint for pre-buffer direction
    void SetPlayhead(int64_t frame, int direction, float speed);

    // Constant-time per-track video access.
    // cache_only=true: return cached frame or nullptr (no sync decode).
    // Play path uses cache_only=true — all decode on prefetch workers.
    // Park/Seek uses cache_only=false — sync decode on caller's thread.
    VideoResult GetVideoFrame(TrackId track, int64_t timeline_frame, bool cache_only = false);

    // Video track IDs with clips loaded, sorted descending (topmost first).
    // Thread-safe: acquires m_tracks_mutex internally.
    std::vector<int> GetVideoTrackIds();

    // Effective (eligible) video-track set — pushed by the playback layer
    // when mute/solo state changes. REFILL workers decode only tracks in
    // this set; the compositor's effective filter is the source of truth.
    // Until first push, every track with clips is eligible (boot semantics).
    // Thread-safe.
    void SetEffectiveVideoTracks(const std::vector<int>& track_indices);

    // Per-track audio access
    // Returns nullptr for gaps (Lua fills with silence)
    std::shared_ptr<PcmChunk> GetTrackAudio(TrackId track, TimeUS t0, TimeUS t1,
                                             const AudioFormat& fmt);

    // Sequence rate (required before GetTrackAudio — converts timeline frames to us)
    void SetSequenceRate(int32_t num, int32_t den);

    // Sequence resolution — max output size for SW-decoded frames.
    // Frames larger than this are downscaled during decode to avoid
    // caching oversized CPU buffers (33MB at 4K vs 8MB at 1080p).
    // HW-decoded frames (CVPixelBuffer) are unaffected — GPU scales for free.
    void SetSequenceResolution(int32_t w, int32_t h);

    // Audio format for pre-buffer (call once before playback)
    void SetAudioFormat(const AudioFormat& fmt);

    // ── Autonomous pre-mixed audio ──

    // Tell TMB what tracks to pre-mix. Invalidates mixed cache.
    // Mix thread wakes and refills ahead of playhead.
    void SetAudioMixParams(const std::vector<MixTrackParam>& params, const AudioFormat& fmt);

    // Non-blocking cache read. Sync fallback on miss (startup/seek).
    // Returns nullptr if no mix params set.
    std::shared_ptr<PcmChunk> GetMixedAudio(TimeUS t0, TimeUS t1);

    // Set TC origin overrides for specific media paths (FR-004).
    // Call after SetTrackClips, before first SetPlayhead.
    // When acquire_reader opens a file whose path is in the map,
    // it calls set_tc_origin_override before Reader::Create.
    void SetTcOverrides(std::unordered_map<std::string, TcOverride> overrides);

    // Configuration
    void SetMaxReaders(int max);

    // Probe file without buffering (for import)
    static Result<MediaFileInfo> ProbeFile(const std::string& path);

    // Diagnostics: count of GetVideoFrame calls that required a Reader decode
    // (TMB cache miss). Reset with ResetVideoCacheMissCount().
    int64_t GetVideoCacheMissCount() const { return m_video_cache_misses.load(); }
    void ResetVideoCacheMissCount() { m_video_cache_misses.store(0); }

    // Remove a path from the offline blacklist (called when FS watcher
    // detects a previously-missing file has reappeared).
    void ClearOffline(const std::string& path);

    // Drop all TMB state tied to `path` — the FS watcher detected an
    // in-place byte rewrite, so any cached decode of the old bytes is
    // stale. Evicts the reader pool entries (next acquire reopens the
    // file), all cached video frames / audio PCM / EOF markers for
    // clips referencing this path, the decode-speed hint, and the
    // whole pre-mixed audio buffer (can't be partially invalidated —
    // mix is composed across clips). Safe to call at any time; readers
    // currently in use stay alive via shared_ptr until callers release.
    void InvalidatePath(const std::string& path);

    // Stop all background decode work (prefetch workers + decode-prep jobs).
    // Called on playback stop to release HW decoder sessions immediately.
    // Prefetch restarts on next play via SetPlayhead().
    void ParkReaders();

    // Lifecycle
    void ReleaseTrack(TrackId track);
    void ReleaseAll();

    // Advance video buffer watermark (e.g. after external pre-fill).
    // Direction-aware monotonic: never regresses in direction of travel.
    void AdvanceVideoBufferEnd(TrackId track, int64_t pos, int direction);

    // Test accessor: return video_buffer_end for a track (-1 if unset/missing)
    int64_t GetVideoBufferEnd(TrackId track) const;

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
        std::shared_ptr<std::mutex> mutex_owner;  // prevents mutex destruction while locked
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
    PoolEntry evict_lru_reader();  // returns evicted entry for destruction outside lock
    std::string snapshot_pool_state(const char* action, const TrackId& track,
                                     const std::string& clip_id, bool is_hw);

    // Generate a beep tone for offline/unplayable audio clips.
    // 1kHz sine, 100ms on / 900ms off (once per second).
    // position_us: absolute timeline position (determines beep phase).
    // duration_us: requested chunk duration.
    // clip_start_us: clip's timeline start (beep phase relative to clip, not timeline)
    std::shared_ptr<PcmChunk> generate_offline_beep(int64_t position_us, int64_t duration_us, int64_t clip_start_us);
    // Removed: log_pool_state (fprintf under lock caused 100ms+ stalls).
    // Replaced by snapshot_pool_state which returns a string for deferred logging.

    mutable std::mutex m_pool_mutex;
    // Key: (track, clip_id) → each clip gets its own reader/decode session
    // (avoids cache thrashing when two clips from the same file have different source positions)
    std::map<std::pair<TrackId, std::string>, PoolEntry> m_readers;
    int m_max_readers = 16;
    int64_t m_pool_clock = 0;  // monotonic counter for LRU ordering

    // Paths that failed to open (offline media)
    std::unordered_map<std::string, Error> m_offline;

    // TC origin overrides: path → TcOverride (FR-004)
    std::unordered_map<std::string, TcOverride> m_tc_overrides;

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
            uint64_t insert_seq = 0;  // monotonic insertion order for LRU eviction
            // Offline marker: when true, this timeline position is known
            // to have no decodable content (past EOF, before start TC)
            // for a file that otherwise opens fine. Play-time cache_only
            // lookups return offline=true instead of freezing on the
            // nearest cached decoded frame — user sees the red "Not
            // enough media for clip" panel through the offline range.
            bool offline = false;
            std::string error_code;
            std::string error_msg;
        };
        std::map<int64_t, CachedFrame> video_cache; // key = timeline_frame
        uint64_t video_cache_seq = 0;               // next insert_seq to assign
        // Must hold at least 2 × VIDEO_PREFETCH_MAX (96) so current clip + next
        // clip prefetch don't thrash each other via eviction.
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

        // Prefetch watermark: furthest timeline position already fetched.
        // -1 = cold (no prefetch yet). Written by prefetch workers, reset by
        // SetTrackClips (clip change), ParkReaders (stop), direction change.
        int64_t video_buffer_end = -1;    // timeline frame
        TimeUS audio_buffer_end = -1;     // microseconds

        // Generation counter: incremented by SetTrackClips on clip list change.
        // Prefetch workers check generation each iteration — mismatch = abandon.
        int64_t prefetch_generation = 0;

        // Per-clip EOF: first undecodable source frame + last good hold frame.
        // When DecodeAt fails with EOF, record clip_id → EofInfo. Subsequent
        // prefetch iterations skip the decoder and fill hold frames directly,
        // bounded by the prefetch window (not clip boundary).
        // Cleared on SetTrackClips (clip list may change) and ParkReaders.
        struct ClipEofInfo {
            int64_t source_frame;              // first undecodable source frame
            std::shared_ptr<Frame> hold_frame; // last successfully decoded frame
            int rotation = 0;
            int32_t par_num = 1, par_den = 1;
        };
        std::unordered_map<std::string, ClipEofInfo> clip_eof_frame;
    };

    mutable std::mutex m_tracks_mutex;
    std::unordered_map<TrackId, TrackState, TrackIdHash> m_tracks;

    // Effective video-track set pushed by playback layer. Guarded by
    // m_tracks_mutex (read on REFILL hot path under same lock as m_tracks;
    // write on mute/solo change is rare). When _valid is false, every
    // track is treated as eligible (boot before first push).
    std::vector<int> m_effective_video_tracks;
    bool m_effective_video_tracks_valid{false};

    // Find segment (CLIP or GAP) at timeline frame. Never returns null-equivalent —
    // gaps are explicit with bounds. Caller must hold m_tracks_mutex.
    Segment find_segment_at(const TrackState& ts, int64_t timeline_frame) const;

    // Track is in the effective/eligible set pushed by the playback layer.
    // Until first push, every track is eligible. Caller must hold m_tracks_mutex.
    bool track_is_eligible(int track_index) const;

    // Evict one entry from video cache: LRU via insert_seq.
    // Lowest insert_seq = oldest insertion = least recently used.
    // Correct for both directions and across seek boundaries.
    // O(n) on cache size (~144 entries). Caller must hold m_tracks_mutex.
    void evict_video_cache_entry(TrackState& ts) const;

    // Microsecond variant for audio path. Requires m_seq_rate to be set.
    SegmentUS find_segment_at_us(const TrackState& ts, TimeUS t_us) const;

    // Check audio cache for pre-buffered PCM covering [seg_t0, seg_t1) for clip_id
    // Returns sub-range PcmChunk on hit (full coverage required), nullptr on miss
    std::shared_ptr<PcmChunk> check_audio_cache(
        TrackState& ts, const std::string& clip_id,
        TimeUS seg_t0, TimeUS seg_t1, const AudioFormat& fmt) const;

    // Build output PcmChunk: trim decoded audio to source range, conform, rebase to timeline.
    // `speed_magnitude` is the absolute conform ratio (seq_fps / media_fps) — positive only.
    // Direction is encoded upstream in source_in/source_out ordering; this function operates
    // on a forward source slice and callers pass std::abs(clip.speed_ratio).
    std::shared_ptr<PcmChunk> build_audio_output(
        const std::shared_ptr<PcmChunk>& decoded,
        TimeUS source_t0, TimeUS source_t1,
        TimeUS timeline_t0, TimeUS timeline_t1,
        float speed_magnitude, const AudioFormat& fmt) const;

    // ── Pre-buffer thread pool ──
    // Decode-preparation jobs: submitted externally (SetPlayhead probe scan,
    // SetTrackClips reader warming). Processed with priority by prefetch_worker.
    // PreBufferJob is public so unit tests can construct jobs and feed
    // pick_proximity_warm_job (which is also public, below). The struct has
    // no encapsulated invariants — just plain data fields used by the picker
    // and the worker pipeline.
public:
    struct PreBufferJob {
        enum Type { SPEED_DETECT, READER_WARM };
        Type type = SPEED_DETECT;

        TrackId track{TrackType::Video, 0};
        std::string clip_id;
        std::string media_path;

        // SPEED_DETECT fields — single-frame decode to measure codec speed.
        int64_t probe_source_in = 0;
        int32_t probe_rate_num = 0;
        int32_t probe_rate_den = 1;

        // Timeline position of the clip this job warms. Used by
        // process_next_decode_prep_job to pick the READER_WARM job whose clip
        // is closest to the current playhead in the playback direction — so
        // at shuttle speed where many warm jobs may be queued, the imminent
        // clip wins over far-future ones (LIFO over sequence-ordered Lua
        // insertions had the OPPOSITE shape: it warmed the furthest clip
        // first, stalling the imminent one for ~10s at 32×).
        // -1 = unknown (SPEED_DETECT jobs leave this at default).
        int64_t sequence_start = -1;

        // WARM timing: set by submit_pre_buffer, checked by prefetch_worker
        std::chrono::steady_clock::time_point submitted_at{};
    };
private:

    void start_workers(int count);
    void stop_workers();

    // Self-directed prefetch loops (replace batch REFILL system).
    // Each worker autonomously picks tracks and fills one frame at a time.
    void prep_worker();            // SPEED_DETECT + READER_WARM (dedicated thread)
    void prefetch_worker();        // video prefetch only
    void audio_prefetch_worker();  // audio prefetch only

    // Decode-prep job processing (SPEED_DETECT, READER_WARM)
    bool process_next_decode_prep_job();
    void submit_pre_buffer(const PreBufferJob& job);
    static std::string job_key(const PreBufferJob& job);

    // Public for unit testing — no controller state, pure function over the
    // job vector + playhead state. Returns the index of the READER_WARM job
    // whose sequence_start is closest to `playhead` in `direction`, or -1 if
    // no READER_WARM jobs exist. See process_next_decode_prep_job for the
    // rationale on proximity priority.
public:
    static int pick_proximity_warm_job(const std::vector<PreBufferJob>& jobs,
                                       int64_t playhead, int direction);
private:

    // Track selection for prefetch — find most urgent track needing work
    bool pick_video_track(TrackId& out);
    bool pick_audio_track(TrackId& out);

    // Core prefetch algorithm (unified A/V, one frame per iteration)
    void fill_prefetch(const TrackId& track);
    void discard_already_played_prefetch(const TrackId& track);

    // Leaf helpers for fill_prefetch
    int stride_for_clip(const TrackId& track, const ClipInfo& clip) const;
    void decode_into_cache(const TrackId& track, const Segment& seg,
                           int64_t position, int stride, int direction,
                           ReaderHandle& held_reader, std::string& held_clip_id,
                           std::shared_ptr<Frame>& last_good_frame);
    void decode_audio_into_cache(const TrackId& track, const SegmentUS& seg,
                                 TimeUS position, TimeUS chunk_end);

    // Direction-aware watermark setters (never regress in direction of travel)
    void set_already_fetched_video(const TrackId& track, int64_t pos, int direction);
    void set_already_fetched_audio(const TrackId& track, TimeUS pos, int direction);

    // Wake signal for prefetch workers
    void wake_prefetch_workers();
    bool is_video_buffer_low(const TrackState& ts, int64_t playhead, int dir) const;
    bool is_audio_buffer_low(const TrackState& ts, TimeUS playhead_us, int dir) const;

    // Track claim sets — prevent two workers from filling the same track
    // RAII guard: inserts track into set on construction, erases on destruction
    struct PrefetchClaimGuard {
        std::unordered_set<TrackId, TrackIdHash>* set = nullptr;
        std::mutex* mutex = nullptr;
        TrackId track;

        PrefetchClaimGuard(std::unordered_set<TrackId, TrackIdHash>* s,
                           std::mutex* m, TrackId t)
            : set(s), mutex(m), track(t) {}

        // Move-only: moved-from guard is inert (set==nullptr → no unlock)
        PrefetchClaimGuard(PrefetchClaimGuard&& o) noexcept
            : set(o.set), mutex(o.mutex), track(o.track) { o.set = nullptr; }
        PrefetchClaimGuard(const PrefetchClaimGuard&) = delete;
        PrefetchClaimGuard& operator=(const PrefetchClaimGuard&) = delete;
        PrefetchClaimGuard& operator=(PrefetchClaimGuard&&) = delete;

        ~PrefetchClaimGuard() {
            if (set) {
                std::lock_guard<std::mutex> lock(*mutex);
                set->erase(track);
            }
        }
    };
    std::unique_ptr<PrefetchClaimGuard> claim_track_for_prefetch(
        const TrackId& track, std::unordered_set<TrackId, TrackIdHash>& set);

    std::vector<std::thread> m_workers;
    std::mutex m_jobs_mutex;
    std::condition_variable m_jobs_cv;
    std::vector<PreBufferJob> m_jobs;            // decode-prep queue only
    std::unordered_map<std::string, int64_t> m_pre_buffering;  // in-flight dedup
    std::atomic<bool> m_shutdown{false};

    // Active prefetch sets: tracks currently being filled by a worker
    std::unordered_set<TrackId, TrackIdHash> m_video_prefetching;  // protected by m_jobs_mutex
    std::unordered_set<TrackId, TrackIdHash> m_audio_prefetching;  // protected by m_jobs_mutex

    // ── Sequence rate (for timeline frame → us conversion) ──
    Rate m_seq_rate{0, 1};

    // ── Sequence resolution (max output size for SW-decoded frames) ──
    int32_t m_seq_width{0};
    int32_t m_seq_height{0};

    // ── Audio format (for pre-buffer — set once before playback) ──
    AudioFormat m_audio_fmt{SampleFormat::F32, 0, 0};

    // ── Prefetch buffer constants ──
    // Max: stop filling when already_fetched is this far ahead of playhead
    static constexpr int64_t VIDEO_PREFETCH_MAX = 96;     // ~4s @24fps
    // Min: wake prefetch when already_fetched is only this far ahead
    static constexpr int64_t VIDEO_PREFETCH_MIN = 48;     // ~2s @24fps

    static constexpr TimeUS AUDIO_PREFETCH_MAX = 2000000;  // 2s
    static constexpr TimeUS AUDIO_PREFETCH_MIN = 500000;   // 0.5s
    static constexpr TimeUS AUDIO_REFILL_SIZE = 200000;    // 200ms per audio chunk

    // Max adaptive stride: ceil(decode_ms / frame_period_ms), clamped
    static constexpr int MAX_STRIDE = 8;

    // Pool sizing: floor = 1 prep + 1 video + 1 audio (start_workers layout
    // invariant). Ceiling = FFmpeg shared-state contention plateau past ~14
    // decode threads on Apple Silicon Pro/Max.
    static constexpr int MIN_POOL_THREADS = 3;
    static constexpr int MAX_POOL_THREADS = 16;

    // Probe window: scan this far ahead of playhead for unprobed media paths.
    // Must be >> PREFETCH_MAX so probes complete well before prefetch reaches the clip.
    static constexpr int64_t PROBE_WINDOW = 288;      // ~12s @24fps

    // WARM diagnostics: queue wait >200ms = workers starved (software)
    //                   acquire >1000ms = drive I/O or codec init slow (environment)
    static constexpr int WARM_QUEUE_WARN_MS = 200;
    static constexpr int WARM_ACQUIRE_WARN_MS = 1000;

    // ── Playhead state ──
    std::atomic<int64_t> m_playhead_frame{0};
    std::atomic<int64_t> m_prev_playhead_frame{-1};  // for discontinuity detection
    std::atomic<int> m_playhead_direction{0};
    std::atomic<float> m_playhead_speed{1.0f};

    // Audio worker wake flag — set by SetPlayhead on discontinuity or low buffer,
    // consumed by audio_prefetch_worker CV predicate. Eliminates 100ms polling gap.
    std::atomic<bool> m_audio_work_pending{false};

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

    // Measured ms-per-frame per (track, file). Per-track keying is load-
    // bearing: a shared entry lets one track's cold-start keyframe timing
    // poison a sibling track's stride_for_clip before the sibling has any
    // of its own samples, producing a single stride>1 stall on the sibling.
    // Protected by m_pool_mutex.
    std::map<std::pair<TrackId, std::string>, float> m_decode_speed_cache;

    // ── Diagnostics ──
    std::atomic<int64_t> m_video_cache_misses{0};
};

} // namespace emp
