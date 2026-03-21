#pragma once

#include "emp_errors.h"
#include "emp_time.h"
#include <memory>
#include <string>

namespace emp {

// Forward declaration for implementation
class MediaFileImpl;

// Information about an opened media file
struct MediaFileInfo {
    // Duration in microseconds
    TimeUS duration_us;

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

    // TC of sample 0: start timecode in audio samples.
    // From BWF time_reference (samples since midnight) or stream start_time.
    // Audio path: file_pos = source_sample_tc - first_sample_tc
    int64_t first_sample_tc = 0;

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
    int32_t audio_channels;     // Source channel count

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

    // Open a media file
    static Result<std::shared_ptr<MediaFile>> Open(const std::string& path);

    // Get file information
    const MediaFileInfo& info() const;

    // Internal: Constructor is public but MediaFileImpl is opaque, so only EMP can create MediaFiles
    explicit MediaFile(std::unique_ptr<MediaFileImpl> impl, MediaFileInfo info);

    // Internal: Access impl for Reader
    MediaFileImpl* impl_ptr() const { return m_impl.get(); }

private:
    std::unique_ptr<MediaFileImpl> m_impl;
    MediaFileInfo m_info;
};

} // namespace emp
