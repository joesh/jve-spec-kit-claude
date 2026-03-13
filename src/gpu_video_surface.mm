#include "gpu_video_surface.h"
#include "assert_handler.h"

#ifdef __APPLE__

#include <editor_media_platform/emp_frame.h>
#include <QResizeEvent>
#include "jve_log.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/NSView.h>
#import <mach/mach_time.h>
#include <dispatch/dispatch.h>

struct Vertex {
    float position[2];
    float texCoord[2];
};

// Which render path the current frame uses
enum class FrameMode { None, YUV, BGRA, PackedYUV };

class GPUVideoSurfaceImpl {
public:
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLBuffer> vertexBuffer = nil;
    CVMetalTextureCacheRef textureCache = nullptr;
    CAMetalLayer* metalLayer = nil;

    // YUV pipeline (hw-decoded biplanar VideoToolbox frames: NV12, P010, etc.)
    id<MTLRenderPipelineState> yuvPipelineState = nil;
    CVMetalTextureRef textureY = nullptr;
    CVMetalTextureRef textureUV = nullptr;
    id<MTLTexture> metalTextureY = nil;
    id<MTLTexture> metalTextureUV = nil;

    // BGRA pipeline (sw-decoded CPU frames or non-planar BGRA CVPixelBuffers)
    id<MTLRenderPipelineState> bgraPipelineState = nil;
    id<MTLTexture> bgraTexture = nil;

    // Packed YUV pipeline (non-planar AYUV: y416 from ProRes 4444 with alpha)
    id<MTLRenderPipelineState> packedYuvPipelineState = nil;
    id<MTLTexture> packedYuvTexture = nil;

    // CVMetalTextureRef for zero-copy non-planar HW paths (BGRA or packed YUV)
    CVMetalTextureRef textureNonPlanar = nullptr;

    // Which pipeline is active for the current frame
    FrameMode frameMode = FrameMode::None;

    ~GPUVideoSurfaceImpl() { cleanup(); }

    void cleanup() {
        releaseTextures();
        if (textureCache) {
            CFRelease(textureCache);
            textureCache = nullptr;
        }
        vertexBuffer = nil;
        yuvPipelineState = nil;
        bgraPipelineState = nil;
        packedYuvPipelineState = nil;
        commandQueue = nil;
        device = nil;
        metalLayer = nil;
    }

    void releaseTextures() {
        if (textureY) { CFRelease(textureY); textureY = nullptr; }
        if (textureUV) { CFRelease(textureUV); textureUV = nullptr; }
        if (textureNonPlanar) { CFRelease(textureNonPlanar); textureNonPlanar = nullptr; }
        metalTextureY = nil;
        metalTextureUV = nil;
        bgraTexture = nil;
        packedYuvTexture = nil;
        frameMode = FrameMode::None;
    }
};

static const char* shaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// NV12/P010 YUV to RGB conversion (BT.709 for HD content)
// Works for both 8-bit (NV12) and 10-bit (P010) - texture formats handle normalization
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texUV [[texture(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float y = texY.sample(s, in.texCoord).r;
    float2 uv = texUV.sample(s, in.texCoord).rg;

    // BT.709 YUV to RGB (video range: Y 16-235, UV 16-240)
    // For normalized textures, video range is 16/255 to 235/255
    y = (y - 0.0627) * 1.164;  // (y - 16/255) * 255/219
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;

    // BT.709 coefficients
    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    return float4(saturate(float3(r, g, b)), 1.0);
}

// BGRA passthrough for sw-decoded frames (PNG, JPEG, etc.)
// MTLPixelFormatBGRA8Unorm swizzles on read, so sampling returns RGBA directly.
fragment float4 bgraFragmentShader(VertexOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return tex.sample(s, in.texCoord);
}

// Packed 4:4:4:4 AYUV (y416 from ProRes 4444 with alpha).
// CVPixelBuffer format: A(16) Y(16) Cb(16) Cr(16) per pixel, non-planar.
// Metal RGBA16Unorm maps to: R=A, G=Y, B=Cb, A=Cr (all [0,1] normalized).
// Full-range BT.709 conversion (ProRes is full-range).
fragment float4 packedYuvFragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 ayuv = tex.sample(s, in.texCoord);

    float alpha = ayuv.r;
    float y = ayuv.g;
    float cb = ayuv.b - 0.5;
    float cr = ayuv.a - 0.5;

    // BT.709 full-range YCbCr to RGB
    float r = y + 1.5748 * cr;
    float g = y - 0.1873 * cb - 0.4681 * cr;
    float b = y + 1.8556 * cb;

    return float4(saturate(float3(r, g, b)), alpha);
}
)";

