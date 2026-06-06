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

// The Metal shader's CdlUniform (defined in the shader source string below)
// must agree byte-for-byte with emp::CdlParams — setFragmentBytes uploads
// the C++ struct directly into the shader's uniform slot, no marshaling.
// Pin the size + member offsets on the C++ side so a field reorder in
// emp_cdl.h fails the build instead of silently scrambling the shader read.
// 3+3+3 = 9 floats SOP + 1 float saturation + 1 int32 enabled = 11 × 4 bytes.
static_assert(sizeof(emp::CdlParams) == 11 * sizeof(float),
              "CdlParams size drift breaks Metal shader CdlUniform layout");
static_assert(offsetof(emp::CdlParams, slope)      == 0,
              "CdlParams.slope offset drift");
static_assert(offsetof(emp::CdlParams, offset)     == 3 * sizeof(float),
              "CdlParams.offset offset drift");
static_assert(offsetof(emp::CdlParams, power)      == 6 * sizeof(float),
              "CdlParams.power offset drift");
static_assert(offsetof(emp::CdlParams, saturation) == 9 * sizeof(float),
              "CdlParams.saturation offset drift");
static_assert(offsetof(emp::CdlParams, enabled)    == 10 * sizeof(float),
              "CdlParams.enabled offset drift");

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

    // LUT3D color stage (spec 023 Piece 3). 3D RGBA16F texture sampled
    // with a linear sampler in the fragment shader; HW trilinear matches
    // emp::apply_lut3d_rgb. lut3dSize is the grid edge length (33 for
    // Resolve's 33PTCUBE bakes); 0 means no LUT loaded.
    id<MTLTexture> lut3dTexture = nil;
    id<MTLSamplerState> lut3dSampler = nil;
    int lut3dSize = 0;
    // 1×1×1 placeholder so Metal validation has a bound texture when no
    // LUT is loaded (the shader's apply_lut3d returns its input verbatim
    // via the enabled gate, so the placeholder is never sampled — it
    // exists purely to satisfy resource binding).
    id<MTLTexture> lut3dPlaceholder = nil;

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
        lut3dTexture = nil;
        lut3dSampler = nil;
        lut3dPlaceholder = nil;
        lut3dSize = 0;
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

// ASC CDL primary grade uniform (spec 023 T032 / FR-016).
// Layout MUST match emp::CdlParams in editor_media_platform/emp_cdl.h
// (slope[3], offset[3], power[3], saturation, enabled). Uploaded each
// draw via setFragmentBytes at buffer index 0 — no allocation.
struct CdlUniform {
    float slope[3];
    float offset[3];
    float power[3];
    float saturation;
    int enabled;
};

// LUT3D color stage gate (spec 023 Piece 3 / FR-016). The cube data is
// uploaded as a separate texture3d (sampled with a linear sampler for
// HW trilinear); this uniform carries only the enable flag. When
// enabled == 0, apply_lut3d returns its input unchanged. The shader
// assumes domain [0,1] — Resolve's ExportLUT emits the default domain;
// GPUVideoSurface::setLut3D asserts on non-default DOMAIN_MIN/MAX to
// keep the assumption honest (rule 1.14 — surface the assumption
// break, do NOT silently mis-color the pixel).
struct LutUniform {
    int enabled;
};

// Color-space conversion uniform — replaces the per-shader hardcoded
// YUV→RGB math. A 3x4 affine matrix:
//   R = dot(row_r, float4(Y, Cb, Cr, 1))
//   G = dot(row_g, ...)
//   B = dot(row_b, ...)
// The CPU side composes the matrix from the source CVPixelBuffer's
// format and range (limited vs full) and the colorimetry primaries
// (today BT.709 only; BT.2020 lands when 4K HDR comes through).
// Composing on the CPU lets one shader cover every YUV path:
// biplanar Y+UV (NV12/P010/sv44) and packed AYUV (y416).
struct CscUniform {
    float4 row_r;
    float4 row_g;
    float4 row_b;
};

// Apply the 3x4 CSC affine matrix to a raw YCbCr triple from the
// source texture. The matrix carries both the BT.{601,709,2020}
// coefficients AND the range scaling (limited→full or pure full),
// so the same shader works for every YUV pixel format the renderer
// supports. CPU side composes the right matrix per source format.
float3 apply_csc(float3 ycbcr, constant CscUniform& csc) {
    float4 v = float4(ycbcr, 1.0);
    return float3(dot(csc.row_r, v), dot(csc.row_g, v), dot(csc.row_b, v));
}

