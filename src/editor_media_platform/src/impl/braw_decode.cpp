#include "braw_decode.h"
#include <algorithm>  // tolower
#include <cctype>

namespace emp {
namespace impl {

// Extension check (always compiled — no SDK dependency)
bool is_braw_file(const std::string& path) {
    if (path.size() < 5) return false;
    std::string ext = path.substr(path.size() - 5);
    for (auto& c : ext) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return ext == ".braw";
}

} // namespace impl
} // namespace emp

#ifndef EMP_HAS_BRAW

// Stub implementations when SDK is not available
namespace emp {
namespace impl {

Result<BrawClipInfo> braw_probe_clip(const std::string&) {
    return Error::unsupported("Blackmagic RAW SDK not installed");
}

BrawReaderContext::BrawReaderContext() = default;
BrawReaderContext::~BrawReaderContext() = default;
Result<void> BrawReaderContext::init(const std::string&) {
    return Error::unsupported("Blackmagic RAW SDK not installed");
}
void BrawReaderContext::set_resolution_scale(int, int) {}
Result<std::shared_ptr<Frame>> BrawReaderContext::decode_frame(uint64_t, TimeUS, std::shared_ptr<FrameBufferPool>) {
    return Error::unsupported("Blackmagic RAW SDK not installed");
}

} // namespace impl
} // namespace emp

#else // EMP_HAS_BRAW

#include "frame_impl.h"
#include <editor_media_platform/emp_frame.h>
#include <cassert>
#include <chrono>
#include <cstring>
#include <mutex>

// The BRAW SDK header defines COM interfaces + the dispatch API.
// Only this file and braw_dispatch.cpp include it.
#include "BlackmagicRawAPI.h"

#include <CoreFoundation/CoreFoundation.h>

// Log level (same pattern as ffmpeg_context.cpp)
static int braw_log_level() {
    static int level = [] {
        const char* env = getenv("EMP_LOG_LEVEL");
        return env ? atoi(env) : 0;
    }();
    return level;
}
#define BRAW_LOG_DEBUG(...) do { if (braw_log_level() >= 2) { fprintf(stderr, "[BRAW] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)
#define BRAW_LOG_WARN(...) do { if (braw_log_level() >= 1) { fprintf(stderr, "[BRAW WARN] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)

// SDK framework search path (standard install location)
static constexpr const char* BRAW_SDK_LIB_PATH =
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries";