bool GPUVideoSurface::isAvailable() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil;
    }
}

GPUVideoSurface::GPUVideoSurface(QWidget* parent)
    : QWidget(parent)
    , m_impl(std::make_unique<GPUVideoSurfaceImpl>())
{
    setAttribute(Qt::WA_NativeWindow);
    setAttribute(Qt::WA_PaintOnScreen);
    setAttribute(Qt::WA_NoSystemBackground);
}

GPUVideoSurface::~GPUVideoSurface() {
    cleanupMetal();
}

void GPUVideoSurface::setReadyCallback(ReadyCallback cb) {
    m_ready_callback = std::move(cb);
    m_ready_fired = false;
    tryFireReady();
}

/// Fire ready callback once when Metal is initialized AND widget has non-zero geometry.
/// Called from initMetal, resizeEvent, and setReadyCallback.
void GPUVideoSurface::tryFireReady() {
    if (m_ready_fired) return;
    if (!m_initialized) return;
    if (!m_ready_callback) return;
    if (width() <= 0 || height() <= 0) return;
    m_ready_fired = true;
    JVE_LOG_EVENT(Video, "GPUVideoSurface: ready (Metal + geometry %dx%d)", width(), height());
    m_ready_callback();
}

void GPUVideoSurface::setErrorCallback(ErrorCallback cb) {
    m_error_callback = std::move(cb);
}

