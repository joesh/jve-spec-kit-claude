#include "ffmpeg_hwaccel.h"
#include "ffmpeg_context.h"
#include <cassert>
#include <cstdio>

namespace emp {
namespace impl {

// Check if codec supports VideoToolbox hw acceleration
bool codec_supports_videotoolbox(AVCodecID codec_id) {
#ifdef EMP_HAS_VIDEOTOOLBOX
    switch (codec_id) {
        case AV_CODEC_ID_H264:
        case AV_CODEC_ID_HEVC:
        case AV_CODEC_ID_VP9:
        case AV_CODEC_ID_PRORES:
            return true;
        default:
            return false;
    }
#else
    (void)codec_id;
    return false;
#endif
}

Result<AVBufferRef*> init_hw_device_ctx(AVHWDeviceType type) {
    AVBufferRef* hw_device_ctx = nullptr;
    int ret = av_hwdevice_ctx_create(&hw_device_ctx, type, nullptr, nullptr, 0);
    if (ret < 0) {
        return ffmpeg_error(ret, "av_hwdevice_ctx_create");
    }
    return hw_device_ctx;
}

AVPixelFormat hw_pix_fmt_for_device(AVHWDeviceType type) {
    switch (type) {
#ifdef EMP_HAS_VIDEOTOOLBOX
        case AV_HWDEVICE_TYPE_VIDEOTOOLBOX:
            return AV_PIX_FMT_VIDEOTOOLBOX;
#endif
        case AV_HWDEVICE_TYPE_VAAPI:
            return AV_PIX_FMT_VAAPI;
        case AV_HWDEVICE_TYPE_CUDA:
            return AV_PIX_FMT_CUDA;
        case AV_HWDEVICE_TYPE_DXVA2:
            return AV_PIX_FMT_DXVA2_VLD;
        case AV_HWDEVICE_TYPE_D3D11VA:
            return AV_PIX_FMT_D3D11;
        default:
            return AV_PIX_FMT_NONE;
    }
}

Result<void> transfer_hw_frame_to_sw(AVFrame* hw_frame, AVFrame* sw_frame) {
    assert(hw_frame && "hw_frame is null");
    assert(sw_frame && "sw_frame is null");

    // av_hwframe_transfer_data copies from GPU to CPU
    // It allocates the destination buffer if needed
    int ret = av_hwframe_transfer_data(sw_frame, hw_frame, 0);
    if (ret < 0) {
        return ffmpeg_error(ret, "av_hwframe_transfer_data");
    }

    // Copy metadata
    sw_frame->pts = hw_frame->pts;
    sw_frame->pkt_dts = hw_frame->pkt_dts;
    sw_frame->duration = hw_frame->duration;

    return Result<void>();
}

} // namespace impl
} // namespace emp