namespace emp {
namespace impl {

// ============================================================================
// SDK factory (singleton, lazily loaded)
// ============================================================================

static IBlackmagicRawFactory* get_braw_factory() {
    static std::once_flag s_init;
    static IBlackmagicRawFactory* s_factory = nullptr;

    std::call_once(s_init, [] {
        CFStringRef lib_path = CFStringCreateWithCString(
            kCFAllocatorDefault, BRAW_SDK_LIB_PATH, kCFStringEncodingUTF8);
        s_factory = CreateBlackmagicRawFactoryInstanceFromPath(lib_path);
        CFRelease(lib_path);

        if (s_factory) {
            BRAW_LOG_DEBUG("SDK loaded from %s", BRAW_SDK_LIB_PATH);
        } else {
            BRAW_LOG_WARN("SDK not found at %s", BRAW_SDK_LIB_PATH);
        }
    });

    return s_factory;
}

// ============================================================================
// Helper: convert float fps to rational
// ============================================================================

static void float_fps_to_rational(float fps, int32_t& num, int32_t& den) {
    // Common cinema rates — snap to exact values
    struct { float f; int32_t n; int32_t d; } table[] = {
        {23.976f, 24000, 1001}, {24.0f, 24, 1},
        {25.0f, 25, 1}, {29.97f, 30000, 1001},
        {30.0f, 30, 1}, {47.952f, 48000, 1001},
        {48.0f, 48, 1}, {50.0f, 50, 1},
        {59.94f, 60000, 1001}, {60.0f, 60, 1},
        {119.88f, 120000, 1001}, {120.0f, 120, 1},
    };
    for (auto& e : table) {
        if (std::abs(fps - e.f) < 0.05f) {
            num = e.n;
            den = e.d;
            return;
        }
    }
    // Non-standard rate: approximate as integer
    num = static_cast<int32_t>(fps * 1000 + 0.5f);
    den = 1000;
}

// ============================================================================
// Probe clip metadata
// ============================================================================

Result<BrawClipInfo> braw_probe_clip(const std::string& path) {
    auto* factory = get_braw_factory();
    if (!factory) {
        return Error::unsupported("Blackmagic RAW SDK not installed");
    }

    IBlackmagicRaw* codec = nullptr;
    HRESULT hr = factory->CreateCodec(&codec);
    if (FAILED(hr) || !codec) {
        return Error::internal("BRAW: CreateCodec failed");
    }

    CFStringRef cf_path = CFStringCreateWithCString(
        kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8);

    IBlackmagicRawClip* clip = nullptr;
    hr = codec->OpenClip(cf_path, &clip);
    CFRelease(cf_path);

    if (FAILED(hr) || !clip) {
        codec->Release();
        return Error::file_not_found("BRAW: failed to open clip: " + path);
    }

    BrawClipInfo info;

    uint32_t w = 0, h = 0;
    clip->GetWidth(&w);
    clip->GetHeight(&h);
    info.width = static_cast<int>(w);
    info.height = static_cast<int>(h);

    float fps = 0;
    clip->GetFrameRate(&fps);
    float_fps_to_rational(fps, info.fps_num, info.fps_den);

    uint64_t frame_count = 0;
    clip->GetFrameCount(&frame_count);
    info.frame_count = frame_count;

    // Duration in microseconds
    if (info.fps_num > 0 && info.fps_den > 0 && frame_count > 0) {
        info.duration_us = static_cast<TimeUS>(
            frame_count * 1000000LL * info.fps_den / info.fps_num);
    }

    // Timecode for first frame
    CFStringRef tc_str = nullptr;
    if (SUCCEEDED(clip->GetTimecodeForFrame(0, &tc_str)) && tc_str) {
        char buf[64];
        if (CFStringGetCString(tc_str, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            // Parse "HH:MM:SS:FF" to frame count
            int hh = 0, mm = 0, ss = 0, ff = 0;
            if (sscanf(buf, "%d:%d:%d%*c%d", &hh, &mm, &ss, &ff) == 4) {
                double fps_d = static_cast<double>(info.fps_num) / info.fps_den;
                info.first_frame_tc = static_cast<int64_t>(
                    ((hh * 3600) + (mm * 60) + ss) * fps_d + ff);
            }
        }
        CFRelease(tc_str);
    }

    BRAW_LOG_DEBUG("probe: %dx%d @ %d/%d fps, %llu frames, tc=%lld path=%s",
        info.width, info.height, info.fps_num, info.fps_den,
        (unsigned long long)frame_count, (long long)info.first_frame_tc,
        path.c_str());

    clip->Release();
    codec->Release();

    return info;
}

// ============================================================================
// Callback handler for synchronous decode
// ============================================================================

// Captures the decoded image data. One instance per BrawReaderContext,
// reused across frames. The output target (buffer pointer + stride) is
// set before each decode and read after FlushJobs completes.
class BrawCallbackHandler : public IBlackmagicRawCallback {
public:
    // Output target — set by decode_frame before submit
    uint8_t* out_data = nullptr;
    int out_stride = 0;
    int out_w = 0;
    int out_h = 0;
    BlackmagicRawResolutionScale resolution_scale = blackmagicRawResolutionScaleFull;
    HRESULT decode_result = E_FAIL;

    void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result,
                     IBlackmagicRawFrame* frame) override {
        if (FAILED(result)) {
            decode_result = result;
            readJob->Release();
            return;
        }

        // Set output format and resolution scale BEFORE creating decode job
        frame->SetResourceFormat(blackmagicRawResourceFormatBGRAU8);
        frame->SetResolutionScale(resolution_scale);

        IBlackmagicRawJob* processJob = nullptr;
        result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &processJob);
        if (FAILED(result)) {
            decode_result = result;
            readJob->Release();
            return;
        }

        result = processJob->Submit();
        if (FAILED(result)) {
            decode_result = result;
            processJob->Release();
        }

        readJob->Release();
    }

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result,
                        IBlackmagicRawProcessedImage* image) override {
        if (FAILED(result)) {
            decode_result = result;
            job->Release();
            return;
        }

        uint32_t width = 0, height = 0, size_bytes = 0;
        void* resource = nullptr;

        image->GetWidth(&width);
        image->GetHeight(&height);
        image->GetResourceSizeBytes(&size_bytes);
        image->GetResource(&resource);

        assert(resource && "BrawCallbackHandler: GetResource returned null");
        assert(width > 0 && height > 0 && "BrawCallbackHandler: zero dimensions");

        // Copy into caller's output buffer (row by row for stride alignment).
        // The SDK outputs tightly packed BGRA8 (stride = width * 4).
        int sdk_stride = static_cast<int>(width) * 4;
        int copy_w = std::min(static_cast<int>(width), out_w);
        int copy_h = std::min(static_cast<int>(height), out_h);

        const uint8_t* src = static_cast<const uint8_t*>(resource);
        for (int y = 0; y < copy_h; y++) {
            std::memcpy(out_data + y * out_stride,
                        src + y * sdk_stride,
                        copy_w * 4);
        }

        decode_result = S_OK;
        job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) override { return E_NOTIMPL; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }  // prevent Release-based deletion
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
};

