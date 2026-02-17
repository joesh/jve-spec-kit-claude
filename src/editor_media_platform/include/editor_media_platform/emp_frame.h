#pragma once

#include "emp_time.h"
#include <cstdint>
#include <memory>
#include <vector>

namespace emp {

// Forward declaration for implementation
class FrameImpl;

// Decoded video frame in BGRA32 format
// Memory layout: B, G, R, A for each pixel (matches Qt QImage::Format_ARGB32 on little-endian)
class Frame {
public:
    ~Frame();

    // Frame dimensions
    int width() const;
    int height() const;

    // Bytes per row (may include padding)
    int stride_bytes() const;

    // Source presentation timestamp (for debug/telemetry only)
    TimeUS source_pts_us() const;

    // Raw pixel data pointer (BGRA32 format, alpha=255)
    const uint8_t* data() const;

    // Total data size in bytes (stride_bytes * height)
    size_t data_size() const;

#ifdef EMP_HAS_VIDEOTOOLBOX
    // Returns CVPixelBufferRef if frame has hardware buffer, nullptr otherwise
    // For Metal zero-copy rendering path
    void* native_buffer() const;
#endif

    // Create a CPU-backed frame from raw BGRA32 pixel data.
    // Public factory — avoids exposing FrameImpl to callers.
    static std::shared_ptr<Frame> CreateCPU(int w, int h, int stride,
                                            TimeUS pts, std::vector<uint8_t> data);

    // Internal: Constructor is public but FrameImpl is opaque, so only EMP can create Frames
    explicit Frame(std::unique_ptr<FrameImpl> impl);

private:
    std::unique_ptr<FrameImpl> m_impl;
};

} // namespace emp
