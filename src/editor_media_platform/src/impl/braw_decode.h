#pragma once

// Blackmagic RAW (BRAW) decoder integration.
// Detects .braw files by extension, probes metadata via the SDK, and
// decodes frames into BGRA8 CPU buffers for the Frame/TMB pipeline.
//
// The SDK is loaded dynamically at runtime via BlackmagicRawAPIDispatch.cpp.
// If the SDK framework is not installed, all operations return Error::unsupported.
//
// Thread safety: one BrawReaderContext per Reader (same as FFmpeg path).
// The TMB's per-Reader use_mutex serializes access.

#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>
#include "frame_buffer_pool.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace emp {

class Frame;

namespace impl {

// Metadata extracted from a .braw clip (parallel to FFmpeg's AVFormatContext probe).
struct BrawClipInfo {
    int width = 0;
    int height = 0;
    int32_t fps_num = 0;
    int32_t fps_den = 1;
    uint64_t frame_count = 0;
    TimeUS duration_us = 0;
    int64_t first_frame_tc = 0;  // TC origin in frames at video rate

    // Audio — populated when clip has an audio track.
    bool has_audio = false;
    int32_t audio_sample_rate = 0;
    int32_t audio_channels = 0;
    int32_t audio_bit_depth = 0;
    int64_t audio_sample_count = 0;
};

// Check file extension (case-insensitive). No I/O, no SDK required.
bool is_braw_file(const std::string& path);

// Check if the BRAW SDK is available at runtime.
bool braw_sdk_available();

// Open a .braw clip, extract metadata, close. Requires the SDK at runtime.
Result<BrawClipInfo> braw_probe_clip(const std::string& path);

// BRAW reader context — owns a codec + clip for frame decoding.
// One instance per Reader. Lifetime managed by ReaderImpl.
class BrawReaderContext {
public:
    BrawReaderContext();
    ~BrawReaderContext();

    // Non-copyable
    BrawReaderContext(const BrawReaderContext&) = delete;
    BrawReaderContext& operator=(const BrawReaderContext&) = delete;

    // Open clip for decoding. Call once after construction.
    Result<void> init(const std::string& path);

    // Select resolution scale based on sequence vs source resolution.
    // Uses SDK's native Half/Quarter/Eighth scaling (cheaper than post-decode scale).
    void set_resolution_scale(int max_w, int max_h);

    // Decode one frame by index. Returns BGRA8 Frame with given PTS.
    // Pool provides pre-allocated malloc'd buffers (no zero-init overhead).
    Result<std::shared_ptr<Frame>> decode_frame(uint64_t frame_index, TimeUS pts_us,
                                                 std::shared_ptr<FrameBufferPool> pool);

    // Output dimensions after resolution scaling.
    int output_width() const { return m_out_w; }
    int output_height() const { return m_out_h; }

    // Audio accessors (zero if clip has no audio track).
    bool has_audio() const { return m_audio_raw != nullptr; }
    int32_t audio_sample_rate() const { return m_audio_sample_rate; }
    int32_t audio_channels() const { return m_audio_channels; }
    int32_t audio_bit_depth() const { return m_audio_bit_depth; }
    int64_t audio_sample_count() const { return m_audio_sample_count; }

    // Read [sample_start, sample_start + sample_count) audio sample-frames
    // into out_f32 (interleaved, size = sample_count * channels). Returns
    // the number of frames actually read (may be < sample_count at EOF).
    // Converts native PCM bit depth to float32 in [-1, 1].
    Result<int64_t> read_audio_f32(int64_t sample_start, int64_t sample_count,
                                    std::vector<float>& out_f32);

private:
    // SDK COM objects. Typed as void* to avoid pulling the SDK header
    // into callers. Cast to IBlackmagicRaw*/IBlackmagicRawClip* in .cpp.
    void* m_codec_raw = nullptr;
    void* m_clip_raw = nullptr;
    void* m_callback_raw = nullptr;  // BrawCallbackHandler*, owned
    void* m_audio_raw = nullptr;     // IBlackmagicRawClipAudio*, QI'd from clip
    int m_src_w = 0;
    int m_src_h = 0;
    int m_out_w = 0;   // after resolution scale
    int m_out_h = 0;
    int m_braw_scale = 0;  // BlackmagicRawResolutionScale (stored as int to avoid SDK header)
    float m_last_decode_ms = 0;

    // Audio params (cached at init)
    int32_t m_audio_sample_rate = 0;
    int32_t m_audio_channels = 0;
    int32_t m_audio_bit_depth = 0;
    int64_t m_audio_sample_count = 0;
};

} // namespace impl
} // namespace emp
