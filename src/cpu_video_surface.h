#pragma once

#include <QWidget>
#include <QImage>
#include <cstdint>
#include <memory>

#include <editor_media_platform/emp_cdl.h>

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

    // Set rotation (0, 90, 180, 270 degrees)
    void setRotation(int degrees);
    int rotation() const { return m_rotation; }

    int frameWidth() const { return m_frameWidth; }
    int frameHeight() const { return m_frameHeight; }

    // CDL color stage (spec 023 T032 / FR-016). The View pulls the
    // clip's grade from the model and pushes the CDL params here
    // BEFORE setFrame; subsequent frames apply the math in-place on
    // the BGRA buffer before display. clearGrade flips enabled=0
    // (subsequent frames pass through).
    void setGrade(const emp::CdlParams& cdl);
    void clearGrade();
    const emp::CdlParams& grade() const { return m_cdl; }

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    QImage m_image;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
    int m_rotation = 0;  // 0, 90, 180, 270
    emp::CdlParams m_cdl{};  // zero-init ⇒ enabled = 0 (passthrough)
};
