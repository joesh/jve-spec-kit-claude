#pragma once

#include <QWidget>
#include <QImage>
#include <cstdint>
#include <memory>

namespace emp { class Frame; }

// CPUVideoSurface - CPU-based video renderer using QPainter
// Works on all platforms. For hardware acceleration, use GPUVideoSurface.
class CPUVideoSurface : public QWidget {
    Q_OBJECT

public:
    explicit CPUVideoSurface(QWidget* parent = nullptr);
    ~CPUVideoSurface() override;

    // Set frame (calls frame->data() to get CPU pixels)
    void setFrame(const std::shared_ptr<emp::Frame>& frame);

    // Set frame from raw BGRA32 data
    void setFrameData(const uint8_t* data, int width, int height, int stride);

    // Clear display
    void clearFrame();

    int frameWidth() const { return m_frameWidth; }
    int frameHeight() const { return m_frameHeight; }

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    QImage m_image;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
};
