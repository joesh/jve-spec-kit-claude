#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_rate.h>
#include "impl/media_file_impl.h"
#include "impl/ffmpeg_context.h"  // av_log_set_level
#include <cassert>
#include <climits>  // INT_MAX for av_reduce
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

// Parse timecode string "HH:MM:SS:FF" (or "HH:MM:SS;FF" for drop-frame)
// into a frame count at the given rate. Returns 0 on parse failure.
static int64_t parse_timecode_tag(const char* tc_str, int32_t fps_num, int32_t fps_den) {
    if (!tc_str || fps_num <= 0 || fps_den <= 0) return 0;
    int hh = 0, mm = 0, ss = 0, ff = 0;
    // %*c matches either ':' (non-drop) or ';' (drop-frame)
    if (sscanf(tc_str, "%d:%d:%d%*c%d", &hh, &mm, &ss, &ff) != 4) return 0;
    double fps = static_cast<double>(fps_num) / fps_den;
    return static_cast<int64_t>(((hh * 3600) + (mm * 60) + ss) * fps + ff);
}

// Find the first non-null "timecode" tag across metadata dictionaries.
static const char* find_timecode_tag(AVFormatContext* fmt, AVStream* video_stream) {
    if (video_stream) {
        AVDictionaryEntry* e = av_dict_get(video_stream->metadata, "timecode", nullptr, 0);
        if (e && e->value) return e->value;
    }
    AVDictionaryEntry* e = av_dict_get(fmt->metadata, "timecode", nullptr, 0);
    return (e && e->value) ? e->value : nullptr;
}

// Extract video TC origin in frames at video rate.
// Camera files: from "timecode" metadata tag.
// Broadcast files: from stream start_time (PTS origin).
static int64_t extract_video_tc_origin(AVFormatContext* fmt, AVStream* video_stream,
                                        const MediaFileInfo& info) {
    // Timecode metadata tag (camera MOV/MP4, ProRes, BRAW)
    const char* tc_str = find_timecode_tag(fmt, video_stream);
    int64_t tc = parse_timecode_tag(tc_str, info.video_fps_num, info.video_fps_den);
    if (tc > 0) return tc;

    // Stream start_time (broadcast MXF, some professional formats)
    if (video_stream && video_stream->start_time != AV_NOPTS_VALUE
        && video_stream->start_time > 0) {
        TimeUS start_us = impl::stream_pts_to_us(video_stream->start_time, video_stream);
        tc = (start_us * info.video_fps_num) / (1000000LL * info.video_fps_den);
        if (tc > 0) return tc;
    }

    return 0;
}

// Extract audio TC origin in samples at sample rate.
// BWF WAV: from "time_reference" format tag (already in samples).
// Other: from stream start_time converted to samples.
static int64_t extract_audio_tc_origin(AVFormatContext* fmt, AVStream* audio_stream,
                                        const MediaFileInfo& info) {
    // BWF time_reference (Pro Tools, sound post WAV files)
    AVDictionaryEntry* tr = av_dict_get(fmt->metadata, "time_reference", nullptr, 0);
    if (tr && tr->value) {
        char* endptr = nullptr;
        int64_t val = strtoll(tr->value, &endptr, 10);
        if (endptr != tr->value && val >= 0) return val;
    }

    // Stream start_time — only if it represents a real TC origin, not codec
    // priming delay. Video files commonly have audio start_time of a few ms
    // (encoder padding) which is not a TC origin. Threshold: 1 second.
    if (audio_stream && audio_stream->start_time != AV_NOPTS_VALUE
        && audio_stream->start_time > 0) {
        TimeUS start_us = impl::stream_pts_to_us(audio_stream->start_time, audio_stream);
        if (start_us >= 1000000LL) {  // >= 1 second = real TC, not priming
            return (start_us * info.audio_sample_rate) / 1000000LL;
        }
    }

    return 0;
}

// Extract BWF time_reference (raw, for diagnostic/relink use).
// Returns -1 if not a BWF file.
static int64_t extract_bwf_time_reference(AVFormatContext* fmt) {
    AVDictionaryEntry* tr = av_dict_get(fmt->metadata, "time_reference", nullptr, 0);
    if (tr && tr->value) {
        char* endptr = nullptr;
        int64_t val = strtoll(tr->value, &endptr, 10);
        if (endptr != tr->value && val >= 0) return val;
    }
    return -1;
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

        // Extract pixel aspect ratio (sample aspect ratio in FFmpeg terms)
        // Prefer stream-level SAR (container metadata), fall back to codec-level
        AVRational sar = video_stream->sample_aspect_ratio;
        if (sar.num <= 0 || sar.den <= 0) {
            sar = params->sample_aspect_ratio;
        }
        if (sar.num > 0 && sar.den > 0) {
            int num, den;
            av_reduce(&num, &den, sar.num, sar.den, INT_MAX);
            info.video_par_num = static_cast<int32_t>(num);
            info.video_par_den = static_cast<int32_t>(den);
        } else {
            info.video_par_num = 1;
            info.video_par_den = 1;
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

    // ── TC origins ──
    // Each media type stores its TC origin in a different place:
    //   Camera video (MOV/MP4):  timecode metadata tag "HH:MM:SS:FF"
    //   Broadcast video (MXF):   stream start_time (PTS origin)
    //   Post audio (BWF WAV):    format tag "time_reference" (samples)
    //   Other audio:             stream start_time (PTS origin)
    //
    // first_frame_tc: frame number of the first video frame (at video rate)
    // first_sample_tc: sample number of the first audio sample (at sample rate)
    // Both default to 0 (file starts at TC 00:00:00:00).

    info.first_frame_tc = extract_video_tc_origin(fmt, video_stream, info);
    info.first_sample_tc = extract_audio_tc_origin(fmt, audio_stream, info);
    info.bwf_time_reference = extract_bwf_time_reference(fmt);

    // Sanity check TC origins — negative values are invalid, unreasonably large
    // values indicate parsing errors. Max: 24 hours at 96kHz = 8,294,400,000 samples.
    assert(info.first_frame_tc >= 0 && "MediaFile::Open: first_frame_tc must be >= 0");
    assert(info.first_sample_tc >= 0 && "MediaFile::Open: first_sample_tc must be >= 0");
    constexpr int64_t MAX_TC_SAMPLES = 24LL * 3600 * 96000;  // 24h @ 96kHz
    constexpr int64_t MAX_TC_FRAMES = 24LL * 3600 * 120;     // 24h @ 120fps
    assert(info.first_frame_tc <= MAX_TC_FRAMES &&
        "MediaFile::Open: first_frame_tc exceeds 24h — corrupt stream start_time?");
    assert(info.first_sample_tc <= MAX_TC_SAMPLES &&
        "MediaFile::Open: first_sample_tc exceeds 24h — corrupt BWF/stream start_time?");

    return std::make_shared<MediaFile>(std::move(impl), std::move(info));
}

} // namespace emp
