#include "ffmpeg_context.h"
#include <editor_media_platform/emp_errors.h>

namespace emp {
namespace impl {

// Seek backoff window: 2 seconds (ensures keyframe before target for H.264 GOP)
constexpr TimeUS SEEK_BACKOFF_US = 2000000;

// Seek to keyframe before target with 2-second backoff
Result<void> seek_with_backoff(AVFormatContext* fmt_ctx, AVStream* stream,
                                AVCodecContext* codec_ctx, TimeUS target_us) {
    // Calculate seek target with backoff
    TimeUS stream_start_us = stream_pts_to_us(stream->start_time, stream);
    TimeUS seek_target_us = target_us - SEEK_BACKOFF_US;
    if (seek_target_us < stream_start_us) {
        seek_target_us = stream_start_us;
    }

    // Convert to stream time base
    int64_t seek_pts = us_to_stream_pts(seek_target_us, stream);

    // Flush codec before seeking
    avcodec_flush_buffers(codec_ctx);

    // Seek to keyframe at or before target
    int ret = av_seek_frame(fmt_ctx, stream->index, seek_pts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        // Try seeking to start on failure
        ret = av_seek_frame(fmt_ctx, stream->index, stream->start_time, AVSEEK_FLAG_BACKWARD);
        if (ret < 0) {
            return ffmpeg_error(ret, "av_seek_frame");
        }
    }

    return Result<void>();
}

// Check if we need to seek (current position is too far from target)
bool need_seek(TimeUS current_pts_us, TimeUS target_us, bool have_current) {
    if (!have_current) {
        return true;
    }

    // If target is before current position, need to seek
    if (target_us < current_pts_us) {
        return true;
    }

    // If target is more than 2 seconds ahead, seek (optimization)
    if (target_us - current_pts_us > SEEK_BACKOFF_US) {
        return true;
    }

    return false;
}

} // namespace impl
} // namespace emp
