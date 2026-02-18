#pragma once

#include "emp_media_file.h"
#include "emp_frame.h"
#include "emp_audio.h"
#include "emp_errors.h"
#include "emp_time.h"
#include <memory>
#include <atomic>

namespace emp {

// Global decode mode — controls how readers handle intermediate frames.
// Set by the transport layer (playback controller, ruler drag) via Lua bindings.
//
// Play:  BGRA-convert ALL intermediates, cache for sequential access, prefetch active
// Scrub: Decode from keyframe through B-frames, only BGRA-convert target frame
// Park:  Same as Scrub (single frame decode, no expectation of further requests)
enum class DecodeMode { Play, Scrub, Park };

// Global decode mode accessors (thread-safe)
void SetDecodeMode(DecodeMode mode);
DecodeMode GetDecodeMode();

// Forward declaration for implementation
class ReaderImpl;

// Video reader for decoding frames from a media file
class Reader {
public:
    ~Reader();

    // Create a reader for a media file
    static Result<std::shared_ptr<Reader>> Create(std::shared_ptr<MediaFile> media_file);

    // Seek to a frame time (invalidates current frame)
    Result<void> Seek(FrameTime t);

    // Decode frame at the given time using floor-on-grid semantics:
    // Returns frame F with largest pts_us(F) <= T
    // If T < first frame: returns first frame
    // If T > last frame: returns last frame
    Result<std::shared_ptr<Frame>> DecodeAt(FrameTime t);

    // Debug/tooling APIs (not used by editor clients)
    Result<void> SeekUS(TimeUS t_us);
    Result<std::shared_ptr<Frame>> DecodeAtUS(TimeUS t_us);

    // Audio decoding
    // Decodes audio from [t0, t1) using the given CFR grid rate
    // Output is resampled to the specified AudioFormat (float32 stereo @ device rate)
    // Returns empty chunk (frames=0) at EOF, error only on decode failure
    Result<std::shared_ptr<PcmChunk>> DecodeAudioRange(FrameTime t0, FrameTime t1,
                                                        const AudioFormat& out);

    // Debug/tooling: decode audio by microseconds directly
    Result<std::shared_ptr<PcmChunk>> DecodeAudioRangeUS(TimeUS t0_us, TimeUS t1_us,
                                                          const AudioFormat& out);

    // =========================================================================
    // Background Prefetch API - for smooth playback
    // =========================================================================

    // Start/update background prefetch thread
    // direction: 1 = forward, -1 = reverse, 0 = stop (same as StopPrefetch)
    // Prefetch thread will decode ahead in the specified direction
    void StartPrefetch(int direction);

    // Stop background prefetch (safe to call even if not running)
    void StopPrefetch();

    // Update prefetch target position (call from playback tick)
    // Prefetch thread will decode ahead of this position
    void UpdatePrefetchTarget(TimeUS t_us);

    // Non-blocking cache lookup - returns nullptr on miss
    // Use this for display path; falls back to DecodeAtUS on miss
    std::shared_ptr<Frame> GetCachedFrame(TimeUS t_us);

    // Set maximum cached BGRA frames. Reader evicts down to new limit immediately.
    // Used by Lua to control per-reader cache size based on state
    // (e.g., active+playing=120, active+scrubbing=8, pooled=1).
    void SetMaxCacheFrames(size_t max_frames);

    // Diagnostics: total frames decoded by prefetch since last StartPrefetch.
    // Used by tests to verify seek-vs-forward-decode behavior.
    int64_t PrefetchFramesDecoded() const;

    // Get the underlying media file
    std::shared_ptr<MediaFile> media_file() const;

    // Internal: Constructor is public but ReaderImpl is opaque, so only EMP can create Readers
    explicit Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<MediaFile> media_file);

private:
    std::unique_ptr<ReaderImpl> m_impl;
    std::shared_ptr<MediaFile> m_media_file;

    // Prefetch worker thread function
    void prefetch_worker();
};

} // namespace emp
