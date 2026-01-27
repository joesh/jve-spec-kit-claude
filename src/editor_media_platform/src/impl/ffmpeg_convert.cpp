#include "ffmpeg_context.h"
#include <cstring>
#include <vector>

namespace emp {
namespace impl {

// Allocate BGRA32 buffer with proper alignment
std::vector<uint8_t> allocate_bgra_buffer(int width, int height, int* out_stride) {
    // Align stride to 32 bytes for SIMD operations
    int stride = ((width * 4) + 31) & ~31;
    *out_stride = stride;
    return std::vector<uint8_t>(stride * height);
}

// Convert AVFrame to BGRA32 buffer
void convert_frame_to_bgra(FFmpegScaleContext& scale_ctx, AVFrame* frame,
                            uint8_t* dst_data, int dst_stride) {
    scale_ctx.convert(frame, dst_data, dst_stride);
}

} // namespace impl
} // namespace emp
