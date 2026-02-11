#pragma once

#include "emp_errors.h"
#include "emp_time.h"
#include <memory>
#include <string>

namespace emp {

// Forward declaration for implementation
class AssetImpl;

// Information about an opened media asset
struct AssetInfo {
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

    // Start timecode in frames at media's native rate
    // Extracted from stream start_time (e.g., 86400 for 01:00:00:00 @ 24fps)
    int64_t start_tc;

    // Rotation in degrees (0, 90, 180, 270) from display matrix metadata
    // Applies to phone footage recorded in portrait/landscape modes
    int rotation;

    // Audio stream info
    bool has_audio;
    int32_t audio_sample_rate;  // Source sample rate (e.g., 48000)
    int32_t audio_channels;     // Source channel count

    // Original file path
    std::string path;

    // Get rate as Rate struct
    Rate video_rate() const {
        return Rate{video_fps_num, video_fps_den};
    }
};

// Media asset handle (opened file)
class Asset {
public:
    ~Asset();

    // Open a media file
    static Result<std::shared_ptr<Asset>> Open(const std::string& path);

    // Get asset information
    const AssetInfo& info() const;

    // Internal: Constructor is public but AssetImpl is opaque, so only EMP can create Assets
    explicit Asset(std::unique_ptr<AssetImpl> impl, AssetInfo info);

    // Internal: Access impl for Reader
    AssetImpl* impl_ptr() const { return m_impl.get(); }

private:
    std::unique_ptr<AssetImpl> m_impl;
    AssetInfo m_info;
};

} // namespace emp
