#pragma once

#include "emp_errors.h"
#include "emp_time.h"
#include <memory>
#include <string>
#include <vector>

namespace emp {

// Forward declaration for implementation
class MediaFileImpl;

// Information about an opened media file
struct MediaFileInfo {
    // Duration in microseconds. 0 is ambiguous — it can legitimately
    // mean "this is a single-frame still image" (TIFF, single-frame
    // export) or "no duration source was found in the container."
    // Callers that need to distinguish these cases check has_duration.
    TimeUS duration_us;

    // True when duration_us came from an authoritative container
    // source (format.duration, video_stream->duration, or
    // audio_stream->duration). False means no duration source was
    // present — the stream is either a still image or the container
    // doesn't encode duration. Mirrors has_video_tc_origin /
    // has_audio_tc_origin for TC values.
    bool has_duration = false;

    // Authoritative video frame count from container metadata, when the
    // demuxer exposes it directly (BRAW SDK clip->GetFrameCount(), some
    // MOV containers via nb_frames). -1 = unknown; consumers must fall
    // back to duration_us × fps. ALWAYS prefer this when present: the
    // duration_us round-trip is lossy at non-integer fps and on some
    // codecs (e.g. BRAW 23.976) the container records audio at the
    // nominal rate, so video-duration-derived audio extents drift.
    int64_t video_frame_count = -1;

    // Authoritative audio sample count from container metadata, when
    // exposed directly (BRAW SDK audio interface). -1 = unknown;
    // consumers must fall back to duration_us × sample_rate. Same
    // rationale as video_frame_count — and especially load-bearing
    // for 23.976 BRAW where the derivation overshoots by ~1‰.
    int64_t audio_sample_count = -1;

    // Video stream info
    bool has_video;
    int video_width;
    int video_height;

    // Nominal frame rate (best-effort, may be approximate)
    // After canonical snapping
    int32_t video_fps_num;
    int32_t video_fps_den;

    // True if file appears to be VFR (variable frame rate)
    // Conservative: may be true even for CFR files
    bool is_vfr;

    // TC of frame 0: start timecode in frames at media's native rate.
    // Extracted from stream start_time (e.g., 86400 for 01:00:00:00 @ 24fps).
    // Video path: file_pos = source_frame_tc - first_frame_tc
    int64_t first_frame_tc = 0;

    // True iff first_frame_tc came from an authoritative container source
    // (MOV tmcd atom, MXF stream start_time, BRAW metadata). False means
    // no TC source was found and first_frame_tc defaulted to 0 — callers
    // matching on TC should treat this as "unknown" rather than "zero".
    bool has_video_tc_origin = false;

    // TC of sample 0: start timecode in audio samples.
    // From BWF time_reference (samples since midnight) or stream start_time.
    // Audio path: file_pos = source_sample_tc - first_sample_tc
    int64_t first_sample_tc = 0;

    // True iff first_sample_tc came from an authoritative container
    // source (BWF time_reference or audio stream start_time >= 1s).
    // False means no TC source was found and first_sample_tc defaulted
    // to 0 — same semantics as has_video_tc_origin.
    bool has_audio_tc_origin = false;

    // Every distinct TC value found in any stream's "timecode" tag or
    // the format-level "timecode" tag, in frames at video_fps_num/den.
    // first_frame_tc IS the first entry (preserved for back-compat); any
    // additional entries are distinct TCs from other tmcd tracks or
    // format metadata. Empty when no TC source was found
    // (has_video_tc_origin == false).
    //
    // Use case: Resolve-style conform allows matching against multiple
    // TC sources in one file. A file may carry both a render-time TC
    // (elapsed-time tmcd) and an original-source TC (sidecar/atom).
    // Matchers iterate this list when a single primary TC misses.
    std::vector<int64_t> all_video_tc_origins;

    // Every distinct audio TC value (samples at audio_sample_rate)
    // found via BWF time_reference, audio stream start_time >= 1s, or
    // derivation from a video TC origin. first_sample_tc IS the first
    // entry. Empty when has_audio_tc_origin == false.
    std::vector<int64_t> all_audio_tc_origins;

    // Rotation in degrees (0, 90, 180, 270) from display matrix metadata
    // Applies to phone footage recorded in portrait/landscape modes
    int rotation;

    // Pixel aspect ratio (sample aspect ratio in FFmpeg terms)
    // 1:1 = square pixels. Non-square examples: 1440x1080 anamorphic HD = 4:3
    int32_t video_par_num = 1;
    int32_t video_par_den = 1;

    // Audio stream info
    bool has_audio;
    int32_t audio_sample_rate;  // Source sample rate (e.g., 48000)

    // Flat channel count across ALL audio streams in the container.
    // For a single multichannel stream this equals that stream's
    // nb_channels. For containers like broadcast MXF that split each
    // channel into its own mono PCM stream, this is the SUM across the
    // audio streams — the abstraction JVE deals in is "channel of file",
    // not "channel of stream". Downstream (master_builder, resolver,
    // peak generator) iterates source_channel ∈ [0, audio_channels).
    int32_t audio_channels;

