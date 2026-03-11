#include "ffmpeg_context.h"
#include <editor_media_platform/emp_errors.h>
#include <cassert>
#include <vector>

namespace emp {
namespace impl {

// Decoded frame with its PTS in microseconds
struct DecodedFrame {
    AVFrame* frame;
    TimeUS pts_us;
};

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
// NOTE: With B-frames, decoder output is NOT in PTS order. We must continue
// decoding past the target to drain any buffered B-frames that belong before it.
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
                av_frame_unref(frame);
                return best_frame;
            }
            return result.error();
        }

        TimeUS frame_pts_us = stream_pts_to_us(frame->pts, stream);

        if (frame_pts_us <= target_us) {
            if (!have_best || frame_pts_us > best_pts_us) {
                av_frame_unref(best_frame);
                av_frame_move_ref(best_frame, frame);
                best_pts_us = frame_pts_us;
                have_best = true;
            } else {
                av_frame_unref(frame);
            }
        } else {
            // Past target — floor frame (if any) is confirmed
            av_frame_unref(frame);
            if (have_best) {
                return best_frame;
            }
            return Error::internal("No frame found at target time");
        }
    }
}

// Decode frames until we find one past target_us, capturing ALL decoder output
// Returns vector of (AVFrame*, pts_us) pairs. Caller owns all returned AVFrames.
// The returned frames are in presentation order (PTS order), NOT decode order.
Result<std::vector<DecodedFrame>> decode_frames_batch(
    AVCodecContext* codec_ctx, AVFormatContext* fmt_ctx,
    AVStream* stream, int stream_idx,
    TimeUS target_us, AVPacket* pkt, AVFrame* temp_frame)
{
    std::vector<DecodedFrame> frames;
    bool found_target = false;

    while (true) {
        // Receive frames from decoder
        while (true) {
            int ret = avcodec_receive_frame(codec_ctx, temp_frame);
            if (ret == AVERROR(EAGAIN)) {
                break;  // Need more packets
            } else if (ret == AVERROR_EOF) {
                if (frames.empty()) {
                    return Error::eof();
                }
                return frames;
            } else if (ret < 0) {
                for (auto& df : frames) {
                    av_frame_free(&df.frame);
                }
                return ffmpeg_error(ret, "avcodec_receive_frame");
            }

            AVFrame* new_frame = av_frame_alloc();
            assert(new_frame && "av_frame_alloc failed");
            av_frame_move_ref(new_frame, temp_frame);

            TimeUS pts_us = stream_pts_to_us(new_frame->pts, stream);
            frames.push_back({new_frame, pts_us});

            if (pts_us >= target_us) {
                found_target = true;
            }
        }

        // Got the target frame — done
        if (found_target) {
            return frames;
        }

        // Read next packet
        while (true) {
            int ret = av_read_frame(fmt_ctx, pkt);
            if (ret == AVERROR_EOF) {
                // Flush decoder
                avcodec_send_packet(codec_ctx, nullptr);
                // Drain remaining frames
                while (true) {
                    ret = avcodec_receive_frame(codec_ctx, temp_frame);
                    if (ret == AVERROR_EOF || ret == AVERROR(EAGAIN)) {
                        break;
                    }
                    if (ret < 0) {
                        for (auto& df : frames) {
                            av_frame_free(&df.frame);
                        }
                        return ffmpeg_error(ret, "avcodec_receive_frame (flush)");
                    }
                    AVFrame* new_frame = av_frame_alloc();
                    assert(new_frame && "av_frame_alloc failed");
                    av_frame_move_ref(new_frame, temp_frame);
                    TimeUS pts_us = stream_pts_to_us(new_frame->pts, stream);
                    frames.push_back({new_frame, pts_us});
                }
                if (frames.empty()) {
                    return Error::eof();
                }
                return frames;
            }
            if (ret < 0) {
                for (auto& df : frames) {
                    av_frame_free(&df.frame);
                }
                return ffmpeg_error(ret, "av_read_frame");
            }

            if (pkt->stream_index == stream_idx) {
                break;
            }
            av_packet_unref(pkt);
        }

        // Send packet to decoder
        int ret = avcodec_send_packet(codec_ctx, pkt);
        av_packet_unref(pkt);

        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            for (auto& df : frames) {
                av_frame_free(&df.frame);
            }
            return ffmpeg_error(ret, "avcodec_send_packet");
        }
    }
}

} // namespace impl
} // namespace emp
