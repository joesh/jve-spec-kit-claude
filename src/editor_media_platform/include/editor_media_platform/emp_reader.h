#pragma once

#include "emp_media_file.h"
#include "emp_frame.h"
#include "emp_audio.h"
#include "emp_errors.h"
#include "emp_time.h"
#include <memory>

namespace emp {

// Global decode mode — controls seek behavior.
// Set by the transport layer (playback controller, ruler drag) via Lua bindings.
//
// Play:  Sequential decode with seek avoidance (need_seek check)
// Scrub: Always seek to keyframe before target
// Park:  Same as Scrub
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

    // True if video decoder is using hardware acceleration (VideoToolbox)
    bool IsHwAccelerated() const;

    // Per-frame decode time from the last batch decode (play path).
    // Returns ms/frame averaged over the batch, or -1.0f if no batch yet.
    // Retained across cache-hit calls — reflects codec throughput, not per-call latency.
    float LastBatchMsPerFrame() const;

    // Get the underlying media file
    std::shared_ptr<MediaFile> media_file() const;

    // Internal: Constructor is public but ReaderImpl is opaque, so only EMP can create Readers
    explicit Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<MediaFile> media_file);

private:
    std::unique_ptr<ReaderImpl> m_impl;
    std::shared_ptr<MediaFile> m_media_file;
};

} // namespace emp