void GPUVideoSurface::initMetal() {
    if (m_initialized) return;

    @autoreleasepool {
        m_impl->device = MTLCreateSystemDefaultDevice();
        JVE_ASSERT(m_impl->device, "Metal device not available");

        m_impl->commandQueue = [m_impl->device newCommandQueue];
        JVE_ASSERT(m_impl->commandQueue, "Failed to create command queue");

        CVReturn ret = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nullptr, m_impl->device, nullptr, &m_impl->textureCache);
        JVE_ASSERT(ret == kCVReturnSuccess, "CVMetalTextureCacheCreate failed");

        NSView* view = reinterpret_cast<NSView*>(winId());
        m_impl->metalLayer = [CAMetalLayer layer];
        m_impl->metalLayer.device = m_impl->device;
        m_impl->metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        m_impl->metalLayer.framebufferOnly = YES;
        [view setLayer:m_impl->metalLayer];
        [view setWantsLayer:YES];

        NSError* error = nil;
        id<MTLLibrary> library = [m_impl->device
            newLibraryWithSource:[NSString stringWithUTF8String:shaderSource]
            options:nil error:&error];
        JVE_ASSERT(library, "Shader compile failed");

        id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertexShader"];
        id<MTLFunction> yuvFragmentFunc = [library newFunctionWithName:@"fragmentShader"];
        id<MTLFunction> bgraFragmentFunc = [library newFunctionWithName:@"bgraFragmentShader"];
        id<MTLFunction> packedYuvFragmentFunc = [library newFunctionWithName:@"packedYuvFragmentShader"];

        MTLVertexDescriptor* vertexDesc = [MTLVertexDescriptor new];
        vertexDesc.attributes[0].format = MTLVertexFormatFloat2;
        vertexDesc.attributes[0].offset = 0;
        vertexDesc.attributes[0].bufferIndex = 0;
        vertexDesc.attributes[1].format = MTLVertexFormatFloat2;
        vertexDesc.attributes[1].offset = sizeof(float) * 2;
        vertexDesc.attributes[1].bufferIndex = 0;
        vertexDesc.layouts[0].stride = sizeof(Vertex);

        // YUV pipeline (hw-decoded VideoToolbox frames)
        MTLRenderPipelineDescriptor* yuvDesc = [MTLRenderPipelineDescriptor new];
        yuvDesc.vertexFunction = vertexFunc;
        yuvDesc.fragmentFunction = yuvFragmentFunc;
        yuvDesc.vertexDescriptor = vertexDesc;
        yuvDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        m_impl->yuvPipelineState = [m_impl->device newRenderPipelineStateWithDescriptor:yuvDesc error:&error];
        JVE_ASSERT(m_impl->yuvPipelineState, "YUV pipeline creation failed");

        // BGRA pipeline (sw-decoded CPU frames or non-planar BGRA CVPixelBuffers)
        MTLRenderPipelineDescriptor* bgraDesc = [MTLRenderPipelineDescriptor new];
        bgraDesc.vertexFunction = vertexFunc;
        bgraDesc.fragmentFunction = bgraFragmentFunc;
        bgraDesc.vertexDescriptor = vertexDesc;
        bgraDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        m_impl->bgraPipelineState = [m_impl->device newRenderPipelineStateWithDescriptor:bgraDesc error:&error];
        JVE_ASSERT(m_impl->bgraPipelineState, "BGRA pipeline creation failed");

        // Packed YUV pipeline (non-planar AYUV: y416 from ProRes 4444 with alpha)
        MTLRenderPipelineDescriptor* packedYuvDesc = [MTLRenderPipelineDescriptor new];
        packedYuvDesc.vertexFunction = vertexFunc;
        packedYuvDesc.fragmentFunction = packedYuvFragmentFunc;
        packedYuvDesc.vertexDescriptor = vertexDesc;
        packedYuvDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        m_impl->packedYuvPipelineState = [m_impl->device newRenderPipelineStateWithDescriptor:packedYuvDesc error:&error];
        JVE_ASSERT(m_impl->packedYuvPipelineState, "Packed YUV pipeline creation failed");

        Vertex vertices[] = {
            {{-1, -1}, {0, 1}},
            {{ 1, -1}, {1, 1}},
            {{-1,  1}, {0, 0}},
            {{ 1,  1}, {1, 0}},
        };
        m_impl->vertexBuffer = [m_impl->device newBufferWithBytes:vertices
            length:sizeof(vertices) options:MTLResourceStorageModeShared];

        m_initialized = true;
        JVE_LOG_EVENT(Video, "GPUVideoSurface: Metal initialized");

        // Render black immediately so the surface isn't showing uninitialized
        // memory. renderTexture() guards against 0x0 size internally.
        renderTexture();

        // Fire ready callback if geometry is also available (may defer to resizeEvent).
        tryFireReady();
    }
}

void GPUVideoSurface::cleanupMetal() {
    if (m_impl) m_impl->cleanup();
    m_initialized = false;
}

void GPUVideoSurface::setRotation(int degrees) {
    // Normalize to 0/90/180/270
    degrees = ((degrees % 360) + 360) % 360;
    JVE_ASSERT(degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270,
        "GPUVideoSurface::setRotation: invalid rotation (must be 0/90/180/270)");
    if (degrees == m_rotation) return;
    m_rotation = degrees;
    if (m_initialized) {
        rebuildVertexBuffer();
        if (m_impl->frameMode != FrameMode::None) renderTexture();
    }
}

void GPUVideoSurface::setPixelAspectRatio(int num, int den) {
    JVE_ASSERT(num > 0 && den > 0,
        "GPUVideoSurface::setPixelAspectRatio: num and den must be > 0");
    if (num == m_par_num && den == m_par_den) return;
    m_par_num = num;
    m_par_den = den;
    if (m_initialized && m_impl->frameMode != FrameMode::None) {
        renderTexture();
    }
}

