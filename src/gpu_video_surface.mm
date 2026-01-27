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

class GPUVideoSurfaceImpl {
public:
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLRenderPipelineState> pipelineState = nil;
    id<MTLBuffer> vertexBuffer = nil;
    CVMetalTextureCacheRef textureCache = nullptr;
    CAMetalLayer* metalLayer = nil;

    // NV12 bi-planar textures (Y plane + UV plane)
    CVMetalTextureRef textureY = nullptr;
    CVMetalTextureRef textureUV = nullptr;
    id<MTLTexture> metalTextureY = nil;
    id<MTLTexture> metalTextureUV = nil;

    ~GPUVideoSurfaceImpl() { cleanup(); }

    void cleanup() {
        releaseTextures();
        if (textureCache) {
            CFRelease(textureCache);
            textureCache = nullptr;
        }
        vertexBuffer = nil;
        pipelineState = nil;
        commandQueue = nil;
        device = nil;
        metalLayer = nil;
    }

    void releaseTextures() {
        if (textureY) { CFRelease(textureY); textureY = nullptr; }
        if (textureUV) { CFRelease(textureUV); textureUV = nullptr; }
        metalTextureY = nil;
        metalTextureUV = nil;
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

// NV12 YUV to RGB conversion (BT.709 for HD content)
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texUV [[texture(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float y = texY.sample(s, in.texCoord).r;
    float2 uv = texUV.sample(s, in.texCoord).rg;

    // BT.709 YUV to RGB (video range 16-235)
    y = (y - 0.0625) * 1.164;
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;

    float r = y + 1.793 * v;
    float g = y - 0.213 * u - 0.533 * v;
    float b = y + 2.112 * u;

    return float4(saturate(float3(r, g, b)), 1.0);
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
        id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragmentShader"];

        MTLVertexDescriptor* vertexDesc = [MTLVertexDescriptor new];
        vertexDesc.attributes[0].format = MTLVertexFormatFloat2;
        vertexDesc.attributes[0].offset = 0;
        vertexDesc.attributes[0].bufferIndex = 0;
        vertexDesc.attributes[1].format = MTLVertexFormatFloat2;
        vertexDesc.attributes[1].offset = sizeof(float) * 2;
        vertexDesc.attributes[1].bufferIndex = 0;
        vertexDesc.layouts[0].stride = sizeof(Vertex);

        MTLRenderPipelineDescriptor* pipelineDesc = [MTLRenderPipelineDescriptor new];
        pipelineDesc.vertexFunction = vertexFunc;
        pipelineDesc.fragmentFunction = fragmentFunc;
        pipelineDesc.vertexDescriptor = vertexDesc;
        pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        m_impl->pipelineState = [m_impl->device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
        JVE_ASSERT(m_impl->pipelineState, "Pipeline creation failed");

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

void GPUVideoSurface::setFrame(const std::shared_ptr<emp::Frame>& frame) {
    if (!frame) {
        clearFrame();
        return;
    }

    JVE_ASSERT(m_initialized, "Metal not initialized");

#ifdef EMP_HAS_VIDEOTOOLBOX
    void* hw_buffer = frame->native_buffer();
    JVE_ASSERT(hw_buffer, "Frame has no hw_buffer - use CPUVideoSurface for sw-decoded frames");

    m_frameWidth = frame->width();
    m_frameHeight = frame->height();

    @autoreleasepool {
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)hw_buffer;

        // Verify bi-planar format (NV12: 420v or 420f)
        size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
        JVE_ASSERT(planeCount == 2, "Expected bi-planar NV12 format from VideoToolbox");

        m_impl->releaseTextures();

        // Y plane (full resolution, R8)
        size_t yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

        CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
            MTLPixelFormatR8Unorm, yWidth, yHeight, 0, &m_impl->textureY);
        JVE_ASSERT(ret == kCVReturnSuccess && m_impl->textureY, "Failed to create Y texture");

        // UV plane (half resolution, RG8)
        size_t uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        size_t uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

        ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, m_impl->textureCache, pixelBuffer, nullptr,
            MTLPixelFormatRG8Unorm, uvWidth, uvHeight, 1, &m_impl->textureUV);
        JVE_ASSERT(ret == kCVReturnSuccess && m_impl->textureUV, "Failed to create UV texture");

        m_impl->metalTextureY = CVMetalTextureGetTexture(m_impl->textureY);
        m_impl->metalTextureUV = CVMetalTextureGetTexture(m_impl->textureUV);

        renderTexture();
    }
#else
    JVE_FAIL("EMP_HAS_VIDEOTOOLBOX not defined");
#endif
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

        if (m_impl->metalTextureY && m_impl->metalTextureUV && m_frameWidth > 0 && m_frameHeight > 0) {
            // Letterbox viewport
            float widget_w = width() * scale;
            float widget_h = height() * scale;
            float frame_aspect = (float)m_frameWidth / m_frameHeight;
            float widget_aspect = widget_w / widget_h;

            CGRect viewport;
            if (frame_aspect > widget_aspect) {
                float h = widget_w / frame_aspect;
                viewport = CGRectMake(0, (widget_h - h) / 2, widget_w, h);
            } else {
                float w = widget_h * frame_aspect;
                viewport = CGRectMake((widget_w - w) / 2, 0, w, widget_h);
            }

            [encoder setRenderPipelineState:m_impl->pipelineState];
            [encoder setViewport:(MTLViewport){viewport.origin.x, viewport.origin.y,
                                               viewport.size.width, viewport.size.height, 0.0, 1.0}];
            [encoder setVertexBuffer:m_impl->vertexBuffer offset:0 atIndex:0];
            [encoder setFragmentTexture:m_impl->metalTextureY atIndex:0];
            [encoder setFragmentTexture:m_impl->metalTextureUV atIndex:1];
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
    if (m_impl->metalTextureY) renderTexture();
}

bool GPUVideoSurface::event(QEvent* event) {
    if (event->type() == QEvent::WinIdChange || event->type() == QEvent::Show) {
        if (!m_initialized) initMetal();
    }
    return QWidget::event(event);
}

#endif // __APPLE__
