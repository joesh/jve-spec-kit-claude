#pragma once

#include <QWidget>
#include <QPaintEngine>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include <editor_media_platform/emp_cdl.h>
#include <editor_media_platform/emp_lut3d.h>

namespace emp { class Frame; }

#ifdef __APPLE__

class GPUVideoSurfaceImpl;

// GPUVideoSurface - Hardware-accelerated video renderer (Metal on macOS)
// Three render paths, all GPU-accelerated via Metal:
//   1. HW YUV: biplanar CVPixelBuffer (NV12/P010/etc.) → zero-copy Y+UV textures → YUV shader
//   2. HW BGRA: non-planar CVPixelBuffer (ProRes 4444, Animation) → zero-copy BGRA texture
//   3. SW BGRA: CPU-decoded data → uploaded BGRA texture
class GPUVideoSurface : public QWidget {
    Q_OBJECT

public:
    explicit GPUVideoSurface(QWidget* parent = nullptr);
    ~GPUVideoSurface() override;

    // Callback fired once when Metal backend becomes render-ready.
    // If Metal is already initialized when callback is set, fires immediately.
    using ReadyCallback = std::function<void()>;
    void setReadyCallback(ReadyCallback cb);

    // Callback fired when a frame cannot be rendered (unsupported format,
    // texture creation failure, etc.). Surfaces the error to the View so
    // it can display an indicator instead of showing stale content.
    using ErrorCallback = std::function<void(const std::string& error)>;
    void setErrorCallback(ErrorCallback cb);

    // Set frame to display. Thread-safe: if called off the main thread,
    // dispatches to main queue. Generation counter prevents stale dispatches
    // from overwriting newer ones.
    void setFrame(const std::shared_ptr<emp::Frame>& frame);

    // Clear display to black. Thread-safe (same dispatch + generation logic).
    void clearFrame();

    // CDL color stage (spec 023 T032 / FR-016). The View pulls the
    // clip's grade from the model and pushes the CDL params here
    // BEFORE setFrame; subsequent frames apply the math in the Metal
    // fragment shader (uniform binding) before the final saturate.
    // Main-thread only. clearGrade flips enabled=0 (passthrough).
    void setGrade(const emp::CdlParams& cdl);
    void clearGrade();
    const emp::CdlParams& grade() const { return m_cdl; }

    // LUT3D color stage (spec 023 Piece 3 / FR-016 — partial / unrepresentable
    // fidelity path). Same View contract as setGrade: push BEFORE setFrame.
    // CDL and LUT are mutually exclusive per clip per FR-015's closed-set
    // fidelity discriminator — view_grade_pull guarantees only one is
    // enabled at a time, so the shader can apply both in series with
    // either flag flipped off without conflict. Uploads the cube data as
    // an MTLTextureType3D RGBA16F texture; hardware MTLSamplerStateLinear
    // gives trilinear matching emp::apply_lut3d_rgb. Main-thread only.
    void setLut3D(const emp::Lut3d& lut);
    void clearLut3D();
    int lut3dSize() const { return m_lut_size; }

    // Set rotation (0, 90, 180, 270 degrees)
    void setRotation(int degrees);
    int rotation() const { return m_rotation; }

    // Set pixel aspect ratio (1:1 = square pixels, 4:3 = anamorphic HD)
    void setPixelAspectRatio(int num, int den);
    int parNum() const { return m_par_num; }
    int parDen() const { return m_par_den; }

    int frameWidth() const { return m_frameWidth; }
    int frameHeight() const { return m_frameHeight; }
    int frameCount() const { return m_frame_count; }
    // Count of frames with distinct source PTS (unique visual content).
    // Stride-duplicated frames share the same PTS and don't increment this.
    int uniqueFrameCount() const { return m_unique_frame_count; }

    // YCbCr→RGB color-space conversion matrix uniform. Layout MUST
    // match the Metal CscUniform struct (three float4 rows = a 3x4
    // affine matrix). Composed from the source CVPixelBuffer's
    // pixel format in setFrameHW_YUV / setFrameHW_PackedYUV — picks
    // BT.709 limited vs full range based on the format's range
    // suffix. Public so the file-static composeBt709Csc helper in
    // the .mm can construct one without friending it.
    struct CscParams {
        float row_r[4];
        float row_g[4];
        float row_b[4];
    };

    // Check if GPU rendering is available
    static bool isAvailable();