void GPUVideoSurface::rebuildVertexBuffer() {
    JVE_ASSERT(m_initialized, "GPUVideoSurface::rebuildVertexBuffer: Metal not initialized");

    // Texture coordinates for each rotation.
    // To rotate the displayed image N° CW, rotate tex coords N° CCW around (0.5, 0.5).
    // Vertex order: BL, BR, TL, TR (triangle strip)
    static const float texCoords[4][4][2] = {
        // 0°:   identity
        {{0,1}, {1,1}, {0,0}, {1,0}},
        // 90°:  image rotated 90° CW
        {{1,1}, {1,0}, {0,1}, {0,0}},
        // 180°: image rotated 180°
        {{1,0}, {0,0}, {1,1}, {0,1}},
        // 270°: image rotated 270° CW (= 90° CCW)
        {{0,0}, {0,1}, {1,0}, {1,1}},
    };

    int idx = m_rotation / 90;
    Vertex vertices[] = {
        {{-1, -1}, {texCoords[idx][0][0], texCoords[idx][0][1]}},
        {{ 1, -1}, {texCoords[idx][1][0], texCoords[idx][1][1]}},
        {{-1,  1}, {texCoords[idx][2][0], texCoords[idx][2][1]}},
        {{ 1,  1}, {texCoords[idx][3][0], texCoords[idx][3][1]}},
    };
    m_impl->vertexBuffer = [m_impl->device newBufferWithBytes:vertices
        length:sizeof(vertices) options:MTLResourceStorageModeShared];
}

void GPUVideoSurface::setFrame(const std::shared_ptr<emp::Frame>& frame) {
    if (!frame) {
        clearFrame();
        return;
    }

    uint64_t gen = m_generation.fetch_add(1, std::memory_order_relaxed) + 1;

    if ([NSThread isMainThread]) {
        setFrameImpl(frame);
    } else {
        GPUVideoSurface* surface = this;
        std::shared_ptr<emp::Frame> frame_copy = frame;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (surface->m_generation.load(std::memory_order_relaxed) != gen) return;
            surface->setFrameImpl(frame_copy);
        });
    }
}

void GPUVideoSurface::setFrameImpl(const std::shared_ptr<emp::Frame>& frame) {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::setFrameImpl: must be on main thread");
    JVE_ASSERT(frame, "GPUVideoSurface::setFrameImpl: null frame (use clearFrame)");

    if (!m_initialized) initMetal();
    if (!m_initialized) {
        JVE_LOG_WARN(Video, "GPUVideoSurface::setFrameImpl: Metal not initialized, dropping frame");
        if (m_error_callback) m_error_callback("Metal not initialized");
        return;
    }

    ++m_frame_count;

    // Log first frame on each surface (confirms render pipeline works)
    if (m_frame_count == 1) {
        JVE_LOG_EVENT(Video, "setFrameImpl: FIRST FRAME on surface=%p %dx%d widget=%dx%d",
                     (void*)this, frame->width(), frame->height(), width(), height());
    }

    // Sampled DETAIL log: every 30th frame
    if (m_frame_count % 30 == 0) {
        bool hw = false;
#ifdef EMP_HAS_VIDEOTOOLBOX
        hw = (frame->native_buffer() != nullptr);
#endif
        JVE_LOG_DETAIL(Video, "setFrame: count=%lld mode=%s %dx%d",
                      (long long)m_frame_count, hw ? "HW" : "SW",
                      frame->width(), frame->height());
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    void* hw_buffer = frame->native_buffer();
    if (hw_buffer) {
        setFrameHW(hw_buffer, frame->width(), frame->height());
    } else {
        setFrameSW(frame->data(), frame->width(), frame->height(), frame->stride_bytes());
    }
#else
    setFrameSW(frame->data(), frame->width(), frame->height(), frame->stride_bytes());
#endif
}

#ifdef EMP_HAS_VIDEOTOOLBOX
void GPUVideoSurface::setFrameHW(void* hw_buffer, int w, int h) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)hw_buffer;
    m_frameWidth = w;
    m_frameHeight = h;

    @autoreleasepool {
        size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

        m_impl->releaseTextures();

        if (planeCount == 0) {
            // Non-planar CVPixelBuffer: route by pixel format.
            if (pixelFormat == kCVPixelFormatType_32BGRA) {
                setFrameHW_BGRA(pixelBuffer, pixelFormat);
            } else {
                // Packed YUV (y416 from ProRes 4444 w/ alpha, etc.)
                setFrameHW_PackedYUV(pixelBuffer, pixelFormat);
            }
        } else if (planeCount >= 2) {
            // Biplanar YUV (NV12, P010, P210, 4:2:2, 4:4:4)
            setFrameHW_YUV(pixelBuffer, pixelFormat);
        } else {
            char msg[128];
            snprintf(msg, sizeof(msg), "unexpected plane count %zu (format 0x%x)",
                     planeCount, pixelFormat);
            JVE_ASSERT(false, msg);
        }
    }
}

