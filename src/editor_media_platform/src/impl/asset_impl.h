#pragma once

// Internal header - defines AssetImpl for use by Reader
// FFmpeg headers allowed here (we're in impl/)

#include "ffmpeg_context.h"

namespace emp {

// AssetImpl holds the FFmpeg format context
class AssetImpl {
public:
    impl::FFmpegFormatContext fmt_ctx;
};

} // namespace emp