    // Override to suppress Qt paint warnings (Metal handles rendering)
    QPaintEngine* paintEngine() const override { return nullptr; }

protected:
    void paintEvent(QPaintEvent*) override {}  // Metal handles rendering
    void resizeEvent(QResizeEvent* event) override;
    bool event(QEvent* event) override;

private:
    void initMetal();
    void cleanupMetal();
    void tryFireReady();
    void renderTexture();
    void rebuildVertexBuffer();

    // Internal impl — MUST be called on main thread only.
    // Public setFrame/clearFrame handle dispatch + generation.
    void setFrameImpl(const std::shared_ptr<emp::Frame>& frame);
    void clearFrameImpl();

    // HW path: zero-copy from VideoToolbox CVPixelBuffer → Metal texture
    void setFrameHW(void* pixelBuffer, int w, int h);
    void setFrameHW_YUV(void* pixelBuffer, uint32_t pixelFormat);       // biplanar YUV
    void setFrameHW_BGRA(void* pixelBuffer, uint32_t pixelFormat);      // non-planar BGRA
    void setFrameHW_PackedYUV(void* pixelBuffer, uint32_t pixelFormat); // non-planar packed YUV (y416)
    // SW path: upload BGRA CPU data to Metal texture
    void setFrameSW(const uint8_t* data, int w, int h, int stride);

    std::unique_ptr<GPUVideoSurfaceImpl> m_impl;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
    int m_rotation = 0;
    int m_par_num = 1;
    int m_par_den = 1;
    int m_frame_count = 0;
    int m_unique_frame_count = 0;
    int64_t m_last_source_pts = INT64_MIN;
    bool m_initialized = false;
    bool m_ready_fired = false;  // ready_callback fires once: Metal init + non-zero geometry
    ReadyCallback m_ready_callback;
    ErrorCallback m_error_callback;

    // Generation counter: monotonically increasing. Each setFrame/clearFrame
    // call increments before dispatching. The dispatched block only executes
    // if its captured generation still matches current — stale dispatches
    // (from earlier ticks) become no-ops.
    std::atomic<uint64_t> m_generation{0};

    // CDL color stage state (T032). Zero-init ⇒ enabled = 0 (passthrough),
    // so untouched surfaces behave bit-identically to pre-T032 builds.
    // Uploaded to the fragment shader via setFragmentBytes each draw.
    emp::CdlParams m_cdl{};

    // LUT3D color stage state (Piece 3 of spec 023). Cube data + size is
    // owned by the impl's MTLTexture (uploaded RGBA16F at setLut3D); the
    // shader-side gate is this enabled flag, uploaded as a 4-byte
    // LutUniform via setFragmentBytes each draw. Zero-init ⇒ disabled
    // (passthrough), so untouched surfaces behave identically to pre-
    // Piece-3 builds.
    int32_t m_lut_enabled = 0;
    int     m_lut_size    = 0;  // tracked separately for setLut3D reuse

    // Deferred LUT upload: setLut3D may be called BEFORE Metal init
    // completes (View pushes grade as soon as a clip is loaded, which
    // races with the GPU surface's deferred Metal init). The Lut3d
    // struct lands here; initMetal flushes it after creating the
    // device + sampler + placeholder. Empty std::vector ⇒ no pending.
    emp::Lut3d m_pending_lut3d{};

    // Zero-init ⇒ all rows zero (would produce black) so every YUV
    // setFrame MUST overwrite this before draw. See public CscParams
    // declaration above for layout invariants.
    CscParams m_csc{};
};

#else
// Non-Apple: GPUVideoSurface not available
// Caller should check GPUVideoSurface::isAvailable() and use CPUVideoSurface
class GPUVideoSurface : public QWidget {
    Q_OBJECT
public:
    using ReadyCallback = std::function<void()>;
    using ErrorCallback = std::function<void(const std::string&)>;
    explicit GPUVideoSurface(QWidget* parent = nullptr) : QWidget(parent) {}
    void setReadyCallback(ReadyCallback) {}
    void setErrorCallback(ErrorCallback) {}
    void setFrame(const std::shared_ptr<emp::Frame>&) { assert(false && "GPUVideoSurface not available on this platform"); }
    void clearFrame() {}
    void setGrade(const emp::CdlParams&) {}
    void clearGrade() {}
    void setLut3D(const emp::Lut3d&) {}
    void clearLut3D() {}
    int lut3dSize() const { return 0; }
    void setRotation(int) {}
    int rotation() const { return 0; }
    void setPixelAspectRatio(int, int) {}
    int parNum() const { return 1; }
    int parDen() const { return 1; }
    int frameWidth() const { return 0; }
    int frameHeight() const { return 0; }
    int frameCount() const { return 0; }
    static bool isAvailable() { return false; }
};
#endif