void GPUVideoSurface::setFrameHW_BGRA(void* hw_buffer, uint32_t /*pixelFormat*/) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)hw_buffer;
    size_t texW = CVPixelBufferGetWidth(pixelBuffer);
    size_t texH = CVPixelBufferGetHeight(pixelBuffer);

    CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
        MTLPixelFormatBGRA8Unorm, texW, texH, 0, &m_impl->textureNonPlanar);

    if (ret != kCVReturnSuccess || !m_impl->textureNonPlanar) {
        char msg[128];
        snprintf(msg, sizeof(msg), "failed to create BGRA texture (ret=%d)", ret);
        JVE_LOG_WARN(Video, "GPUVideoSurface::setFrameHW_BGRA: %s", msg);
        if (m_error_callback) m_error_callback(msg);
        return;
    }

    m_impl->bgraTexture = CVMetalTextureGetTexture(m_impl->textureNonPlanar);
    JVE_ASSERT(m_impl->bgraTexture, "GPUVideoSurface::setFrameHW_BGRA: CVMetalTextureGetTexture returned nil");
    m_impl->frameMode = FrameMode::BGRA;
    renderTexture();
}

void GPUVideoSurface::setFrameHW_PackedYUV(void* hw_buffer, uint32_t pixelFormat) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)hw_buffer;
    size_t texW = CVPixelBufferGetWidth(pixelBuffer);
    size_t texH = CVPixelBufferGetHeight(pixelBuffer);

    // Map non-planar packed YUV format to Metal texture format.
    // y416 (kCVPixelFormatType_4444AYpCbCr16): 64 bpp → RGBA16Unorm
    MTLPixelFormat mtlFormat;
    switch (pixelFormat) {
        case kCVPixelFormatType_4444AYpCbCr16:  // 'y416'
            mtlFormat = MTLPixelFormatRGBA16Unorm;
            break;
        default: {
            char fourcc[5] = {
                static_cast<char>((pixelFormat >> 24) & 0xFF),
                static_cast<char>((pixelFormat >> 16) & 0xFF),
                static_cast<char>((pixelFormat >> 8) & 0xFF),
                static_cast<char>(pixelFormat & 0xFF), '\0'
            };
            char msg[128];
            snprintf(msg, sizeof(msg),
                "setFrameHW_PackedYUV: unsupported format '%s' (0x%x)", fourcc, pixelFormat);
            JVE_ASSERT(false, msg);
        }
    }

    CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
        mtlFormat, texW, texH, 0, &m_impl->textureNonPlanar);

    if (ret != kCVReturnSuccess || !m_impl->textureNonPlanar) {
        char msg[128];
        snprintf(msg, sizeof(msg), "failed to create packed YUV texture (ret=%d)", ret);
        JVE_LOG_WARN(Video, "GPUVideoSurface::setFrameHW_PackedYUV: %s", msg);
        if (m_error_callback) m_error_callback(msg);
        return;
    }

    m_impl->packedYuvTexture = CVMetalTextureGetTexture(m_impl->textureNonPlanar);
    JVE_ASSERT(m_impl->packedYuvTexture, "GPUVideoSurface::setFrameHW_PackedYUV: CVMetalTextureGetTexture returned nil");
    m_impl->frameMode = FrameMode::PackedYUV;
    renderTexture();
}

