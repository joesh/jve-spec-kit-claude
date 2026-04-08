#pragma once

// Internal header - defines MediaFileImpl for use by Reader
// FFmpeg headers allowed here (we're in impl/)

#include "ffmpeg_context.h"

namespace emp {

// Which backend opened this media file
enum class MediaFileBackend { FFmpeg, Braw };

// MediaFileImpl holds the FFmpeg format context (or nothing for BRAW)
class MediaFileImpl {
public:
    impl::FFmpegFormatContext fmt_ctx;
    MediaFileBackend backend = MediaFileBackend::FFmpeg;
};

} // namespace emp
