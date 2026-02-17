#pragma once

#include <QWidget>
#include <QPaintEngine>
#include <cstdint>
#include <memory>

namespace emp { class Frame; }

#ifdef __APPLE__

class GPUVideoSurfaceImpl;

// GPUVideoSurface - Hardware-accelerated video renderer (Metal on macOS)
// Supports both hw-decoded frames (VideoToolbox YUV, zero-copy) and
// sw-decoded frames (BGRA CPU data, uploaded to Metal texture).
class GPUVideoSurface : public QWidget {
    Q_OBJECT

public:
    explicit GPUVideoSurface(QWidget* parent = nullptr);
    ~GPUVideoSurface() override;

    // Set frame to display. Accepts both hw-decoded (native_buffer) and
    // sw-decoded (CPU BGRA data) frames.
    void setFrame(const std::shared_ptr<emp::Frame>& frame);

    // Clear display
    void clearFrame();

    // Set rotation (0, 90, 180, 270 degrees)
    void setRotation(int degrees);
    int rotation() const { return m_rotation; }

    int frameWidth() const { return m_frameWidth; }
    int frameHeight() const { return m_frameHeight; }

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
    void renderTexture();
    void rebuildVertexBuffer();

    // HW path: zero-copy from VideoToolbox CVPixelBuffer (YUV bi-planar)
    void setFrameHW(void* pixelBuffer, int w, int h);
    // SW path: upload BGRA CPU data to Metal texture
    void setFrameSW(const uint8_t* data, int w, int h, int stride);

    std::unique_ptr<GPUVideoSurfaceImpl> m_impl;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
    int m_rotation = 0;
    bool m_initialized = false;
};

#else
// Non-Apple: GPUVideoSurface not available
// Caller should check GPUVideoSurface::isAvailable() and use CPUVideoSurface
class GPUVideoSurface : public QWidget {
    Q_OBJECT
public:
    explicit GPUVideoSurface(QWidget* parent = nullptr) : QWidget(parent) {}
    void setFrame(const std::shared_ptr<emp::Frame>&) { assert(false && "GPUVideoSurface not available on this platform"); }
    void clearFrame() {}
    void setRotation(int) {}
    int rotation() const { return 0; }
    int frameWidth() const { return 0; }
    int frameHeight() const { return 0; }
    static bool isAvailable() { return false; }
};
#endif
