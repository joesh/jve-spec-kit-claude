#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_rate.h>
#include "impl/media_file_impl.h"
#include "impl/ffmpeg_context.h"  // av_log_set_level
#include "impl/braw_decode.h"
#include "../../assert_handler.h"  // JVE_ASSERT
#include <atomic>
#include <cassert>
#include <climits>  // INT_MAX for av_reduce
#include <mutex>
#include <thread>

namespace emp {

MediaFile::MediaFile(std::unique_ptr<MediaFileImpl> impl, MediaFileInfo info)
    : m_impl(std::move(impl)), m_info(std::move(info)) {
    assert(m_impl && "MediaFile impl cannot be null");
}

MediaFile::~MediaFile() = default;

const MediaFileInfo& MediaFile::info() const {
    return m_info;
}

Result<void> MediaFile::ProbeCodec() const {
    // BRAW: SDK IS the decoder — if we got metadata, we can decode.
    if (m_impl->backend == MediaFileBackend::Braw) {
        return {};
    }

    if (!m_info.has_video) {
        return {};  // audio-only — no video codec to check
    }
    auto* params = m_impl->fmt_ctx.video_codec_params();
    if (!params) {
        return Error::unsupported("No video codec parameters");
    }
    const AVCodec* decoder = avcodec_find_decoder(params->codec_id);
    if (!decoder) {
        return Error::unsupported(
            std::string("No decoder for codec ") + avcodec_get_name(params->codec_id));
    }
    return {};
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
// Returns {value, true} when an authoritative source was found, or
// {0, false} when no source was present (default — caller decides
// whether to treat as "TC is 0" or "TC is unknown").
static std::pair<int64_t, bool> extract_video_tc_origin(
        AVFormatContext* fmt, AVStream* video_stream, const MediaFileInfo& info) {
    // Timecode metadata tag (camera MOV/MP4, ProRes, BRAW). Tag presence —
    // not value — is what makes this authoritative: "timecode=00:00:00:00"
    // is a real, explicit zero TC.
    const char* tc_str = find_timecode_tag(fmt, video_stream);
    if (tc_str) {
        int64_t tc = parse_timecode_tag(tc_str, info.video_fps_num, info.video_fps_den);
        return {tc, true};
    }

    // Stream start_time (broadcast MXF, some PTS-encoded containers). We
    // only trust values >= 1s to avoid treating codec priming delay as a
    // TC origin.
    if (video_stream && video_stream->start_time != AV_NOPTS_VALUE
        && video_stream->start_time > 0) {
        TimeUS start_us = impl::stream_pts_to_us(video_stream->start_time, video_stream);
        int64_t tc = (start_us * info.video_fps_num) / (1000000LL * info.video_fps_den);
        if (tc > 0) return {tc, true};
    }

    return {0, false};
}

// Extract audio TC origin in samples at sample rate.
// BWF WAV: from "time_reference" format tag (already in samples).
// Other: from stream start_time converted to samples.
// Returns {value, true} when an authoritative source was found, or
// {0, false} when no source was present (plain MP3, non-BWF WAV, etc).
static std::pair<int64_t, bool> extract_audio_tc_origin(
        AVFormatContext* fmt, AVStream* audio_stream, const MediaFileInfo& info) {
    // BWF time_reference (Pro Tools, sound post WAV files)
    AVDictionaryEntry* tr = av_dict_get(fmt->metadata, "time_reference", nullptr, 0);
    if (tr && tr->value) {
        char* endptr = nullptr;
        int64_t val = strtoll(tr->value, &endptr, 10);
        if (endptr != tr->value && val >= 0) return {val, true};
    }

    // Stream start_time — only if it represents a real TC origin, not codec
    // priming delay. Video files commonly have audio start_time of a few ms
    // (encoder padding) which is not a TC origin. Threshold: 1 second.
    if (audio_stream && audio_stream->start_time != AV_NOPTS_VALUE
        && audio_stream->start_time > 0) {
        TimeUS start_us = impl::stream_pts_to_us(audio_stream->start_time, audio_stream);
        if (start_us >= 1000000LL) {  // >= 1 second = real TC, not priming
            return {(start_us * info.audio_sample_rate) / 1000000LL, true};
        }
    }

    return {0, false};
}

// Derive audio TC origin from video TC when the file has both streams on a
// common clock (camera MOVs, BRAW). Fills in info.first_sample_tc /
// has_audio_tc_origin only when (a) video TC is authoritative, (b) the file
// has audio, (c) audio TC wasn't already set by a primary source (BWF
// time_reference, stream start_time ≥ 1s). Primary sources win.
static void derive_audio_tc_from_video(MediaFileInfo& info) {
    if (!info.has_video_tc_origin) return;
    if (!info.has_audio) return;
    if (info.has_audio_tc_origin) return;
    if (info.audio_sample_rate <= 0) return;
    if (info.video_fps_num <= 0 || info.video_fps_den <= 0) return;

    info.first_sample_tc = (info.first_frame_tc
        * static_cast<int64_t>(info.audio_sample_rate)
        * static_cast<int64_t>(info.video_fps_den))
        / static_cast<int64_t>(info.video_fps_num);
    info.has_audio_tc_origin = true;
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

// Build MediaFileInfo for a BRAW clip via SDK metadata probe.
// BRAW's probe is always metadata-only — same call used by both Open
// (needs a handle back) and ProbeMetadata (just wants the info).
static Result<MediaFileInfo> build_braw_info(const std::string& path) {
    auto probe = impl::braw_probe_clip(path);
    if (probe.is_error()) return probe.error();

    auto& bi = probe.value();
    MediaFileInfo info;
    info.path = path;
    info.has_video = true;
    info.video_width = bi.width;
    info.video_height = bi.height;
    info.video_fps_num = bi.fps_num;
    info.video_fps_den = bi.fps_den;
    info.is_vfr = false;
    info.rotation = 0;
    info.video_par_num = 1;
    info.video_par_den = 1;
    info.has_audio = bi.has_audio;
    info.audio_sample_rate = bi.audio_sample_rate;
    info.audio_channels = bi.audio_channels;
    info.duration_us = bi.duration_us;
    // BRAW's SDK probe always returns a duration. The "no duration
    // known" case doesn't arise here — if braw_probe_clip succeeded,
    // duration is authoritative.
    info.has_duration = bi.duration_us > 0;
    info.first_frame_tc = bi.first_frame_tc;
    info.bwf_time_reference = -1;

    constexpr int64_t MAX_TC_FRAMES = 24LL * 3600 * 120;
    assert(info.first_frame_tc >= 0 && "BRAW: first_frame_tc must be >= 0");
    if (info.first_frame_tc > MAX_TC_FRAMES) {
        info.first_frame_tc = 0;             // unreasonable TC — reset to 0
        info.has_video_tc_origin = false;    // and mark as unknown
    } else {
        info.has_video_tc_origin = true;     // BRAW metadata is authoritative
    }

    // BRAW has no separate audio TC source — derive from video TC on the
    // common-clock assumption. Defaults leave first_sample_tc=0 /
    // has_audio_tc_origin=false if derivation can't run.
    // Overflow handling mirrors the video-TC block above: clamp-to-unknown
    // rather than assert, because the BRAW SDK can surface implausible
    // values on malformed clips and we'd rather flag "no TC" than reject
    // the clip entirely (pre-existing pattern for this backend).
    derive_audio_tc_from_video(info);
    assert(info.first_sample_tc >= 0 && "build_braw_info: first_sample_tc must be >= 0");
    constexpr int64_t MAX_TC_SAMPLES = 24LL * 3600 * 96000;
    if (info.first_sample_tc > MAX_TC_SAMPLES) {
        info.first_sample_tc = 0;
        info.has_audio_tc_origin = false;
    }

    return info;
}

// Build MediaFileInfo from an already-opened FFmpegFormatContext. The ctx
// may have been opened with or without avformat_find_stream_info: fields
// derived from the container header (tmcd atom, BWF bext, codec params,
// sample_aspect_ratio) are populated either way; fields derived from
// packet analysis (full codec confirmation, some stream start_time values)
// may be less accurate in the no-find_stream_info case.
static Result<MediaFileInfo> build_ffmpeg_info(impl::FFmpegFormatContext& fmt_ctx,
                                                const std::string& path) {
    MediaFileInfo info;
    info.path = path;

    AVStream* video_stream = nullptr;
    auto stream_result = fmt_ctx.find_video_stream();
    if (stream_result.is_ok()) {
        video_stream = fmt_ctx.video_stream();
        AVCodecParameters* params = fmt_ctx.video_codec_params();
        info.has_video = true;
        info.video_width = params->width;
        info.video_height = params->height;

        bool is_vfr = false;
        Rate nominal = select_nominal_rate(video_stream, &is_vfr);
        info.video_fps_num = nominal.num;
        info.video_fps_den = nominal.den;
        info.is_vfr = is_vfr;

        info.rotation = 0;
        for (int i = 0; i < params->nb_coded_side_data; i++) {
            AVPacketSideData* sd = &params->coded_side_data[i];
            if (sd->type == AV_PKT_DATA_DISPLAYMATRIX && sd->size >= sizeof(int32_t) * 9) {
                double theta = av_display_rotation_get(reinterpret_cast<const int32_t*>(sd->data));
                int rot = static_cast<int>(-theta);
                while (rot < 0) rot += 360;
                while (rot >= 360) rot -= 360;
                info.rotation = ((rot + 45) / 90) * 90 % 360;
                break;
            }
        }

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
        info.video_fps_num = 0;
        info.video_fps_den = 1;
        info.is_vfr = false;
        info.rotation = 0;
    }

    AVStream* audio_stream = nullptr;
    int audio_idx = fmt_ctx.find_audio_stream();
    if (audio_idx >= 0) {
        audio_stream = fmt_ctx.audio_stream();
        AVCodecParameters* audio_params = fmt_ctx.audio_codec_params();
        info.has_audio = true;
        info.audio_sample_rate = audio_params->sample_rate;
        info.audio_channels = audio_params->ch_layout.nb_channels;

        if (!info.has_video && info.audio_sample_rate > 0) {
            info.video_fps_num = info.audio_sample_rate;
            info.video_fps_den = 1;
        }
    } else {
        info.has_audio = false;
        info.audio_sample_rate = 0;
        info.audio_channels = 0;
    }

    if (!info.has_video && !info.has_audio) {
        return Error::unsupported("No video or audio stream found");
    }

    AVFormatContext* fmt = fmt_ctx.get();
    if (fmt->duration != AV_NOPTS_VALUE) {
        info.duration_us = av_rescale_q(fmt->duration, AV_TIME_BASE_Q, {1, 1000000});
        info.has_duration = true;
    } else if (video_stream && video_stream->duration != AV_NOPTS_VALUE) {
        info.duration_us = impl::stream_pts_to_us(video_stream->duration, video_stream);
        info.has_duration = true;
    } else if (audio_stream && audio_stream->duration != AV_NOPTS_VALUE) {
        info.duration_us = impl::stream_pts_to_us(audio_stream->duration, audio_stream);
        info.has_duration = true;
    } else {
        info.duration_us = 0;
        info.has_duration = false;
    }

    auto video_tc = extract_video_tc_origin(fmt, video_stream, info);
    info.first_frame_tc = video_tc.first;
    info.has_video_tc_origin = video_tc.second;
    auto audio_tc = extract_audio_tc_origin(fmt, audio_stream, info);
    info.first_sample_tc = audio_tc.first;
    info.has_audio_tc_origin = audio_tc.second;
    info.bwf_time_reference = extract_bwf_time_reference(fmt);

    // When no primary audio TC source (BWF time_reference, audio stream
    // start_time ≥ 1s) was found, derive from video TC on the assumption
    // video and audio share a common recording clock (camera MOVs, etc.).
    // Primary-source audio TC wins when available.
    derive_audio_tc_from_video(info);

    assert(info.first_frame_tc >= 0 && "build_ffmpeg_info: first_frame_tc must be >= 0");
    assert(info.first_sample_tc >= 0 && "build_ffmpeg_info: first_sample_tc must be >= 0");
    constexpr int64_t MAX_TC_SAMPLES = 24LL * 3600 * 96000;
    constexpr int64_t MAX_TC_FRAMES = 24LL * 3600 * 120;
    assert(info.first_frame_tc <= MAX_TC_FRAMES &&
        "build_ffmpeg_info: first_frame_tc exceeds 24h — corrupt stream start_time?");
    assert(info.first_sample_tc <= MAX_TC_SAMPLES &&
        "build_ffmpeg_info: first_sample_tc exceeds 24h — corrupt BWF/stream start_time?");

    return info;
}

// Idempotent FFmpeg log-level init. Called from both Open and ProbeMetadata
// so either path can be the first to run in a fresh process.
static void ensure_ffmpeg_log_level_set() {
    static std::once_flag s_ffmpeg_log_init;
    std::call_once(s_ffmpeg_log_init, [] {
        av_log_set_level(AV_LOG_FATAL);
    });
}

Result<std::shared_ptr<MediaFile>> MediaFile::Open(const std::string& path) {
    // BRAW is detected by extension; its probe is metadata-only by design.
    if (impl::is_braw_file(path)) {
        auto info_result = build_braw_info(path);
        if (info_result.is_error()) return info_result.error();
        auto mf_impl = std::make_unique<MediaFileImpl>();
        mf_impl->backend = MediaFileBackend::Braw;
        return std::make_shared<MediaFile>(std::move(mf_impl), std::move(info_result.value()));
    }

    ensure_ffmpeg_log_level_set();

    auto impl = std::make_unique<MediaFileImpl>();
    // Open() uses FFmpeg defaults (5 MB probesize, 5 s analyze duration) —
    // find_stream_info runs full analysis because this path feeds a decoder.
    auto open_result = impl->fmt_ctx.open(path);
    if (open_result.is_error()) return open_result.error();

    auto info_result = build_ffmpeg_info(impl->fmt_ctx, path);
    if (info_result.is_error()) return info_result.error();

    return std::make_shared<MediaFile>(std::move(impl), std::move(info_result.value()));
}

Result<MediaFileInfo> MediaFile::ProbeMetadata(const std::string& path) {
    // BRAW probe is metadata-only via the SDK — already fast.
    if (impl::is_braw_file(path)) {
        return build_braw_info(path);
    }
    ensure_ffmpeg_log_level_set();

    // Always run find_stream_info. We validated empirically that skipping
    // it produces wrong fps for MXF (defaults 30000/1001 instead of
    // container's actual 25/1) and wrong duration for some MOV/MP4
    // (mvhd.duration vs packet-PTS estimate), both of which cascade
    // through the relink matcher's TC/extent math.
    impl::FFmpegFormatContext fmt_ctx;
    auto open_result = fmt_ctx.open(path);
    if (open_result.is_error()) return open_result.error();
    return build_ffmpeg_info(fmt_ctx, path);
}

// Dispatch ProbeMetadata calls over a worker pool. Each slot is owned
// by exactly one worker for its duration — no lock.
static void parallel_probe_dispatch(
        const std::vector<std::string>& paths,
        std::vector<Result<MediaFileInfo>>& results,
        size_t parallelism) {
    if (paths.empty()) return;
    if (parallelism == 0) {
        parallelism = std::thread::hardware_concurrency();
        if (parallelism == 0) parallelism = 4;
    }
    if (parallelism > paths.size()) parallelism = paths.size();

    std::atomic<size_t> next_idx{0};
    std::vector<std::thread> workers;
    workers.reserve(parallelism);
    for (size_t t = 0; t < parallelism; ++t) {
        workers.emplace_back([&] {
            while (true) {
                size_t i = next_idx.fetch_add(1, std::memory_order_relaxed);
                if (i >= paths.size()) break;
                results[i] = MediaFile::ProbeMetadata(paths[i]);
            }
        });
    }
    for (auto& w : workers) w.join();
}

std::vector<Result<MediaFileInfo>> MediaFile::ProbeMetadataBatch(
        const std::vector<std::string>& paths, size_t parallelism) {
    std::vector<Result<MediaFileInfo>> results;
    results.reserve(paths.size());
    // Result<T> has no default constructor; seed each slot with a
    // sentinel error that workers will overwrite.
    for (size_t i = 0; i < paths.size(); ++i) {
        results.emplace_back(Error::internal("ProbeMetadataBatch: slot not yet written"));
    }
    if (paths.empty()) return results;

    parallel_probe_dispatch(paths, results, parallelism);
    return results;
}

void MediaFile::set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc) {
    JVE_ASSERT(!m_decode_started,
        ("MediaFile::set_tc_origin_override: called after decode started on " + m_info.path).c_str());
    JVE_ASSERT(first_frame_tc >= 0,
        ("MediaFile::set_tc_origin_override: first_frame_tc must be >= 0, got "
         + std::to_string(first_frame_tc) + " on " + m_info.path).c_str());
    JVE_ASSERT(first_sample_tc >= 0,
        ("MediaFile::set_tc_origin_override: first_sample_tc must be >= 0, got "
         + std::to_string(first_sample_tc) + " on " + m_info.path).c_str());
    m_info.first_frame_tc = first_frame_tc;
    m_info.first_sample_tc = first_sample_tc;
}

void MediaFile::mark_decode_started() {
    m_decode_started = true;
}

} // namespace emp
