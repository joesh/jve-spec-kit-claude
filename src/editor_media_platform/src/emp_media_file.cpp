#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_rate.h>
#include "impl/media_file_impl.h"
#include "impl/ffmpeg_context.h"  // av_log_set_level
#include <cassert>
#include <mutex>

namespace emp {

MediaFile::MediaFile(std::unique_ptr<MediaFileImpl> impl, MediaFileInfo info)
    : m_impl(std::move(impl)), m_info(std::move(info)) {
    assert(m_impl && "MediaFile impl cannot be null");
}

MediaFile::~MediaFile() = default;

const MediaFileInfo& MediaFile::info() const {
    return m_info;
}

// Select nominal rate using FFmpeg heuristic (from spec)
static Rate select_nominal_rate(AVStream* stream, bool* is_vfr_out) {
    *is_vfr_out = false;

    AVRational avg_rate = stream->avg_frame_rate;
    AVRational r_rate = stream->r_frame_rate;

    bool avg_valid = avg_rate.num > 0 && avg_rate.den > 0;
    bool r_valid = r_rate.num > 0 && r_rate.den > 0;

    Rate result;

    if (avg_valid && !r_valid) {
        result = impl::av_rational_to_rate(avg_rate);
    } else if (!avg_valid && r_valid) {
        result = impl::av_rational_to_rate(r_rate);
    } else if (avg_valid && r_valid) {
        Rate avg = impl::av_rational_to_rate(avg_rate);
        Rate r = impl::av_rational_to_rate(r_rate);

        if (RateUtils::are_close(avg, r)) {
            // Prefer avg_frame_rate
            result = avg;
        } else {
            // Rates disagree significantly - mark as VFR
            *is_vfr_out = true;

            // Choose nearest canonical rate
            Rate snapped_avg = RateUtils::snap_to_canonical(avg);
            Rate snapped_r = RateUtils::snap_to_canonical(r);

            // Prefer avg if it snapped to canonical
            if (snapped_avg.num != avg.num || snapped_avg.den != avg.den) {
                result = snapped_avg;
            } else if (snapped_r.num != r.num || snapped_r.den != r.den) {
                result = snapped_r;
            } else {
                // Neither is close to canonical, use avg as-is
                result = avg;
            }
        }
    } else {
        // Neither valid - use 30fps as last resort and mark VFR
        *is_vfr_out = true;
        result = canonical_rates::RATE_30;
    }

    // Snap to canonical
    return RateUtils::snap_to_canonical(result);
}

Result<std::shared_ptr<MediaFile>> MediaFile::Open(const std::string& path) {
    // Suppress FFmpeg's h264 decoder warnings (e.g. "co located POCs unavailable"
    // after seeks). These are normal and harmless but noisy on stderr.
    static std::once_flag s_ffmpeg_log_init;
    std::call_once(s_ffmpeg_log_init, [] {
        av_log_set_level(AV_LOG_FATAL);
    });

    auto impl = std::make_unique<MediaFileImpl>();

    // Open file
    auto open_result = impl->fmt_ctx.open(path);
    if (open_result.is_error()) {
        return open_result.error();
    }

    // Build MediaFileInfo
    MediaFileInfo info;
    info.path = path;

    // Try to find video stream (optional - audio-only files are valid)
    AVStream* video_stream = nullptr;
    auto stream_result = impl->fmt_ctx.find_video_stream();
    if (stream_result.is_ok()) {
        video_stream = impl->fmt_ctx.video_stream();
        AVCodecParameters* params = impl->fmt_ctx.video_codec_params();
        info.has_video = true;
        info.video_width = params->width;
        info.video_height = params->height;

        // Nominal rate with canonical snapping
        bool is_vfr = false;
        Rate nominal = select_nominal_rate(video_stream, &is_vfr);
        info.video_fps_num = nominal.num;
        info.video_fps_den = nominal.den;
        info.is_vfr = is_vfr;

        // Extract rotation from display matrix side data (phone footage)
        // FFmpeg 7+: side data is in codecpar->coded_side_data
        info.rotation = 0;
        AVCodecParameters* params_for_rotation = impl->fmt_ctx.video_codec_params();
        for (int i = 0; i < params_for_rotation->nb_coded_side_data; i++) {
            AVPacketSideData* sd = &params_for_rotation->coded_side_data[i];
            if (sd->type == AV_PKT_DATA_DISPLAYMATRIX && sd->size >= sizeof(int32_t) * 9) {
                double theta = av_display_rotation_get(reinterpret_cast<const int32_t*>(sd->data));
                // Normalize to 0, 90, 180, 270 (FFmpeg returns negative for CW rotation)
                int rot = static_cast<int>(-theta);
                while (rot < 0) rot += 360;
                while (rot >= 360) rot -= 360;
                // Snap to nearest 90° increment
                info.rotation = ((rot + 45) / 90) * 90 % 360;
                break;
            }
        }
    } else {
        info.has_video = false;
        info.video_width = 0;
        info.video_height = 0;
        // fps will be set below for audio-only files (use sample rate)
        info.video_fps_num = 0;
        info.video_fps_den = 1;
        info.is_vfr = false;
        info.rotation = 0;
    }

    // Find audio stream (optional - video-only files are valid)
    AVStream* audio_stream = nullptr;
    int audio_idx = impl->fmt_ctx.find_audio_stream();
    if (audio_idx >= 0) {
        audio_stream = impl->fmt_ctx.audio_stream();
        AVCodecParameters* audio_params = impl->fmt_ctx.audio_codec_params();
        info.has_audio = true;
        info.audio_sample_rate = audio_params->sample_rate;
        info.audio_channels = audio_params->ch_layout.nb_channels;

        // For audio-only files, use sample rate as pseudo-fps for time calculations
        if (!info.has_video && info.audio_sample_rate > 0) {
            info.video_fps_num = info.audio_sample_rate;
            info.video_fps_den = 1;
        }
    } else {
        info.has_audio = false;
        info.audio_sample_rate = 0;
        info.audio_channels = 0;
    }

    // Require at least one stream
    if (!info.has_video && !info.has_audio) {
        return Error::unsupported("No video or audio stream found");
    }

    // Duration in microseconds - try format, then video stream, then audio stream
    AVFormatContext* fmt = impl->fmt_ctx.get();
    if (fmt->duration != AV_NOPTS_VALUE) {
        info.duration_us = av_rescale_q(fmt->duration, AV_TIME_BASE_Q, {1, 1000000});
    } else if (video_stream && video_stream->duration != AV_NOPTS_VALUE) {
        info.duration_us = impl::stream_pts_to_us(video_stream->duration, video_stream);
    } else if (audio_stream && audio_stream->duration != AV_NOPTS_VALUE) {
        info.duration_us = impl::stream_pts_to_us(audio_stream->duration, audio_stream);
    } else {
        info.duration_us = 0;
    }

    // Start timecode in frames at media's native rate
    // Use video stream start_time if available, else audio stream, else 0
    info.start_tc = 0;
    if (video_stream && video_stream->start_time != AV_NOPTS_VALUE) {
        TimeUS start_us = impl::stream_pts_to_us(video_stream->start_time, video_stream);
        // frames = (us / 1000000) * (fps_num / fps_den)
        //        = us * fps_num / (1000000 * fps_den)
        info.start_tc = (start_us * info.video_fps_num) / (1000000LL * info.video_fps_den);
    } else if (audio_stream && audio_stream->start_time != AV_NOPTS_VALUE) {
        TimeUS start_us = impl::stream_pts_to_us(audio_stream->start_time, audio_stream);
        info.start_tc = (start_us * info.video_fps_num) / (1000000LL * info.video_fps_den);
    }

    return std::make_shared<MediaFile>(std::move(impl), std::move(info));
}

} // namespace emp
