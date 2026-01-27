#include <editor_media_platform/emp_asset.h>
#include <editor_media_platform/emp_rate.h>
#include "impl/asset_impl.h"
#include <cassert>

namespace emp {

Asset::Asset(std::unique_ptr<AssetImpl> impl, AssetInfo info)
    : m_impl(std::move(impl)), m_info(std::move(info)) {
    assert(m_impl && "Asset impl cannot be null");
}

Asset::~Asset() = default;

const AssetInfo& Asset::info() const {
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

Result<std::shared_ptr<Asset>> Asset::Open(const std::string& path) {
    auto impl = std::make_unique<AssetImpl>();

    // Open file
    auto open_result = impl->fmt_ctx.open(path);
    if (open_result.is_error()) {
        return open_result.error();
    }

    // Find video stream
    auto stream_result = impl->fmt_ctx.find_video_stream();
    if (stream_result.is_error()) {
        return stream_result.error();
    }

    AVStream* video_stream = impl->fmt_ctx.video_stream();
    AVCodecParameters* params = impl->fmt_ctx.video_codec_params();

    // Build AssetInfo
    AssetInfo info;
    info.path = path;
    info.has_video = true;
    info.video_width = params->width;
    info.video_height = params->height;

    // Duration in microseconds
    AVFormatContext* fmt = impl->fmt_ctx.get();
    if (fmt->duration != AV_NOPTS_VALUE) {
        info.duration_us = av_rescale_q(fmt->duration, AV_TIME_BASE_Q, {1, 1000000});
    } else if (video_stream->duration != AV_NOPTS_VALUE) {
        info.duration_us = impl::stream_pts_to_us(video_stream->duration, video_stream);
    } else {
        // Estimate from bitrate if available
        info.duration_us = 0;
    }

    // Nominal rate with canonical snapping
    bool is_vfr = false;
    Rate nominal = select_nominal_rate(video_stream, &is_vfr);
    info.video_fps_num = nominal.num;
    info.video_fps_den = nominal.den;
    info.is_vfr = is_vfr;

    // Find audio stream (optional - not an error if missing)
    int audio_idx = impl->fmt_ctx.find_audio_stream();
    if (audio_idx >= 0) {
        AVCodecParameters* audio_params = impl->fmt_ctx.audio_codec_params();
        info.has_audio = true;
        info.audio_sample_rate = audio_params->sample_rate;
        info.audio_channels = audio_params->ch_layout.nb_channels;
    } else {
        info.has_audio = false;
        info.audio_sample_rate = 0;
        info.audio_channels = 0;
    }

    return std::make_shared<Asset>(std::move(impl), std::move(info));
}

} // namespace emp