void GPUVideoSurface::setFrameHW_YUV(void* hw_buffer, uint32_t pixelFormat) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)hw_buffer;
    MTLPixelFormat yFormat = MTLPixelFormatR8Unorm;
    MTLPixelFormat uvFormat = MTLPixelFormatRG8Unorm;
    switch (pixelFormat) {
        // 4:2:0 8-bit
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            yFormat = MTLPixelFormatR8Unorm;
            uvFormat = MTLPixelFormatRG8Unorm;
            break;

        // 4:2:0 10-bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            yFormat = MTLPixelFormatR16Unorm;
            uvFormat = MTLPixelFormatRG16Unorm;
            break;

        // 4:2:2 10-bit
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            yFormat = MTLPixelFormatR16Unorm;
            uvFormat = MTLPixelFormatRG16Unorm;
            break;

        // 4:2:2 8-bit
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            yFormat = MTLPixelFormatR8Unorm;
            uvFormat = MTLPixelFormatRG8Unorm;
            break;

        // 4:2:2 16-bit (video range only)
        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
            yFormat = MTLPixelFormatR16Unorm;
            uvFormat = MTLPixelFormatRG16Unorm;
            break;

        // 4:4:4 10-bit (ProRes 4444, etc.)
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            yFormat = MTLPixelFormatR16Unorm;
            uvFormat = MTLPixelFormatRG16Unorm;
            break;

        // 4:4:4 16-bit (video range only)
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            yFormat = MTLPixelFormatR16Unorm;
            uvFormat = MTLPixelFormatRG16Unorm;
            break;

        // 4:4:4 8-bit
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            yFormat = MTLPixelFormatR8Unorm;
            uvFormat = MTLPixelFormatRG8Unorm;
            break;

        default: {
            char fourcc[5] = {
                static_cast<char>((pixelFormat >> 24) & 0xFF),
                static_cast<char>((pixelFormat >> 16) & 0xFF),
                static_cast<char>((pixelFormat >> 8) & 0xFF),
                static_cast<char>(pixelFormat & 0xFF), '\0'
            };
            char msg[128];
            snprintf(msg, sizeof(msg),
                "setFrameHW_YUV: unsupported biplanar format '%s' (0x%x)", fourcc, pixelFormat);
            JVE_ASSERT(false, msg);
        }
    }

    size_t yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

    CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
        yFormat, yWidth, yHeight, 0, &m_impl->textureY);
    if (ret != kCVReturnSuccess || !m_impl->textureY) {
        char msg[128];
        snprintf(msg, sizeof(msg), "failed to create Y texture (ret=%d)", ret);
        JVE_LOG_WARN(Video, "GPUVideoSurface::setFrameHW_YUV: %s", msg);
        if (m_error_callback) m_error_callback(msg);
        return;
    }

    size_t uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
    size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

    ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
        uvFormat, uvWidth, uvHeight, 1, &m_impl->textureUV);
    if (ret != kCVReturnSuccess || !m_impl->textureUV) {
        char msg[128];
        snprintf(msg, sizeof(msg), "failed to create UV texture (ret=%d)", ret);
        JVE_LOG_WARN(Video, "GPUVideoSurface::setFrameHW_YUV: %s", msg);
        m_impl->releaseTextures();
        if (m_error_callback) m_error_callback(msg);
        return;
    }

    m_impl->metalTextureY = CVMetalTextureGetTexture(m_impl->textureY);
    JVE_ASSERT(m_impl->metalTextureY, "GPUVideoSurface::setFrameHW_YUV: CVMetalTextureGetTexture(Y) returned nil");
    m_impl->metalTextureUV = CVMetalTextureGetTexture(m_impl->textureUV);
    JVE_ASSERT(m_impl->metalTextureUV, "GPUVideoSurface::setFrameHW_YUV: CVMetalTextureGetTexture(UV) returned nil");
    m_impl->frameMode = FrameMode::YUV;

    renderTexture();
}
#endif

