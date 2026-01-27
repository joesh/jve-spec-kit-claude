#pragma once

#include "emp_asset.h"
#include "emp_frame.h"
#include "emp_audio.h"
#include "emp_errors.h"
#include "emp_time.h"
#include <memory>

namespace emp {

// Forward declaration for implementation
class ReaderImpl;

// Video reader for decoding frames from an asset
class Reader {
public:
    ~Reader();

    // Create a reader for an asset
    static Result<std::shared_ptr<Reader>> Create(std::shared_ptr<Asset> asset);

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

    // Get the underlying asset
    std::shared_ptr<Asset> asset() const;

    // Internal: Constructor is public but ReaderImpl is opaque, so only EMP can create Readers
    explicit Reader(std::unique_ptr<ReaderImpl> impl, std::shared_ptr<Asset> asset);

private:
    std::unique_ptr<ReaderImpl> m_impl;
    std::shared_ptr<Asset> m_asset;
};

} // namespace emp
