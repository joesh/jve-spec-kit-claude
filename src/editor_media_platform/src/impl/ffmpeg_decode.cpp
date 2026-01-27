#include "ffmpeg_context.h"
#include <editor_media_platform/emp_errors.h>
#include <cassert>

namespace emp {
namespace impl {

// Decode next frame from the codec context
// Returns:
//   - Frame on success
//   - EOFReached when no more frames
//   - DecodeFailed on error
Result<AVFrame*> decode_next_frame(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                    int stream_idx, AVPacket* pkt, AVFrame* frame) {
    int ret;

    while (true) {
        // Try to receive a frame from the decoder
        ret = avcodec_receive_frame(codec_ctx, frame);
        if (ret == 0) {
            return frame;
        } else if (ret == AVERROR(EAGAIN)) {
            // Need more packets
        } else if (ret == AVERROR_EOF) {
            return Error::eof();
        } else {
            return ffmpeg_error(ret, "avcodec_receive_frame");
        }

        // Read next packet
        while (true) {
            ret = av_read_frame(fmt_ctx, pkt);
            if (ret < 0) {
                if (ret == AVERROR_EOF) {
                    // Flush decoder
                    avcodec_send_packet(codec_ctx, nullptr);
                    ret = avcodec_receive_frame(codec_ctx, frame);
                    if (ret == 0) {
                        return frame;
                    }
                    return Error::eof();
                }
                return ffmpeg_error(ret, "av_read_frame");
            }

            if (pkt->stream_index == stream_idx) {
                break;
            }
            av_packet_unref(pkt);
        }

        // Send packet to decoder
        ret = avcodec_send_packet(codec_ctx, pkt);
        av_packet_unref(pkt);

        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            return ffmpeg_error(ret, "avcodec_send_packet");
        }
    }
}

// Decode frames until we find one with pts <= target_us
// Returns the frame with largest pts <= target_us (floor-on-grid semantics)
Result<AVFrame*> decode_until_target(AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
                                      AVStream* stream, int stream_idx,
                                      TimeUS target_us,
                                      AVPacket* pkt, AVFrame* frame, AVFrame* best_frame) {
    bool have_best = false;
    TimeUS best_pts_us = INT64_MIN;

    while (true) {
        auto result = decode_next_frame(codec_ctx, fmt_ctx, stream_idx, pkt, frame);
        if (result.is_error()) {
            if (result.error().code == ErrorCode::EOFReached && have_best) {
                // At EOF, return best frame we have
                av_frame_unref(frame);
                return best_frame;
            }
            return result.error();
        }

        TimeUS frame_pts_us = stream_pts_to_us(frame->pts, stream);

        if (frame_pts_us <= target_us) {
            // This frame is a candidate (pts <= target)
            if (!have_best || frame_pts_us > best_pts_us) {
                // Swap into best_frame
                av_frame_unref(best_frame);
                av_frame_move_ref(best_frame, frame);
                best_pts_us = frame_pts_us;
                have_best = true;
            }
        } else {
            // This frame is past target
            // Return best if we have one
            if (have_best) {
                av_frame_unref(frame);
                return best_frame;
            }
            // No frame with pts <= target found, return this first frame
            // (snap to first decodable frame)
            av_frame_move_ref(best_frame, frame);
            return best_frame;
        }
    }
}

} // namespace impl
} // namespace emp