// Mirrors emp::apply_cdl_rgb byte-for-byte semantically:
//   sop  = max(in*slope+offset, 0)        -- negative-clamp before pow
//   cdl  = sop^power
//   luma = dot(cdl, BT.709 weights)
//   out  = saturate(luma + (cdl-luma)*sat)
// When uniform.enabled == 0, returns rgb unchanged (passthrough).
float3 apply_cdl(float3 rgb, constant CdlUniform& cdl) {
    if (cdl.enabled == 0) return rgb;
    float3 s = float3(cdl.slope[0],  cdl.slope[1],  cdl.slope[2]);
    float3 o = float3(cdl.offset[0], cdl.offset[1], cdl.offset[2]);
    float3 p = float3(cdl.power[0],  cdl.power[1],  cdl.power[2]);
    float3 sop = max(rgb * s + o, 0.0);
    float3 c = pow(sop, p);
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));  // BT.709
    return saturate(float3(luma) + (c - float3(luma)) * cdl.saturation);
}

// Mirrors emp::apply_lut3d_rgb semantically. HW trilinear via the
// linear sampler matches the CPU 8-corner-lerp algorithm. Input is
// expected in [0,1] (display-space — setLut3D asserts the default
// DOMAIN_MIN/MAX). The sampler's clamp_to_edge address mode handles
// out-of-range inputs by snapping to the nearest grid edge.
// When uniform.enabled == 0, returns rgb unchanged (passthrough).
//
// Tetrahedral interpolation. Replaced HW trilinear sampler 2026-06-05
// to chase the residual green/dark mismatch vs Resolve preview. Two
// transfer-function experiments (2.2/2.4 fudge and full Rec.709
// EOTF/OETF round-trip) both proved the LUT operates in display-
// encoded space, so the input math is right. Remaining suspect is
// the interp algorithm: ffmpeg lut3d defaults to tetrahedral and
// Resolve's internal LUT engine uses it too; trilinear sampling
// can introduce subtle hue artifacts in the diamond regions of the
// cube (visible as a slight green cast on near-neutrals).
//
// Algorithm: 6 tetrahedra of the unit cube, picked by sorting the
// fractional offsets (dr, dg, db). Each tetra has 4 vertices and
// affine-weights summing to 1. Identity LUT remains passthrough
// because the affine combination at each tet reconstructs base+d.
// Uses texture3d.read() with integer coords — sampler is no longer
// needed for sampling but its binding/declaration is kept so the
// host-side draw code doesn't need to change.
//
// V1 scope unchanged: this is an interpolation upgrade only. Color
// management (per-project transfer functions, gamut mapping) is
// still punted to a later feature.
float3 apply_lut3d(float3 rgb,
                   texture3d<float> lut3d,
                   sampler lutSamp,
                   constant LutUniform& lut) {
    if (lut.enabled == 0) return rgb;

    float3 sat = saturate(rgb);
    int N = int(lut3d.get_width());
    float3 grid = sat * float(N - 1);
    int3 base = clamp(int3(floor(grid)), int3(0), int3(N - 2));
    float3 d = grid - float3(base);

    // 8 corners of the surrounding cube.
    float3 v000 = lut3d.read(uint3(base + int3(0,0,0))).rgb;
    float3 v100 = lut3d.read(uint3(base + int3(1,0,0))).rgb;
    float3 v010 = lut3d.read(uint3(base + int3(0,1,0))).rgb;
    float3 v001 = lut3d.read(uint3(base + int3(0,0,1))).rgb;
    float3 v110 = lut3d.read(uint3(base + int3(1,1,0))).rgb;
    float3 v101 = lut3d.read(uint3(base + int3(1,0,1))).rgb;
    float3 v011 = lut3d.read(uint3(base + int3(0,1,1))).rgb;
    float3 v111 = lut3d.read(uint3(base + int3(1,1,1))).rgb;

    float dr = d.r, dg = d.g, db = d.b;
    float3 result;
    if (dr >= dg) {
        if (dg >= db) {
            // R >= G >= B  — tet 000-100-110-111
            result = (1 - dr) * v000 + (dr - dg) * v100
                   + (dg - db) * v110 + db * v111;
        } else if (dr >= db) {
            // R >= B > G   — tet 000-100-101-111
            result = (1 - dr) * v000 + (dr - db) * v100
                   + (db - dg) * v101 + dg * v111;
        } else {
            // B > R >= G   — tet 000-001-101-111
            result = (1 - db) * v000 + (db - dr) * v001
                   + (dr - dg) * v101 + dg * v111;
        }
    } else {
        if (db >= dg) {
            // B >= G > R   — tet 000-001-011-111
            result = (1 - db) * v000 + (db - dg) * v001
                   + (dg - dr) * v011 + dr * v111;
        } else if (db >= dr) {
            // G > B >= R   — tet 000-010-011-111
            result = (1 - dg) * v000 + (dg - db) * v010
                   + (db - dr) * v011 + dr * v111;
        } else {
            // G > R > B    — tet 000-010-110-111
            result = (1 - dg) * v000 + (dg - dr) * v010
                   + (dr - db) * v110 + db * v111;
        }
    }
    return result;
}

vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// Biplanar YUV→RGB (NV12, P010, sv44, and all 4:2:0 / 4:2:2 / 4:4:4
// biplanar variants). Texture format already normalizes 8/10/16-bit
// storage to [0,1]; range scaling (limited→full) lives in the CSC
// matrix uniform built CPU-side from the source pixel format.
//
// Pre-CSC builds hardcoded BT.709 limited-range math in the shader,
// which silently mis-colored full-range biplanar sources (sv44 from
// ProRes 4444 12-bit, the 444*FullRange formats). Matrix uniform
// fixes that without per-format shader variants.
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texUV [[texture(1)]],
                               texture3d<float> lut3d [[texture(2)]],
                               sampler lutSamp [[sampler(0)]],
                               constant CdlUniform& cdl [[buffer(0)]],
                               constant LutUniform& lut [[buffer(1)]],
                               constant CscUniform& csc [[buffer(2)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float y = texY.sample(s, in.texCoord).r;
    float2 uv = texUV.sample(s, in.texCoord).rg;

    // YCbCr→RGB via uniform 3x4 affine. Limited-range scaling and
    // chroma centering are baked into the matrix CPU-side. Output
    // may overshoot [0,1] at boundary luma/chroma — apply_cdl runs
    // on the raw triple so slope/offset can pull super-white and
    // sub-black back into range; saturate once on output so 8-bit
    // display storage is clamped.
    float3 rgb = apply_csc(float3(y, uv.x, uv.y), csc);
    rgb = apply_cdl(rgb, cdl);
    rgb = apply_lut3d(rgb, lut3d, lutSamp, lut);
    return float4(saturate(rgb), 1.0);
}

// BGRA passthrough for sw-decoded frames (PNG, JPEG, etc.)
// MTLPixelFormatBGRA8Unorm swizzles on read, so sampling returns RGBA directly.
fragment float4 bgraFragmentShader(VertexOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   texture3d<float> lut3d [[texture(2)]],
                                   sampler lutSamp [[sampler(0)]],
                                   constant CdlUniform& cdl [[buffer(0)]],
                                   constant LutUniform& lut [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 rgba = tex.sample(s, in.texCoord);
    float3 rgb = apply_cdl(rgba.rgb, cdl);
    rgb = apply_lut3d(rgb, lut3d, lutSamp, lut);
    return float4(saturate(rgb), rgba.a);
}

// Packed 4:4:4:4 AYUV (y416 from ProRes 4444 with alpha).
// CVPixelBuffer format: A(16) Y(16) Cb(16) Cr(16) per pixel, non-planar.
// Metal RGBA16Unorm maps to: R=A, G=Y, B=Cb, A=Cr (all [0,1] normalized).
// Uses the same CSC uniform as fragmentShader — CPU side sets the
// matrix to BT.709 full-range for y416 (the only format that hits
// this path today).
fragment float4 packedYuvFragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        texture3d<float> lut3d [[texture(2)]],
                                        sampler lutSamp [[sampler(0)]],
                                        constant CdlUniform& cdl [[buffer(0)]],
                                        constant LutUniform& lut [[buffer(1)]],
                                        constant CscUniform& csc [[buffer(2)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 ayuv = tex.sample(s, in.texCoord);

    float alpha = ayuv.r;
    float3 rgb = apply_csc(float3(ayuv.g, ayuv.b, ayuv.a), csc);
    rgb = apply_cdl(rgb, cdl);
    rgb = apply_lut3d(rgb, lut3d, lutSamp, lut);
    return float4(saturate(rgb), alpha);
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
        // Tag the layer's pixels as Rec.709. Without this, macOS treats the
        // layer's contents as already in the display's native gamut (Display
        // P3 on modern Macs) and skips primaries conversion — Rec.709 greens
        // get rendered as P3 greens (visibly more saturated). With the tag,
        // WindowServer correctly converts Rec.709 → display gamut.
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
        JVE_ASSERT(cs, "CGColorSpaceCreateWithName(ITUR_709) failed");
        m_impl->metalLayer.colorspace = cs;
        CGColorSpaceRelease(cs);
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

        // LUT3D sampler: linear min/mag, clamp_to_edge address (out-of-
        // domain inputs snap to the nearest grid edge — matches the CPU
        // implementation's saturate-then-sample contract).
        MTLSamplerDescriptor* lutSampDesc = [MTLSamplerDescriptor new];
        lutSampDesc.minFilter = MTLSamplerMinMagFilterLinear;
        lutSampDesc.magFilter = MTLSamplerMinMagFilterLinear;
        lutSampDesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
        lutSampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        lutSampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        lutSampDesc.rAddressMode = MTLSamplerAddressModeClampToEdge;
        m_impl->lut3dSampler =
            [m_impl->device newSamplerStateWithDescriptor:lutSampDesc];
        JVE_ASSERT(m_impl->lut3dSampler,
            "GPUVideoSurface::initMetal: LUT3D sampler creation failed");

        // 1×1×1 placeholder 3D texture (RGBA16F). Bound when no LUT is
        // loaded so Metal validation passes; never sampled because the
        // shader's lut.enabled gate skips the sample call.
        MTLTextureDescriptor* lutPhDesc = [MTLTextureDescriptor new];
        lutPhDesc.textureType = MTLTextureType3D;
        lutPhDesc.pixelFormat = MTLPixelFormatRGBA16Float;
        lutPhDesc.width = 1; lutPhDesc.height = 1; lutPhDesc.depth = 1;
        lutPhDesc.usage = MTLTextureUsageShaderRead;
        m_impl->lut3dPlaceholder =
            [m_impl->device newTextureWithDescriptor:lutPhDesc];
        JVE_ASSERT(m_impl->lut3dPlaceholder,
            "GPUVideoSurface::initMetal: LUT3D placeholder texture failed");

        m_initialized = true;
        JVE_LOG_EVENT(Video, "GPUVideoSurface: Metal initialized");

        // Flush any LUT pushed by the View before Metal was ready
        // (FR-016 pull contract fires on first clip load, which beats
        // initMetal in the lifecycle). Calling setLut3D recursively
        // is safe because m_initialized is now true so it takes the
        // direct-upload path.
        if (!m_pending_lut3d.data.empty()) {
            emp::Lut3d pending = std::move(m_pending_lut3d);
            m_pending_lut3d = emp::Lut3d{};  // ensure data.empty()
            setLut3D(pending);
        }

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

    // Track unique visual content by source PTS. Stride-duplicated frames
    // share the same decoded PTS — they look identical even though the
    // playback controller sends them as different timeline frame numbers.
    int64_t pts = frame->source_pts_us();
    if (pts != m_last_source_pts) {
        ++m_unique_frame_count;
        m_last_source_pts = pts;
    }

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

        // Log the CVPixelBuffer fourCC on the first frame so the shader path
        // (limited-range YUV / full-range packed YUV / BGRA) is recoverable
        // from logs when a clip displays unexpectedly.
        if (m_frame_count == 1) {
            char fourcc[5] = {
                static_cast<char>((pixelFormat >> 24) & 0xFF),
                static_cast<char>((pixelFormat >> 16) & 0xFF),
                static_cast<char>((pixelFormat >> 8) & 0xFF),
                static_cast<char>(pixelFormat & 0xFF), '\0'
            };
            JVE_LOG_EVENT(Video,
                "setFrameImpl: CVPixelBuffer fourcc='%s' (0x%x) planeCount=%zu %dx%d",
                fourcc, pixelFormat, planeCount, w, h);
        }

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

// Compose the 3x4 YCbCr→RGB matrix for a CVPixelBuffer pixel format.
// Today we ship BT.709 only (HD primaries — every clip in the project
// is HD ProRes / H.264 / DV). BT.2020 (4K HDR) will add a second
// matrix family and a CVPixelBuffer attachment check; until then any
// non-BT.709 source would silently mis-color, so we assert on
// unrecognized formats rather than fall back.
//
// Range is selected from the format's range suffix:
//   *FullRange → Y in [0,1], Cb/Cr centered at 0.5, no Y scaling.
//   *VideoRange → Y in [16/255, 235/255], Cb/Cr in [16/255, 240/255],
//                 inverse-scaled back to full range in the matrix.
// Formats with no range suffix (4:4:4 8-bit packed, BGRA, etc.) are
// assumed full-range — VideoToolbox never emits limited-range data
// in those layouts.
static GPUVideoSurface::CscParams composeBt709Csc(uint32_t pixelFormat) {
    // BT.709 full-range affine. Derivation:
    //   R = Y + 1.5748*(Cr - 0.5)
    //   G = Y - 0.1873*(Cb - 0.5) - 0.4681*(Cr - 0.5)
    //   B = Y + 1.8556*(Cb - 0.5)
    // Constant column folds in the chroma -0.5 offsets.
    GPUVideoSurface::CscParams full = {
        { 1.0f,  0.0f,     1.5748f, -0.7874f },
        { 1.0f, -0.1873f, -0.4681f,  0.3277f },
        { 1.0f,  1.8556f,  0.0f,    -0.9278f },
    };

    // BT.709 limited-range affine. Y' = (Y - 16/255) * 255/219;
    // chroma is centered AND scaled by 255/224 to put neutral chroma
    // at 0 and reach ±0.5 at the format's stored extremes. Both
    // scalings fold into the matrix.
    //   Y_scale = 255/219 ≈ 1.16438
    //   C_scale = 255/224 ≈ 1.13839
    //   Y_offset_eff (constant col) = -1.16438 * 16/255 ≈ -0.07306
    //   C_offset_eff = -C_scale * 128/255 = -0.57143
    // Per-row constants compose chroma_coef * C_offset + Y_offset.
    GPUVideoSurface::CscParams limited = {
        { 1.16438f,  0.0f,      1.79274f, -0.97290f },
        { 1.16438f, -0.21325f, -0.53291f,  0.30163f },
        { 1.16438f,  2.11240f,  0.0f,     -1.13322f },
    };

    switch (pixelFormat) {
        // 4:2:0 8-bit
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:    return limited;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:     return full;
        // 4:2:0 10-bit
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:   return limited;
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:    return full;
        // 4:2:2 8/10/16-bit
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:    return limited;
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:     return full;
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:   return limited;
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:    return full;
        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:   return limited;
        // 4:4:4 8/10/16-bit
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:    return limited;
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:     return full;
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:   return limited;
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:    return full;
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:   return limited;
        // Packed y416 — always full-range per Apple's spec.
        case kCVPixelFormatType_4444AYpCbCr16:                   return full;
        default: {
            char fourcc[5] = {
                static_cast<char>((pixelFormat >> 24) & 0xFF),
                static_cast<char>((pixelFormat >> 16) & 0xFF),
                static_cast<char>((pixelFormat >> 8) & 0xFF),
                static_cast<char>(pixelFormat & 0xFF), '\0'
            };
            char msg[160];
            snprintf(msg, sizeof(msg),
                "composeBt709Csc: unrecognized YUV format '%s' (0x%x) — "
                "add explicit range mapping (FullRange vs VideoRange).",
                fourcc, pixelFormat);
            JVE_ASSERT(false, msg);
            return full;  // unreachable; assert aborts
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
    m_csc = composeBt709Csc(pixelFormat);
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
    m_csc = composeBt709Csc(pixelFormat);

    renderTexture();
}
#endif

void GPUVideoSurface::setFrameSW(const uint8_t* data, int w, int h, int stride) {
    JVE_ASSERT(data, "GPUVideoSurface::setFrameSW: null data pointer");
    JVE_ASSERT(w > 0 && h > 0, "GPUVideoSurface::setFrameSW: invalid dimensions");

    m_frameWidth = w;
    m_frameHeight = h;

    @autoreleasepool {
        // Reuse existing texture if dimensions match. Creating a new
        // MTLTexture every frame causes GPU memory churn — at 4K (33MB)
        // × 25fps the allocation pressure stalls nextDrawable for >900ms.
        // replaceRegion on an existing texture avoids the allocation.
        bool need_new_texture = !m_impl->bgraTexture
            || [m_impl->bgraTexture width] != static_cast<NSUInteger>(w)
            || [m_impl->bgraTexture height] != static_cast<NSUInteger>(h);

        if (need_new_texture) {
            m_impl->releaseTextures();

            MTLTextureDescriptor* desc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:w height:h mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;

            m_impl->bgraTexture = [m_impl->device newTextureWithDescriptor:desc];
            JVE_ASSERT(m_impl->bgraTexture, "GPUVideoSurface::setFrameSW: failed to create BGRA texture");
        }

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

void GPUVideoSurface::setGrade(const emp::CdlParams& cdl) {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::setGrade: must be on main thread");
    m_cdl = cdl;
    // No re-render here; the next setFrame will draw with the new grade.
    // View contract: push grade BEFORE pushing frame.
}

void GPUVideoSurface::clearGrade() {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::clearGrade: must be on main thread");
    m_cdl = emp::CdlParams{};  // zero-init ⇒ enabled = 0 (passthrough)
}

void GPUVideoSurface::setLut3D(const emp::Lut3d& lut) {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::setLut3D: must be on main thread");
    JVE_ASSERT(lut.enabled == 1,
        "GPUVideoSurface::setLut3D: caller passed an unloaded lut "
        "(enabled==0) — use clearLut3D() to disable");
    JVE_ASSERT(lut.size >= 2 && lut.size <= 256,
        "GPUVideoSurface::setLut3D: lut.size out of [2,256]");
    JVE_ASSERT(static_cast<size_t>(lut.size) * lut.size * lut.size * 3
                == lut.data.size(),
        "GPUVideoSurface::setLut3D: lut.data size mismatches grid");
    // Domain assumption: shader samples saturate(rgb) ∈ [0,1] against
    // the cube, so non-default domains would silently mis-map colors.
    // Surface the assumption break (rule 1.14 / 2.32).
    JVE_ASSERT(lut.domain_min[0] == 0.0f && lut.domain_min[1] == 0.0f
                && lut.domain_min[2] == 0.0f,
        "GPUVideoSurface::setLut3D: non-default DOMAIN_MIN not "
        "supported (V1 scope: display-space LUTs only)");
    JVE_ASSERT(lut.domain_max[0] == 1.0f && lut.domain_max[1] == 1.0f
                && lut.domain_max[2] == 1.0f,
        "GPUVideoSurface::setLut3D: non-default DOMAIN_MAX not "
        "supported (V1 scope: display-space LUTs only)");

    // Race with deferred Metal init: the View pushes a grade as soon
    // as a clip is loaded (FR-016 pull contract), which can happen
    // BEFORE GPUVideoSurface::initMetal completes. Stash the lut and
    // let initMetal flush it once the device exists. Until then the
    // shader sees lut.enabled == 0 (placeholder texture bound) so the
    // pipeline still draws correctly — ungraded — instead of crashing
    // on an unmade texture (rule 1.14 satisfied by the JVE_ASSERTs
    // above + the deferred flush asserting against init failure).
    if (!m_initialized) {
        m_pending_lut3d = lut;
        m_lut_size = lut.size;  // expose via lut3dSize() right away
        // m_lut_enabled stays 0 until initMetal flushes; shader is
        // passthrough in the meantime.
        return;
    }

    @autoreleasepool {
        // Reuse the existing 3D texture if its size matches — same
        // allocation-churn rationale as the bgraTexture reuse path
        // (setFrameSW). Switching grade or even reloading the same LUT
        // is rare relative to per-frame draws, but allocations on the
        // main thread block UI.
        const int N = lut.size;
        if (!m_impl->lut3dTexture || m_impl->lut3dSize != N) {
            MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
            desc.textureType = MTLTextureType3D;
            desc.pixelFormat = MTLPixelFormatRGBA16Float;
            desc.width = N; desc.height = N; desc.depth = N;
            desc.usage = MTLTextureUsageShaderRead;
            m_impl->lut3dTexture =
                [m_impl->device newTextureWithDescriptor:desc];
            JVE_ASSERT(m_impl->lut3dTexture,
                "GPUVideoSurface::setLut3D: 3D texture creation failed");
            m_impl->lut3dSize = N;
        }

        // Convert float RGB triples → half-float RGBA16 rows. Metal's
        // RGBA16F upload expects 4 channels per texel; we set A=1.0
        // (unused — the shader samples .rgb).
        // Use __fp16 (Apple half) for the conversion — Metal-defined
        // type, no extra dependency. Allocation is per-setLut3D, not
        // per-frame, so it doesn't violate the hot-loop alloc rule.
        const size_t texel_count = static_cast<size_t>(N) * N * N;
        std::vector<__fp16> half_rgba(texel_count * 4);
        for (size_t i = 0; i < texel_count; ++i) {
            half_rgba[i * 4 + 0] = static_cast<__fp16>(lut.data[i * 3 + 0]);
            half_rgba[i * 4 + 1] = static_cast<__fp16>(lut.data[i * 3 + 1]);
            half_rgba[i * 4 + 2] = static_cast<__fp16>(lut.data[i * 3 + 2]);
            half_rgba[i * 4 + 3] = static_cast<__fp16>(1.0f);
        }
        const size_t bytes_per_row = N * 4 * sizeof(__fp16);
        const size_t bytes_per_slice = N * bytes_per_row;
        MTLRegion region = MTLRegionMake3D(0, 0, 0, N, N, N);
        [m_impl->lut3dTexture replaceRegion:region
            mipmapLevel:0 slice:0
            withBytes:half_rgba.data()
            bytesPerRow:bytes_per_row
            bytesPerImage:bytes_per_slice];
    }
    m_lut_enabled = 1;
    m_lut_size = lut.size;
    // No re-render here; view contract: push LUT BEFORE setFrame.
}

void GPUVideoSurface::clearLut3D() {
    JVE_ASSERT([NSThread isMainThread],
        "GPUVideoSurface::clearLut3D: must be on main thread");
    m_lut_enabled = 0;
    m_lut_size = 0;
    // Drop any LUT stashed before Metal init so it doesn't surprise
    // us by lighting up at the end of initMetal after clearLut3D.
    m_pending_lut3d = emp::Lut3d{};
    // Keep lut3dTexture around for reuse on a future setLut3D of the
    // same size — freeing it would force an allocation on next set.
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

            // CDL color stage uniform (T032 / FR-016). All three shaders
            // bind it at fragment buffer index 0. setFragmentBytes is the
            // Apple-blessed zero-alloc path for ≤4KB structs; CdlParams
            // is 44 bytes. apply_cdl is a no-op when enabled==0, so
            // ungraded surfaces are bit-identical to pre-T032 output.
            [encoder setFragmentBytes:&m_cdl length:sizeof(m_cdl) atIndex:0];

            // LUT3D color stage (Piece 3 of spec 023 / FR-016). texture(2)
            // + sampler(0) are declared in every shader. Metal validation
            // requires every declared resource be bound, so when no LUT
            // is loaded we bind a 1×1×1 placeholder texture and pass
            // enabled=0 — apply_lut3d returns its input unchanged.
            id<MTLTexture> bound_lut = m_impl->lut3dTexture
                ? m_impl->lut3dTexture : m_impl->lut3dPlaceholder;
            JVE_ASSERT(bound_lut,
                "GPUVideoSurface::renderTexture: lut3d placeholder "
                "missing (initMetal didn't create it?)");
            [encoder setFragmentTexture:bound_lut atIndex:2];
            [encoder setFragmentSamplerState:m_impl->lut3dSampler
                                     atIndex:0];
            // C++ mirror of the Metal-side LutUniform struct. Layout
            // MUST match — a single int32 `enabled` (4 bytes). Kept
            // local to the draw call since it's 4 bytes and the
            // setFragmentBytes path is zero-alloc per Apple docs.
            struct LutUniformCpp { int32_t enabled; };
            LutUniformCpp lut_uniform{};
            lut_uniform.enabled = m_lut_enabled;
            [encoder setFragmentBytes:&lut_uniform
                               length:sizeof(lut_uniform)
                              atIndex:1];

            // CSC matrix uniform — only YUV pipelines declare it; BGRA
            // reads RGB straight from the texture so no matrix applies.
            // Layout MUST match the Metal CscUniform struct.
            if (m_impl->frameMode == FrameMode::YUV
                || m_impl->frameMode == FrameMode::PackedYUV) {
                [encoder setFragmentBytes:&m_csc
                                   length:sizeof(m_csc)
                                  atIndex:2];
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