// ============================================================================
// BrawReaderContext
// ============================================================================

// Accessor macros for opaque SDK pointers stored in BrawReaderContext
#define CODEC() static_cast<IBlackmagicRaw*>(m_codec_raw)
#define CLIP()  static_cast<IBlackmagicRawClip*>(m_clip_raw)
#define CB()    static_cast<BrawCallbackHandler*>(m_callback_raw)

BrawReaderContext::BrawReaderContext() = default;

BrawReaderContext::~BrawReaderContext() {
    if (m_clip_raw) { CLIP()->Release(); m_clip_raw = nullptr; }
    if (m_codec_raw) { CODEC()->Release(); m_codec_raw = nullptr; }
    delete CB();
    m_callback_raw = nullptr;
}

Result<void> BrawReaderContext::init(const std::string& path) {
    auto* factory = get_braw_factory();
    if (!factory) {
        return Error::unsupported("Blackmagic RAW SDK not installed");
    }

    IBlackmagicRaw* codec = nullptr;
    HRESULT hr = factory->CreateCodec(&codec);
    if (FAILED(hr) || !codec) {
        return Error::internal("BRAW: CreateCodec failed");
    }
    m_codec_raw = codec;

    // Set callback handler (owned by this context, prevent COM Release-based deletion)
    auto* cb = new BrawCallbackHandler();
    m_callback_raw = cb;
    hr = codec->SetCallback(cb);
    if (FAILED(hr)) {
        return Error::internal("BRAW: SetCallback failed");
    }

    CFStringRef cf_path = CFStringCreateWithCString(
        kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8);
    IBlackmagicRawClip* clip = nullptr;
    hr = codec->OpenClip(cf_path, &clip);
    CFRelease(cf_path);

    if (FAILED(hr) || !clip) {
        return Error::file_not_found("BRAW: failed to open clip: " + path);
    }
    m_clip_raw = clip;

    uint32_t w = 0, h = 0;
    clip->GetWidth(&w);
    clip->GetHeight(&h);
    m_src_w = static_cast<int>(w);
    m_src_h = static_cast<int>(h);
    m_out_w = m_src_w;
    m_out_h = m_src_h;

    BRAW_LOG_DEBUG("Reader: opened %dx%d path=%s", m_src_w, m_src_h, path.c_str());

    return {};
}