void GPUVideoSurface::setFrameSW(const uint8_t* data, int w, int h, int stride) {
    JVE_ASSERT(data, "GPUVideoSurface::setFrameSW: null data pointer");
    JVE_ASSERT(w > 0 && h > 0, "GPUVideoSurface::setFrameSW: invalid dimensions");

    m_frameWidth = w;
    m_frameHeight = h;

    @autoreleasepool {
        m_impl->releaseTextures();

        // Create (or reuse) a BGRA Metal texture and upload CPU data
        MTLTextureDescriptor* desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;

        m_impl->bgraTexture = [m_impl->device newTextureWithDescriptor:desc];
        JVE_ASSERT(m_impl->bgraTexture, "GPUVideoSurface::setFrameSW: failed to create BGRA texture");

        [m_impl->bgraTexture replaceRegion:MTLRegionMake2D(0, 0, w, h)
            mipmapLevel:0
            withBytes:data
            bytesPerRow:stride];

        m_impl->frameMode = FrameMode::BGRA;

        renderTexture();
    }
}

void GPUVideoSurface::clearFrame() {
    uint64_t gen = m_generation.fetch_add(1, std::memory_order_relaxed) + 1;

    if ([NSThread isMainThread]) {
        clearFrameImpl();
    } else {
        GPUVideoSurface* surface = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (surface->m_generation.load(std::memory_order_relaxed) != gen) return;
            surface->clearFrameImpl();
        });
    }
}

void GPUVideoSurface::clearFrameImpl() {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::clearFrameImpl: must be on main thread");
    m_frameWidth = 0;
    m_frameHeight = 0;
    m_impl->releaseTextures();
    // Render black
    if (m_initialized) renderTexture();
}

