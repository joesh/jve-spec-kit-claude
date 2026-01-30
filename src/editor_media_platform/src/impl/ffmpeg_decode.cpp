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

    // B-frame depth: keep decoding this many frames after seeing one past target
    // H.264 GOP can have long chains; VideoToolbox may have additional buffering
    // Use generous lookahead to ensure we don't miss buffered B-frames
    constexpr int BFRAME_LOOKAHEAD = 10;
    int frames_past_target = 0;

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
            } else {
                av_frame_unref(frame);
            }
            // Reset counter - we found a frame we want
            frames_past_target = 0;
        } else {
            // This frame is past target
            av_frame_unref(frame);
            frames_past_target++;

            // Keep decoding to drain B-frame buffer
            if (frames_past_target >= BFRAME_LOOKAHEAD && have_best) {
                return best_frame;
            }
            // If we don't have a best yet, keep looking
            if (frames_past_target >= BFRAME_LOOKAHEAD * 2) {
                // Give up - return best or error
                if (have_best) {
                    return best_frame;
                }
                return Error::internal("No frame found at target time");
            }
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
    bool found_target_or_past = false;

    // Count frames with PTS >= target. Once we have BFRAME_LOOKAHEAD such
    // frames, the cache has contiguous PTS coverage past the target.
    // CRITICAL: do NOT reset this counter when late B-frames (PTS < target)
    // arrive from the decoder pipeline — they are expected reorder output,
    // not a signal to restart counting. Resetting caused premature batch
    // return with PTS holes → stale-cache rejection → stutter.
    constexpr int BFRAME_LOOKAHEAD = 8;
    int frames_past_target = 0;

    while (true) {
        // Try to receive frames from decoder (may have buffered B-frames)
        while (true) {
            int ret = avcodec_receive_frame(codec_ctx, temp_frame);
            if (ret == AVERROR(EAGAIN)) {
                break;  // Need more packets
            } else if (ret == AVERROR_EOF) {
                // Decoder drained - return what we have
                if (frames.empty()) {
                    return Error::eof();
                }
                return frames;
            } else if (ret < 0) {
                // Free any frames we've collected
                for (auto& df : frames) {
                    av_frame_free(&df.frame);
                }
                return ffmpeg_error(ret, "avcodec_receive_frame");
            }

            // Got a frame - allocate new AVFrame and move data to it
            AVFrame* new_frame = av_frame_alloc();
            assert(new_frame && "av_frame_alloc failed");
            av_frame_move_ref(new_frame, temp_frame);

            TimeUS pts_us = stream_pts_to_us(new_frame->pts, stream);
            frames.push_back({new_frame, pts_us});

            // Count only frames with PTS >= target toward completion.
            // Late B-frames (PTS < target) are collected but don't advance
            // or reset the counter — they're normal reorder pipeline output.
            if (pts_us >= target_us) {
                frames_past_target++;
                if (frames_past_target >= BFRAME_LOOKAHEAD) {
                    found_target_or_past = true;
                }
            }
        }

        // If we've seen enough frames past target, we're done
        if (found_target_or_past && !frames.empty()) {
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