    // Per-stream layout backing the flat audio_channels count. Empty when
    // has_audio is false; non-empty whenever has_audio is true. Reader
    // maps a flat source_channel to (av_stream_idx, channel_within_stream)
    // by walking these mappings — flat indices
    // [flat_channel_offset, flat_channel_offset + channel_count) belong
    // to av_stream_idx, with channel_within_stream = flat - flat_channel_offset.
    struct AudioStreamMapping {
        int32_t av_stream_idx;       // Index in AVFormatContext::streams[]
        int32_t channel_count;       // nb_channels of this stream
        int32_t flat_channel_offset; // First flat source_channel covered
    };
    std::vector<AudioStreamMapping> audio_streams;

    // BWF (Broadcast Wave Format) timecode origin in audio samples since midnight.
    // From format tag "time_reference". -1 = not present (plain WAV, non-BWF).
    // Example: 172508160 at 48kHz = TC 00:59:53:23.
    int64_t bwf_time_reference = -1;

    // Original file path
    std::string path;

    // Get rate as Rate struct
    Rate video_rate() const {
        return Rate{video_fps_num, video_fps_den};
    }
};

// Media file handle (opened file)
class MediaFile {
public:
    ~MediaFile();

    // Open a media file for decoding. Reads the container header AND runs
    // avformat_find_stream_info (packet analysis to confirm codec parameters).
    // Use this if you intend to decode frames from the returned handle.
    static Result<std::shared_ptr<MediaFile>> Open(const std::string& path);

    // Probe container metadata only — faster variant of Open() for callers
    // that only need the fields on MediaFileInfo (TC origin, stream dims,
    // fps, duration). Skips avformat_find_stream_info, which typically
    // dominates Open()'s runtime on video files (5-10× speedup for MOV/MP4).
    //
    // Returns a MediaFileInfo directly — no MediaFile handle. The returned
    // info is suitable for relink matching, media browser display, and
    // import TC extraction, but NOT for starting a decode: use Open() if
    // you need to read frames.
    //
    // Thread-safe — safe to call concurrently from multiple threads on
    // distinct paths. BRAW path delegates to the SDK's metadata probe;
    // FFmpeg path creates a dedicated format context per call.
    static Result<MediaFileInfo> ProbeMetadata(const std::string& path);

    // Parallel ProbeMetadata over a batch of paths. Spawns a worker pool
    // and dispatches paths round-robin. Results come back in input order,
    // one Result per input path (each may independently be an error).
    //
    // parallelism=0 (default) uses std::thread::hardware_concurrency(),
    // clamped to the input size. Pass an explicit value to override.
    //
    // Intended consumer: relink scan, bulk media browser probes, any
    // workflow that needs metadata for hundreds of files at once.
    static std::vector<Result<MediaFileInfo>> ProbeMetadataBatch(
        const std::vector<std::string>& paths, size_t parallelism = 0);

    // Get file information
    const MediaFileInfo& info() const;

    // Override the TC origin that EMP probed from the file's container.
    // Replaces first_frame_tc and first_sample_tc in the MediaFileInfo.
    // Must be called AFTER Open and BEFORE any decode operation.
    // Asserts if decode has already begun.
    void set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc);

    // Mark that a decode operation has been performed (called by Reader).
    // After this, set_tc_origin_override will assert.
    void mark_decode_started();

    // Check if the video codec has a decoder available (no VT negotiation, no Reader).
    // Returns Ok if decodable, Error{Unsupported} if no decoder found.
    Result<void> ProbeCodec() const;

    // Cheap decoder-availability probe. Opens the container only
    // (avformat_open_input), inspects the video stream's codec_id from
    // the container header, and calls avcodec_find_decoder. Avoids
    // avformat_find_stream_info — which reads up to 5 MB and may decode
    // frames to confirm pix_fmt — so this stays O(64 KB) per file for
    // container-tagged formats (MOV/MP4/MXF/MKV/...). Falls back to
    // find_stream_info ONLY if codec_id is unknown after open (rare:
    // raw elementary streams). For audio-only files returns Ok.
    //
    // This is the codec_probe path; never use it where stream metadata
    // (duration, fps, pix_fmt) is needed — use Open / ProbeMetadata.
    static Result<void> ProbeCodecExistence(const std::string& path);

    // Internal: Constructor is public but MediaFileImpl is opaque, so only EMP can create MediaFiles
    explicit MediaFile(std::unique_ptr<MediaFileImpl> impl, MediaFileInfo info);

    // Internal: Access impl for Reader
    MediaFileImpl* impl_ptr() const { return m_impl.get(); }

private:
    std::unique_ptr<MediaFileImpl> m_impl;
    MediaFileInfo m_info;
    bool m_decode_started = false;
};

} // namespace emp