void GPUVideoSurface::renderTexture() {
    if (!m_initialized) return;
    // Guard against 0x0 drawable size (widget not yet laid out by window manager).
    // CAMetalLayer rejects setDrawableSize with 0 — just skip until resize arrives.
    if (width() <= 0 || height() <= 0) {
        JVE_LOG_WARN(Video, "renderTexture: DROPPED — widget size %dx%d (not yet laid out)",
                    width(), height());
        return;
    }

    @autoreleasepool {
        uint64_t t0 = mach_absolute_time();

        CGFloat scale = devicePixelRatioF();
        CGSize newSize = CGSizeMake(width() * scale, height() * scale);
        CGSize curSize = m_impl->metalLayer.drawableSize;
        // Only set drawableSize when it actually changes.
        // Apple docs: "Changing the drawable size invalidates the current
        // content and causes a new set of drawables to be created."
        // Redundant sets on every render would invalidate the drawable pool.
        if (newSize.width != curSize.width || newSize.height != curSize.height) {
            m_impl->metalLayer.contentsScale = scale;
            m_impl->metalLayer.drawableSize = newSize;
        }

        uint64_t t1 = mach_absolute_time();
        id<CAMetalDrawable> drawable = [m_impl->metalLayer nextDrawable];
        uint64_t t2 = mach_absolute_time();
        if (!drawable) {
            // Metal drawable pool exhausted (triple-buffered). Transient during
            // playback (next frame retries), but during seek this means the user
            // sees stale content until the next render.
            JVE_LOG_WARN(Video, "renderTexture: no drawable (pool exhausted) surface=%p count=%lld",
                        (void*)this, (long long)m_frame_count);
            return;
        }

        MTLRenderPassDescriptor* passDesc = [MTLRenderPassDescriptor new];
        passDesc.colorAttachments[0].texture = drawable.texture;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        id<MTLCommandBuffer> cmdBuffer = [m_impl->commandQueue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [cmdBuffer renderCommandEncoderWithDescriptor:passDesc];

        if (m_impl->frameMode != FrameMode::None && m_frameWidth > 0 && m_frameHeight > 0) {
            // Letterbox viewport - swap dimensions for 90°/270° rotation
            float widget_w = width() * scale;
            float widget_h = height() * scale;
            bool rotated = (m_rotation == 90 || m_rotation == 270);
            float eff_w = rotated ? (float)m_frameHeight : (float)m_frameWidth;
            float eff_h = rotated ? (float)m_frameWidth : (float)m_frameHeight;
            // Apply pixel aspect ratio to get display aspect ratio
            float frame_aspect = (eff_w * m_par_num) / (eff_h * m_par_den);
            float widget_aspect = widget_w / widget_h;

            CGRect viewport;
            if (frame_aspect > widget_aspect) {
                float h = widget_w / frame_aspect;
                viewport = CGRectMake(0, (widget_h - h) / 2, widget_w, h);
            } else {
                float w = widget_h * frame_aspect;
                viewport = CGRectMake((widget_w - w) / 2, 0, w, widget_h);
            }

            [encoder setViewport:(MTLViewport){viewport.origin.x, viewport.origin.y,
                                               viewport.size.width, viewport.size.height, 0.0, 1.0}];
            [encoder setVertexBuffer:m_impl->vertexBuffer offset:0 atIndex:0];

            if (m_impl->frameMode == FrameMode::YUV) {
                [encoder setRenderPipelineState:m_impl->yuvPipelineState];
                [encoder setFragmentTexture:m_impl->metalTextureY atIndex:0];
                [encoder setFragmentTexture:m_impl->metalTextureUV atIndex:1];
            } else if (m_impl->frameMode == FrameMode::PackedYUV) {
                [encoder setRenderPipelineState:m_impl->packedYuvPipelineState];
                [encoder setFragmentTexture:m_impl->packedYuvTexture atIndex:0];
            } else {
                [encoder setRenderPipelineState:m_impl->bgraPipelineState];
                [encoder setFragmentTexture:m_impl->bgraTexture atIndex:0];
            }

            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }

        [encoder endEncoding];
        [cmdBuffer presentDrawable:drawable];
        [cmdBuffer commit];

        uint64_t t3 = mach_absolute_time();
        // Convert to ms using mach_timebase_info
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        auto toMs = [&](uint64_t delta) -> double {
            return (double)(delta * info.numer / info.denom) / 1e6;
        };
        double setup_ms = toMs(t1 - t0);
        double drawable_ms = toMs(t2 - t1);
        double render_ms = toMs(t3 - t2);
        double total_ms = toMs(t3 - t0);
        if (total_ms > 4.0 || m_frame_count % 60 == 0) {
            JVE_LOG_DETAIL(Video, "renderTexture: total=%.1fms (setup=%.1f drawable=%.1f render=%.1f) count=%lld",
                          total_ms, setup_ms, drawable_ms, render_ms, (long long)m_frame_count);
        }
    }
}

void GPUVideoSurface::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    // renderTexture() handles drawableSize update and guards against 0x0.
    if (m_initialized) renderTexture();
    // Metal may have initialized before geometry was available — check now.
    tryFireReady();
}

bool GPUVideoSurface::event(QEvent* event) {
    if (event->type() == QEvent::WinIdChange || event->type() == QEvent::Show) {
        if (!m_initialized) initMetal();
    }
    return QWidget::event(event);
}

#endif // __APPLE__
