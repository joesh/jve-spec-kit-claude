#include <editor_media_platform/emp_frame.h>
#include "impl/frame_impl.h"
#include <cassert>
#include <cstring>

#ifdef EMP_HAS_VIDEOTOOLBOX
#include <CoreVideo/CVPixelBuffer.h>
#endif

namespace emp {

Frame::Frame(std::unique_ptr<FrameImpl> impl) : m_impl(std::move(impl)) {
    assert(m_impl && "Frame impl cannot be null");
}

Frame::~Frame() = default;

int Frame::width() const { return m_impl->width(); }
int Frame::height() const { return m_impl->height(); }
int Frame::stride_bytes() const { return m_impl->stride(); }
TimeUS Frame::source_pts_us() const { return m_impl->pts_us(); }
const uint8_t* Frame::data() const { return m_impl->data(); }
size_t Frame::data_size() const { return m_impl->data_size(); }

#ifdef EMP_HAS_VIDEOTOOLBOX
void* Frame::native_buffer() const {
    return m_impl->hw_buffer();
}
#endif

// FrameImpl method implementations

const uint8_t* FrameImpl::data() {
    ensure_cpu_buffer();
    return m_cpu_buffer.data();
}

void FrameImpl::ensure_cpu_buffer() {
    // Fast path: already have CPU data
    if (m_cpu_buffer_valid) {
        return;
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // Slow path: need to transfer from hw buffer
    std::lock_guard<std::mutex> lock(m_transfer_mutex);

    // Double-check after acquiring lock
    if (m_cpu_buffer_valid) {
        return;
    }

    // INVARIANT: If cpu_buffer not valid, hw_buffer MUST be valid
    // This is enforced by FrameImpl constructors - one or the other must be set
    assert(m_hw_buffer && "FrameImpl::ensure_cpu_buffer: no hw_buffer - "
           "FrameImpl created without valid buffer (width=%d height=%d)");

    // Lock the pixel buffer for CPU access
    CVReturn ret = CVPixelBufferLockBaseAddress(m_hw_buffer, kCVPixelBufferLock_ReadOnly);
    assert(ret == kCVReturnSuccess && "FrameImpl::ensure_cpu_buffer: "
           "CVPixelBufferLockBaseAddress failed");

    // Get buffer info
    size_t width = CVPixelBufferGetWidth(m_hw_buffer);
    size_t height = CVPixelBufferGetHeight(m_hw_buffer);
    size_t src_stride = CVPixelBufferGetBytesPerRow(m_hw_buffer);
    uint8_t* src_data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(m_hw_buffer));

    assert(src_data && "FrameImpl::ensure_cpu_buffer: CVPixelBufferGetBaseAddress returned null");
    assert(width > 0 && height > 0 && "FrameImpl::ensure_cpu_buffer: invalid dimensions");

    // VideoToolbox outputs BGRA which matches our format
    // Allocate our buffer with 32-byte aligned stride
    int dst_stride = ((static_cast<int>(width) * 4) + 31) & ~31;
    m_stride = dst_stride;
    m_cpu_buffer.resize(static_cast<size_t>(dst_stride) * height);

    // Copy row by row (handles stride differences)
    size_t row_bytes = width * 4;
    for (size_t y = 0; y < height; ++y) {
        std::memcpy(m_cpu_buffer.data() + y * dst_stride,
                    src_data + y * src_stride,
                    row_bytes);
    }

    // Unlock
    CVPixelBufferUnlockBaseAddress(m_hw_buffer, kCVPixelBufferLock_ReadOnly);

    m_cpu_buffer_valid = true;
#else
    // Without VideoToolbox, cpu_buffer_valid should always be true
    // If we get here, FrameImpl was constructed incorrectly
    assert(false && "FrameImpl::ensure_cpu_buffer: cpu_buffer not valid but "
           "EMP_HAS_VIDEOTOOLBOX not defined - invalid FrameImpl state");
#endif
}

} // namespace emp
