#pragma once

// Internal header - defines FrameImpl
// Supports both CPU buffer and hardware buffer (VideoToolbox CVPixelBuffer)

#include <editor_media_platform/emp_time.h>
#include <cstdint>
#include <cstdlib>
#include <functional>
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
    // Optional release callback: when set, the destructor passes the cpu_buffer
    // back via this callback instead of freeing it. Used by buffer pools to
    // recycle pre-touched pages (avoids 4K page fault overhead on reallocation).
    using ReleaseCallback = std::function<void(std::vector<uint8_t>)>;

    // Release callback for raw (malloc'd) buffers.
    using RawReleaseCallback = std::function<void(uint8_t*, size_t)>;

    // CPU-only constructor (sw decode path — vector-owned buffer)
    FrameImpl(int w, int h, int stride, TimeUS pts, std::vector<uint8_t> data,
              ReleaseCallback release_cb = nullptr)
        : m_width(w), m_height(h), m_stride(stride), m_pts_us(pts),
          m_cpu_buffer(std::move(data)), m_cpu_buffer_valid(true),
          m_release_cb(std::move(release_cb))
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

    // Raw-pointer constructor — for malloc'd buffers (no zero-init overhead).
    // Caller transfers ownership. raw_release_cb called on destruction (or free() if null).
    FrameImpl(int w, int h, int stride, TimeUS pts,
              uint8_t* raw_data, size_t raw_size,
              RawReleaseCallback raw_release_cb = nullptr)
        : m_width(w), m_height(h), m_stride(stride), m_pts_us(pts),
          m_cpu_buffer_valid(true),
          m_raw_data(raw_data), m_raw_size(raw_size),
          m_raw_release_cb(std::move(raw_release_cb))
#ifdef EMP_HAS_VIDEOTOOLBOX
          , m_hw_buffer(nullptr)
#endif
    {
        assert(w > 0 && "FrameImpl(raw): width must be > 0");
        assert(h > 0 && "FrameImpl(raw): height must be > 0");
        assert(stride >= w * 4 && "FrameImpl(raw): stride must be >= width*4 (BGRA32)");
        assert(raw_data && "FrameImpl(raw): data cannot be null");
        assert(raw_size >= static_cast<size_t>(stride * h) &&
               "FrameImpl(raw): buffer too small for dimensions");
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
        // Return buffer to pool if release callback is set
        if (m_raw_data) {
            if (m_raw_release_cb) {
                m_raw_release_cb(m_raw_data, m_raw_size);
            } else {
                free(m_raw_data);
            }
            m_raw_data = nullptr;
        } else if (m_release_cb && !m_cpu_buffer.empty()) {
            m_release_cb(std::move(m_cpu_buffer));
        }
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
        if (m_raw_data) return m_raw_size;
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

    // CPU buffer — vector path (sw decode, hw→cpu transfer)
    std::vector<uint8_t> m_cpu_buffer;
    bool m_cpu_buffer_valid;

    // Optional release callback for vector buffer pool recycling
    ReleaseCallback m_release_cb;

    // Raw pointer path — malloc'd buffers (no zero-init overhead).
    // When m_raw_data is set, data() returns it instead of m_cpu_buffer.
    uint8_t* m_raw_data = nullptr;
    size_t m_raw_size = 0;
    RawReleaseCallback m_raw_release_cb;

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
