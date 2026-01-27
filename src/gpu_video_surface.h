#pragma once

#include <QWidget>
#include <QPaintEngine>
#include <cstdint>
#include <memory>

namespace emp { class Frame; }

#ifdef __APPLE__

class GPUVideoSurfaceImpl;

// GPUVideoSurface - Hardware-accelerated video renderer (Metal on macOS)
// Requires frames with native hw buffer. Asserts if frame has no hw buffer.
// For CPU-decoded frames, use CPUVideoSurface instead.
class GPUVideoSurface : public QWidget {
    Q_OBJECT

public:
    explicit GPUVideoSurface(QWidget* parent = nullptr);
    ~GPUVideoSurface() override;

    // Set frame to display (MUST have native hw buffer)
    // Asserts if frame->native_buffer() is null
    void setFrame(const std::shared_ptr<emp::Frame>& frame);

    // Clear display
    void clearFrame();

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

    std::unique_ptr<GPUVideoSurfaceImpl> m_impl;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
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
    int frameWidth() const { return 0; }
    int frameHeight() const { return 0; }
    static bool isAvailable() { return false; }
};
#endif
