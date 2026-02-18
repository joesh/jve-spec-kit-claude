#pragma once

// Internal header - defines MediaFileImpl for use by Reader
// FFmpeg headers allowed here (we're in impl/)

#include "ffmpeg_context.h"

namespace emp {

// MediaFileImpl holds the FFmpeg format context
class MediaFileImpl {
public:
    impl::FFmpegFormatContext fmt_ctx;
};

} // namespace emp