void BrawReaderContext::set_resolution_scale(int max_w, int max_h) {
    assert(m_clip_raw && "BrawReaderContext::set_resolution_scale: not initialized");
    assert(max_w > 0 && max_h > 0 && "set_resolution_scale: dims must be > 0");

    auto* clip = CLIP();

    if (m_src_w <= max_w && m_src_h <= max_h) {
        m_out_w = m_src_w;
        m_out_h = m_src_h;
        return;
    }

    // Pick the SDK's native resolution scale level.
    float scale = std::min(static_cast<float>(max_w) / m_src_w,
                           static_cast<float>(max_h) / m_src_h);

    BlackmagicRawResolutionScale braw_scale;
    if (scale > 0.5f) {
        braw_scale = blackmagicRawResolutionScaleFull;
        m_out_w = m_src_w;
        m_out_h = m_src_h;
    } else if (scale > 0.25f) {
        braw_scale = blackmagicRawResolutionScaleHalf;
        m_out_w = m_src_w / 2;
        m_out_h = m_src_h / 2;
    } else if (scale > 0.125f) {
        braw_scale = blackmagicRawResolutionScaleQuarter;
        m_out_w = m_src_w / 4;
        m_out_h = m_src_h / 4;
    } else {
        braw_scale = blackmagicRawResolutionScaleEighth;
        m_out_w = m_src_w / 8;
        m_out_h = m_src_h / 8;
    }

    m_braw_scale = static_cast<int>(braw_scale);

    // Query available resolutions from the SDK
    IBlackmagicRawClipResolutions* resolutions = nullptr;
    HRESULT hr = clip->QueryInterface(IID_IBlackmagicRawClipResolutions,
                                       reinterpret_cast<void**>(&resolutions));
    if (SUCCEEDED(hr) && resolutions) {
        uint32_t out_w = 0, out_h = 0;
        hr = resolutions->GetResolution(braw_scale, &out_w, &out_h);
        if (SUCCEEDED(hr) && out_w > 0 && out_h > 0) {
            m_out_w = static_cast<int>(out_w);
            m_out_h = static_cast<int>(out_h);
        }
        resolutions->Release();
    }

    BRAW_LOG_DEBUG("Resolution scale: %dx%d -> %dx%d (max %dx%d)",
        m_src_w, m_src_h, m_out_w, m_out_h, max_w, max_h);
}

Result<std::shared_ptr<Frame>> BrawReaderContext::decode_frame(
        uint64_t frame_index, TimeUS pts_us, std::shared_ptr<FrameBufferPool> pool) {
    assert(m_codec_raw && m_clip_raw && "BrawReaderContext::decode_frame: not initialized");
    assert(pool && "BrawReaderContext::decode_frame: pool is null");

    auto* codec = CODEC();
    auto* clip = CLIP();
    auto* cb = CB();
    auto t0 = std::chrono::steady_clock::now();

    // Acquire output buffer from pool (malloc'd, no zero-init)
    int frame_stride = ((m_out_w * 4) + 31) & ~31;
    size_t buf_size = static_cast<size_t>(frame_stride) * m_out_h;
    auto entry = pool->acquire(buf_size);

    // Configure callback output target + resolution scale
    cb->out_data = entry.data;
    cb->out_stride = frame_stride;
    cb->out_w = m_out_w;
    cb->out_h = m_out_h;
    cb->resolution_scale = static_cast<BlackmagicRawResolutionScale>(m_braw_scale);
    cb->decode_result = E_FAIL;

    // Create and submit read job
    IBlackmagicRawJob* readJob = nullptr;
    HRESULT hr = clip->CreateJobReadFrame(frame_index, &readJob);
    if (FAILED(hr) || !readJob) {
        pool->release(entry.data, entry.size);
        return Error::internal("BRAW: CreateJobReadFrame failed for frame " +
                              std::to_string(frame_index));
    }

    hr = readJob->Submit();
    if (FAILED(hr)) {
        readJob->Release();
        pool->release(entry.data, entry.size);
        return Error::internal("BRAW: Submit failed for frame " +
                              std::to_string(frame_index));
    }

    // Block until decode + process complete
    codec->FlushJobs();

    if (FAILED(cb->decode_result)) {
        pool->release(entry.data, entry.size);
        return Error::internal("BRAW: decode failed for frame " +
                              std::to_string(frame_index));
    }

    auto t1 = std::chrono::steady_clock::now();
    m_last_decode_ms = std::chrono::duration<float, std::milli>(t1 - t0).count();

    BRAW_LOG_DEBUG("decode: frame=%llu %.1fms %dx%d",
        (unsigned long long)frame_index, m_last_decode_ms, m_out_w, m_out_h);

    // Wrap in Frame with pool release callback
    auto result_frame = std::make_shared<Frame>(std::make_unique<FrameImpl>(
        m_out_w, m_out_h, frame_stride, pts_us,
        entry.data, entry.size,
        FrameBufferPool::make_release_cb(pool)
    ));

    return result_frame;
}

#undef CODEC
#undef CLIP
#undef CB

} // namespace impl
} // namespace emp

#endif // EMP_HAS_BRAW
