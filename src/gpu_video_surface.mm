#include "gpu_video_surface.h"
#include "assert_handler.h"

#ifdef __APPLE__

#include <editor_media_platform/emp_frame.h>
#include <QResizeEvent>
#include <QDebug>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/NSView.h>

struct Vertex {
    float position[2];
    float texCoord[2];
};

// Which render path the current frame uses
enum class FrameMode { None, YUV, BGRA };

class GPUVideoSurfaceImpl {
public:
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLBuffer> vertexBuffer = nil;
    CVMetalTextureCacheRef textureCache = nullptr;
    CAMetalLayer* metalLayer = nil;

    // YUV pipeline (hw-decoded VideoToolbox frames)
    id<MTLRenderPipelineState> yuvPipelineState = nil;
    CVMetalTextureRef textureY = nullptr;
    CVMetalTextureRef textureUV = nullptr;
    id<MTLTexture> metalTextureY = nil;
    id<MTLTexture> metalTextureUV = nil;

    // BGRA pipeline (sw-decoded CPU frames)
    id<MTLRenderPipelineState> bgraPipelineState = nil;
    id<MTLTexture> bgraTexture = nil;

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
        commandQueue = nil;
        device = nil;
        metalLayer = nil;
    }

    void releaseTextures() {
        if (textureY) { CFRelease(textureY); textureY = nullptr; }
        if (textureUV) { CFRelease(textureUV); textureUV = nullptr; }
        metalTextureY = nil;
        metalTextureUV = nil;
        bgraTexture = nil;
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

        // BGRA pipeline (sw-decoded CPU frames)
        MTLRenderPipelineDescriptor* bgraDesc = [MTLRenderPipelineDescriptor new];
        bgraDesc.vertexFunction = vertexFunc;
        bgraDesc.fragmentFunction = bgraFragmentFunc;
        bgraDesc.vertexDescriptor = vertexDesc;
        bgraDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        m_impl->bgraPipelineState = [m_impl->device newRenderPipelineStateWithDescriptor:bgraDesc error:&error];
        JVE_ASSERT(m_impl->bgraPipelineState, "BGRA pipeline creation failed");

        Vertex vertices[] = {
            {{-1, -1}, {0, 1}},
            {{ 1, -1}, {1, 1}},
            {{-1,  1}, {0, 0}},
            {{ 1,  1}, {1, 0}},
        };
        m_impl->vertexBuffer = [m_impl->device newBufferWithBytes:vertices
            length:sizeof(vertices) options:MTLResourceStorageModeShared];

        m_initialized = true;
        qWarning() << "GPUVideoSurface: Metal initialized";
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

    if (!m_initialized) initMetal();
    if (!m_initialized) {
        qDebug() << "GPUVideoSurface::setFrame: Metal not initialized, dropping frame";
        return;
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
        if (planeCount != 2) {
            qWarning() << "GPUVideoSurface::setFrameHW: expected 2 planes, got"
                       << planeCount << "— skipping frame";
            return;
        }

        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

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

            // 4:2:2 16-bit (video range only — no full-range variant in SDK)
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

            // 4:4:4 16-bit (video range only — no full-range variant in SDK)
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
                char fmt_str[5] = {0};
                fmt_str[0] = (pixelFormat >> 24) & 0xFF;
                fmt_str[1] = (pixelFormat >> 16) & 0xFF;
                fmt_str[2] = (pixelFormat >> 8) & 0xFF;
                fmt_str[3] = pixelFormat & 0xFF;
                qWarning() << "GPUVideoSurface::setFrameHW: unsupported pixel format"
                           << QString::fromLatin1(fmt_str)
                           << "(" << QString::number(pixelFormat, 16)
                           << ") — skipping frame";
                return;
            }
        }

        m_impl->releaseTextures();

        size_t yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

        CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
            yFormat, yWidth, yHeight, 0, &m_impl->textureY);
        if (ret != kCVReturnSuccess || !m_impl->textureY) {
            qWarning() << "GPUVideoSurface::setFrameHW: failed to create Y texture (ret="
                       << ret << ") — skipping frame";
            return;
        }

        size_t uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

        ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
            uvFormat, uvWidth, uvHeight, 1, &m_impl->textureUV);
        if (ret != kCVReturnSuccess || !m_impl->textureUV) {
            qWarning() << "GPUVideoSurface::setFrameHW: failed to create UV texture (ret="
                       << ret << ") — skipping frame";
            m_impl->releaseTextures();
            return;
        }

        m_impl->metalTextureY = CVMetalTextureGetTexture(m_impl->textureY);
        m_impl->metalTextureUV = CVMetalTextureGetTexture(m_impl->textureUV);
        m_impl->frameMode = FrameMode::YUV;

        renderTexture();
    }
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
    m_frameWidth = 0;
    m_frameHeight = 0;
    m_impl->releaseTextures();
    // Render black
    if (m_initialized) renderTexture();
}

void GPUVideoSurface::renderTexture() {
    if (!m_initialized) return;

    @autoreleasepool {
        CGFloat scale = devicePixelRatioF();
        m_impl->metalLayer.contentsScale = scale;
        m_impl->metalLayer.drawableSize = CGSizeMake(width() * scale, height() * scale);

        id<CAMetalDrawable> drawable = [m_impl->metalLayer nextDrawable];
        if (!drawable) return;

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
            } else {
                [encoder setRenderPipelineState:m_impl->bgraPipelineState];
                [encoder setFragmentTexture:m_impl->bgraTexture atIndex:0];
            }

            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }

        [encoder endEncoding];
        [cmdBuffer presentDrawable:drawable];
        [cmdBuffer commit];
    }
}

void GPUVideoSurface::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    if (m_initialized && m_impl->metalLayer) {
        CGFloat scale = devicePixelRatioF();
        m_impl->metalLayer.drawableSize = CGSizeMake(width() * scale, height() * scale);
    }
    if (m_impl->frameMode != FrameMode::None) renderTexture();
}

bool GPUVideoSurface::event(QEvent* event) {
    if (event->type() == QEvent::WinIdChange || event->type() == QEvent::Show) {
        if (!m_initialized) initMetal();
    }
    return QWidget::event(event);
}

#endif // __APPLE__
