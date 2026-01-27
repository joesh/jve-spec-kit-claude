#pragma once

// Internal header - defines FrameImpl
// Supports both CPU buffer and hardware buffer (VideoToolbox CVPixelBuffer)

#include <editor_media_platform/emp_time.h>
#include <cstdint>
#include <vector>
#include <mutex>

#ifdef EMP_HAS_VIDEOTOOLBOX
#include <CoreVideo/CVPixelBuffer.h>
#endif

namespace emp {
namespace impl {

// Forward declare for lazy transfer
class FFmpegScaleContext;

} // namespace impl

// FrameImpl holds EITHER hw buffer OR cpu buffer
// The hw→cpu transfer is lazy (happens on first data() call)
// INVARIANT: Exactly one of cpu_buffer_valid or hw_buffer must be true/non-null
class FrameImpl {
public:
    // CPU-only constructor (sw decode path)
    FrameImpl(int w, int h, int stride, TimeUS pts, std::vector<uint8_t> data)
        : m_width(w), m_height(h), m_stride(stride), m_pts_us(pts),
          m_cpu_buffer(std::move(data)), m_cpu_buffer_valid(true)
#ifdef EMP_HAS_VIDEOTOOLBOX
          , m_hw_buffer(nullptr)
#endif
    {
        // FAIL-FAST: Validate inputs
        assert(w > 0 && "FrameImpl(cpu): width must be > 0");
        assert(h > 0 && "FrameImpl(cpu): height must be > 0");
        assert(stride >= w * 4 && "FrameImpl(cpu): stride must be >= width*4 (BGRA32)");
        assert(!m_cpu_buffer.empty() && "FrameImpl(cpu): cpu_buffer cannot be empty");
        assert(m_cpu_buffer.size() >= static_cast<size_t>(stride * h) &&
               "FrameImpl(cpu): cpu_buffer too small for dimensions");
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // HW buffer constructor (VideoToolbox path)
    // Takes ownership of the CVPixelBuffer reference (caller should NOT release)
    FrameImpl(int w, int h, int stride, TimeUS pts, CVPixelBufferRef hw_buffer)
        : m_width(w), m_height(h), m_stride(stride), m_pts_us(pts),
          m_cpu_buffer_valid(false), m_hw_buffer(hw_buffer)
    {
        // FAIL-FAST: Validate inputs
        assert(w > 0 && "FrameImpl(hw): width must be > 0");
        assert(h > 0 && "FrameImpl(hw): height must be > 0");
        assert(stride >= w * 4 && "FrameImpl(hw): stride must be >= width*4 (BGRA32)");
        assert(hw_buffer != nullptr && "FrameImpl(hw): hw_buffer cannot be null");

        // Retain the buffer - we own it now
        CVPixelBufferRetain(m_hw_buffer);
    }
#endif

    ~FrameImpl() {
#ifdef EMP_HAS_VIDEOTOOLBOX
        if (m_hw_buffer) {
            CVPixelBufferRelease(m_hw_buffer);
            m_hw_buffer = nullptr;
        }
#endif
    }

    // Non-copyable (owns hw buffer)
    FrameImpl(const FrameImpl&) = delete;
    FrameImpl& operator=(const FrameImpl&) = delete;

    int width() const { return m_width; }
    int height() const { return m_height; }
    int stride() const { return m_stride; }
    TimeUS pts_us() const { return m_pts_us; }

    // Returns CPU pixel data, triggering hw→cpu transfer if needed
    // Thread-safe via mutex
    const uint8_t* data();

    size_t data_size() const {
        return static_cast<size_t>(m_stride) * m_height;
    }

    // Check if this frame has a hardware buffer
    bool has_hw_buffer() const {
#ifdef EMP_HAS_VIDEOTOOLBOX
        return m_hw_buffer != nullptr;
#else
        return false;
#endif
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // Direct access to hw buffer (for Metal zero-copy path)
    // Returns nullptr if this is a CPU-only frame
    CVPixelBufferRef hw_buffer() const { return m_hw_buffer; }
#endif

private:
    int m_width;
    int m_height;
    int m_stride;
    TimeUS m_pts_us;

    // CPU buffer - may be empty until lazy transfer
    std::vector<uint8_t> m_cpu_buffer;
    bool m_cpu_buffer_valid;

#ifdef EMP_HAS_VIDEOTOOLBOX
    // Hardware buffer (VideoToolbox)
    CVPixelBufferRef m_hw_buffer;
#endif

    // Mutex for lazy transfer
    std::mutex m_transfer_mutex;

    // Perform hw→cpu transfer (called from data() if needed)
    void ensure_cpu_buffer();
};

} // namespace emp
