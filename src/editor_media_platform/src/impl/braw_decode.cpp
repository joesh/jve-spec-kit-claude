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

bool braw_sdk_available() { return false; }

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
Result<int64_t> BrawReaderContext::read_audio_f32(int64_t, int64_t, std::vector<float>&) {
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

bool braw_sdk_available() {
    return get_braw_factory() != nullptr;
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
// Audio interface query — shared by probe + reader-init
// ============================================================================

// Packed audio properties extracted from an IBlackmagicRawClipAudio.
struct BrawAudioProps {
    int32_t sample_rate = 0;
    int32_t channels = 0;
    int32_t bit_depth = 0;
    int64_t sample_count = 0;
};

// Query `clip` for its audio interface and, when available, read the
// PCM-LE audio properties. Returns a non-null IBlackmagicRawClipAudio*
// with `out_props` populated on success; returns nullptr when the clip has
// no audio track or when the SDK reports a format we don't support (e.g.
// a future non-PCM codec — logged, not asserted, so probe doesn't refuse
// the clip outright). Caller owns the returned interface via Release().
static IBlackmagicRawClipAudio* query_braw_audio(IBlackmagicRawClip* clip,
                                                   BrawAudioProps& out_props) {
    IBlackmagicRawClipAudio* audio = nullptr;
    HRESULT hr = clip->QueryInterface(IID_IBlackmagicRawClipAudio,
                                       reinterpret_cast<void**>(&audio));
    if (FAILED(hr) || !audio) return nullptr;  // clip has no audio track

    uint32_t sr = 0, ch = 0, bd = 0;
    uint64_t sc = 0;
    BlackmagicRawAudioFormat fmt = 0;
    audio->GetAudioSampleRate(&sr);
    audio->GetAudioChannelCount(&ch);
    audio->GetAudioBitDepth(&bd);
    audio->GetAudioSampleCount(&sc);
    audio->GetAudioFormat(&fmt);

    // PCM little-endian is the only audio format the SDK documents. Guard
    // against future format additions we haven't validated against.
    const bool is_supported = (fmt == blackmagicRawAudioFormatPCMLittleEndian)
        && sr > 0 && ch > 0 && bd > 0 && sc > 0;
    if (!is_supported) {
        BRAW_LOG_WARN("unsupported audio — fmt=0x%x sr=%u ch=%u bd=%u sc=%llu",
            fmt, sr, ch, bd, (unsigned long long)sc);
        audio->Release();
        return nullptr;
    }

    out_props.sample_rate = static_cast<int32_t>(sr);
    out_props.channels = static_cast<int32_t>(ch);
    out_props.bit_depth = static_cast<int32_t>(bd);
    out_props.sample_count = static_cast<int64_t>(sc);
    return audio;
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

    // Audio track properties. Probe doesn't need to retain the interface —
    // it only copies the numbers into info.
    BrawAudioProps audio_props;
    if (auto* audio = query_braw_audio(clip, audio_props)) {
        info.has_audio = true;
        info.audio_sample_rate = audio_props.sample_rate;
        info.audio_channels = audio_props.channels;
        info.audio_bit_depth = audio_props.bit_depth;
        info.audio_sample_count = audio_props.sample_count;
        audio->Release();
    }

    BRAW_LOG_DEBUG("probe: %dx%d @ %d/%d fps, %llu frames, tc=%lld audio=%s(%dch %dHz %dbit %lld samples) path=%s",
        info.width, info.height, info.fps_num, info.fps_den,
        (unsigned long long)frame_count, (long long)info.first_frame_tc,
        info.has_audio ? "yes" : "no",
        info.audio_channels, info.audio_sample_rate, info.audio_bit_depth,
        (long long)info.audio_sample_count,
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
#define AUDIO() static_cast<IBlackmagicRawClipAudio*>(m_audio_raw)

BrawReaderContext::BrawReaderContext() = default;

BrawReaderContext::~BrawReaderContext() {
    if (m_audio_raw) { AUDIO()->Release(); m_audio_raw = nullptr; }
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

    // Audio interface — retained on the context (unlike probe) because
    // decode_audio_f32 calls GetAudioSamples on it repeatedly.
    BrawAudioProps audio_props;
    if (auto* audio = query_braw_audio(clip, audio_props)) {
        m_audio_raw = audio;
        m_audio_sample_rate = audio_props.sample_rate;
        m_audio_channels = audio_props.channels;
        m_audio_bit_depth = audio_props.bit_depth;
        m_audio_sample_count = audio_props.sample_count;
    }

    BRAW_LOG_DEBUG("Reader: opened %dx%d audio=%s path=%s",
        m_src_w, m_src_h, m_audio_raw ? "yes" : "no", path.c_str());

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

// ============================================================================
// Audio read — synchronous PCM extraction via SDK GetAudioSamples
// ============================================================================

// Convert one native-bit-depth PCM sample frame (interleaved over `channels`)
// to float32 in [-1, 1]. Supported bit depths: 16, 24, 32 (signed PCM LE).
static void convert_pcm_le_to_f32(const uint8_t* src, float* dst,
                                   int64_t sample_frames, int channels,
                                   int bit_depth) {
    const int64_t count = sample_frames * channels;
    if (bit_depth == 16) {
        constexpr float inv = 1.0f / 32768.0f;
        const int16_t* s = reinterpret_cast<const int16_t*>(src);
        for (int64_t i = 0; i < count; i++) {
            dst[i] = static_cast<float>(s[i]) * inv;
        }
    } else if (bit_depth == 24) {
        // 24-bit signed little-endian, tightly packed (3 bytes per sample).
        constexpr float inv = 1.0f / 8388608.0f;  // 2^23
        for (int64_t i = 0; i < count; i++) {
            int32_t v = static_cast<int32_t>(src[i*3])
                      | (static_cast<int32_t>(src[i*3 + 1]) << 8)
                      | (static_cast<int32_t>(src[i*3 + 2]) << 16);
            // Sign-extend 24-bit → 32-bit
            if (v & 0x800000) v |= 0xFF000000;
            dst[i] = static_cast<float>(v) * inv;
        }
    } else if (bit_depth == 32) {
        constexpr float inv = 1.0f / 2147483648.0f;  // 2^31
        const int32_t* s = reinterpret_cast<const int32_t*>(src);
        for (int64_t i = 0; i < count; i++) {
            dst[i] = static_cast<float>(s[i]) * inv;
        }
    } else {
        // Should have been rejected at probe/init — fail loud if it slips through.
        assert(false && "BRAW: unsupported audio bit depth");
    }
}

Result<int64_t> BrawReaderContext::read_audio_f32(int64_t sample_start,
                                                   int64_t sample_count,
                                                   std::vector<float>& out_f32) {
    assert(m_audio_raw && "BrawReaderContext::read_audio_f32: no audio track");
    assert(sample_start >= 0 && "BrawReaderContext::read_audio_f32: negative start");
    assert(sample_count > 0 && "BrawReaderContext::read_audio_f32: count must be > 0");
    assert(m_audio_bit_depth == 16 || m_audio_bit_depth == 24 || m_audio_bit_depth == 32);

    auto* audio = AUDIO();

    // Clamp to available sample count.
    int64_t avail = m_audio_sample_count - sample_start;
    if (avail <= 0) {
        out_f32.clear();
        return int64_t{0};
    }
    int64_t want = std::min(sample_count, avail);

    const int bytes_per_frame = (m_audio_bit_depth / 8) * m_audio_channels;
    const uint32_t buf_bytes = static_cast<uint32_t>(want * bytes_per_frame);
    std::vector<uint8_t> native_buf(buf_bytes);

    // bytes_read is optional per the SDK header — we derive payload size
    // from samples_read * bytes_per_frame, so pass nullptr to skip it.
    uint32_t samples_read = 0;
    HRESULT hr = audio->GetAudioSamples(
        sample_start,
        native_buf.data(),
        buf_bytes,
        static_cast<uint32_t>(want),
        &samples_read,
        nullptr);

    if (FAILED(hr)) {
        return Error::internal("BRAW: GetAudioSamples failed at sample "
                              + std::to_string(sample_start));
    }

    // `want` is already clamped to `avail`, so the SDK should deliver
    // exactly `want` sample-frames on success. A short read past that
    // clamp means the SDK failed in a way its HRESULT didn't report —
    // surface it rather than propagate a truncated chunk up the peak-gen
    // pipeline (see todo_peak_gen_mid_stream_eof.md).
    if (static_cast<int64_t>(samples_read) != want) {
        return Error::internal(
            "BRAW: GetAudioSamples short read — requested "
            + std::to_string(want) + " frames at sample "
            + std::to_string(sample_start) + ", got "
            + std::to_string(samples_read));
    }

    out_f32.resize(static_cast<size_t>(samples_read) * m_audio_channels);
    convert_pcm_le_to_f32(native_buf.data(), out_f32.data(),
                          samples_read, m_audio_channels, m_audio_bit_depth);

    return static_cast<int64_t>(samples_read);
}

#undef CODEC
#undef CLIP
#undef CB
#undef AUDIO

} // namespace impl
} // namespace emp

#endif // EMP_HAS_BRAW
