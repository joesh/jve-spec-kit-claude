#pragma once

// Hardware acceleration helpers for FFmpeg
// VideoToolbox on macOS, extensible for VAAPI/NVDEC later

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
}

#include <editor_media_platform/emp_errors.h>

namespace emp {
namespace impl {

// Check if codec supports VideoToolbox hardware acceleration
bool codec_supports_videotoolbox(AVCodecID codec_id);

// Initialize hardware device context
// Caller owns the returned AVBufferRef (must call av_buffer_unref)
Result<AVBufferRef*> init_hw_device_ctx(AVHWDeviceType type);

// Get the hw pixel format for a device type
AVPixelFormat hw_pix_fmt_for_device(AVHWDeviceType type);

// Transfer hw frame to sw frame (BGRA32 output)
// Caller must allocate dst_frame with av_frame_alloc()
Result<void> transfer_hw_frame_to_sw(AVFrame* hw_frame, AVFrame* sw_frame);

} // namespace impl
} // namespace emp
