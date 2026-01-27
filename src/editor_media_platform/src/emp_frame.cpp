#include <editor_media_platform/emp_frame.h>
#include "impl/frame_impl.h"
#include <cassert>
#include <cstring>
#include <algorithm>  // std::max, std::min

#ifdef EMP_HAS_VIDEOTOOLBOX
#include <CoreVideo/CVPixelBuffer.h>
#include <Accelerate/Accelerate.h>  // vImage for YUV→RGB conversion
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

    assert(width > 0 && height > 0 && "FrameImpl::ensure_cpu_buffer: invalid dimensions");

    // Allocate BGRA output buffer with 32-byte aligned stride
    int dst_stride = ((static_cast<int>(width) * 4) + 31) & ~31;
    m_stride = dst_stride;
    m_cpu_buffer.resize(static_cast<size_t>(dst_stride) * height);

    // Check actual pixel format - VideoToolbox outputs YUV, not BGRA!
    OSType pixel_format = CVPixelBufferGetPixelFormatType(m_hw_buffer);

    switch (pixel_format) {
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB: {
            // Direct copy path (rare - VT usually outputs YUV)
            size_t src_stride = CVPixelBufferGetBytesPerRow(m_hw_buffer);
            uint8_t* src_data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(m_hw_buffer));
            assert(src_data && "FrameImpl::ensure_cpu_buffer: BGRA base address is null");

            size_t row_bytes = width * 4;
            for (size_t y = 0; y < height; ++y) {
                std::memcpy(m_cpu_buffer.data() + y * dst_stride,
                            src_data + y * src_stride,
                            row_bytes);
            }
            break;
        }

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
            // NV12 format (8-bit): Y plane + interleaved UV plane
            // This is the common VideoToolbox output format
            bool full_range = (pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

            // Get plane pointers
            uint8_t* y_plane = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_hw_buffer, 0));
            uint8_t* uv_plane = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_hw_buffer, 1));
            size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(m_hw_buffer, 0);
            size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(m_hw_buffer, 1);

            assert(y_plane && uv_plane && "FrameImpl::ensure_cpu_buffer: NV12 plane address is null");

            // Use vImage for hardware-accelerated NV12→BGRA conversion
            vImage_Buffer y_buf = { y_plane, height, width, y_stride };
            vImage_Buffer uv_buf = { uv_plane, height / 2, width / 2, uv_stride };
            vImage_Buffer dst_buf = { m_cpu_buffer.data(), height, width, static_cast<size_t>(dst_stride) };

            // Create conversion info for BT.709 (HD content) or BT.601 (SD content)
            // Most modern content is BT.709
            vImage_YpCbCrToARGB info;
            vImage_YpCbCrPixelRange pixel_range;

            if (full_range) {
                pixel_range = (vImage_YpCbCrPixelRange){ 0, 128, 255, 255, 255, 1, 255, 0 };
            } else {
                pixel_range = (vImage_YpCbCrPixelRange){ 16, 128, 235, 240, 255, 0, 255, 0 };
            }

            vImageConvert_YpCbCrToARGB_GenerateConversion(
                kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
                &pixel_range,
                &info,
                kvImage420Yp8_CbCr8,
                kvImageARGB8888,
                kvImageNoFlags
            );

            vImage_Error err = vImageConvert_420Yp8_CbCr8ToARGB8888(
                &y_buf, &uv_buf, &dst_buf, &info, nullptr, 255, kvImageNoFlags
            );
            assert(err == kvImageNoError && "FrameImpl::ensure_cpu_buffer: vImage NV12→ARGB failed");

            // vImage outputs ARGB, we need BGRA - swap R and B channels
            // ARGB: [A R G B] → BGRA: [B G R A]
            for (size_t y = 0; y < height; ++y) {
                uint8_t* row = m_cpu_buffer.data() + y * dst_stride;
                for (size_t x = 0; x < width; ++x) {
                    uint8_t* pixel = row + x * 4;
                    // Swap: ARGB → BGRA
                    uint8_t a = pixel[0];
                    uint8_t r = pixel[1];
                    uint8_t g = pixel[2];
                    uint8_t b = pixel[3];
                    pixel[0] = b;
                    pixel[1] = g;
                    pixel[2] = r;
                    pixel[3] = a;
                }
            }
            break;
        }

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: {
            // P010 format (10-bit): Y plane + interleaved UV plane (16-bit per component)
            // Used for HDR content and 10-bit ProRes
            bool full_range = (pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);

            uint16_t* y_plane = static_cast<uint16_t*>(CVPixelBufferGetBaseAddressOfPlane(m_hw_buffer, 0));
            uint16_t* uv_plane = static_cast<uint16_t*>(CVPixelBufferGetBaseAddressOfPlane(m_hw_buffer, 1));
            size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(m_hw_buffer, 0);
            size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(m_hw_buffer, 1);

            assert(y_plane && uv_plane && "FrameImpl::ensure_cpu_buffer: P010 plane address is null");

            // BT.709 YUV→RGB conversion coefficients
            (void)full_range;  // TODO: Apply video range scaling if needed

            for (size_t row = 0; row < height; ++row) {
                uint8_t* dst_row = m_cpu_buffer.data() + row * dst_stride;
                uint16_t* y_row = reinterpret_cast<uint16_t*>(reinterpret_cast<uint8_t*>(y_plane) + row * y_stride);
                uint16_t* uv_row = reinterpret_cast<uint16_t*>(reinterpret_cast<uint8_t*>(uv_plane) + (row / 2) * uv_stride);

                for (size_t col = 0; col < width; ++col) {
                    // P010: data is in upper 10 bits of 16-bit value
                    float y_val = (y_row[col] >> 6) / 1023.0f;
                    float cb_val = (uv_row[(col / 2) * 2] >> 6) / 1023.0f - 0.5f;
                    float cr_val = (uv_row[(col / 2) * 2 + 1] >> 6) / 1023.0f - 0.5f;

                    // Apply video range scaling if needed
                    if (!full_range) {
                        y_val = (y_val - 16.0f/255.0f) * (255.0f / 219.0f);
                        cb_val = cb_val * (255.0f / 224.0f);
                        cr_val = cr_val * (255.0f / 224.0f);
                    }

                    // BT.709 YCbCr → RGB
                    float r = y_val + 1.5748f * cr_val;
                    float g = y_val - 0.1873f * cb_val - 0.4681f * cr_val;
                    float b = y_val + 1.8556f * cb_val;

                    // Clamp and convert to 8-bit BGRA
                    auto clamp8 = [](float v) -> uint8_t {
                        return static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, v * 255.0f)));
                    };

                    uint8_t* pixel = dst_row + col * 4;
                    pixel[0] = clamp8(b);
                    pixel[1] = clamp8(g);
                    pixel[2] = clamp8(r);
                    pixel[3] = 255;
                }
            }
            break;
        }

        default: {
            // Unknown format - fail fast with details
            assert(false && "FrameImpl::ensure_cpu_buffer: unsupported CVPixelBuffer format");
            break;
        }
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
