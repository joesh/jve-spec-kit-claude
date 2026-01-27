#include "cpu_video_surface.h"
#include <editor_media_platform/emp_frame.h>
#include <QPainter>
#include <cstring>

CPUVideoSurface::CPUVideoSurface(QWidget* parent)
    : QWidget(parent)
{
    setAutoFillBackground(true);
    QPalette pal = palette();
    pal.setColor(QPalette::Window, Qt::black);
    setPalette(pal);
}

CPUVideoSurface::~CPUVideoSurface() = default;

void CPUVideoSurface::setFrame(const std::shared_ptr<emp::Frame>& frame) {
    if (!frame) {
        clearFrame();
        return;
    }
    setFrameData(frame->data(), frame->width(), frame->height(), frame->stride_bytes());
}

void CPUVideoSurface::setFrameData(const uint8_t* data, int width, int height, int stride) {
    if (!data || width <= 0 || height <= 0) {
        clearFrame();
        return;
    }

    m_frameWidth = width;
    m_frameHeight = height;

    if (m_image.width() != width || m_image.height() != height) {
        m_image = QImage(width, height, QImage::Format_ARGB32);
    }

    for (int y = 0; y < height; ++y) {
        std::memcpy(m_image.scanLine(y), data + y * stride, width * 4);
    }

    update();
}

void CPUVideoSurface::clearFrame() {
    m_frameWidth = 0;
    m_frameHeight = 0;
    m_image = QImage();
    update();
}

void CPUVideoSurface::paintEvent(QPaintEvent*) {
    QPainter painter(this);
    painter.fillRect(rect(), Qt::black);

    if (m_image.isNull()) return;

    // Letterbox
    double frame_aspect = (double)m_image.width() / m_image.height();
    double widget_aspect = (double)width() / height();

    QRect dest;
    if (frame_aspect > widget_aspect) {
        int h = (int)(width() / frame_aspect);
        dest = QRect(0, (height() - h) / 2, width(), h);
    } else {
        int w = (int)(height() * frame_aspect);
        dest = QRect((width() - w) / 2, 0, w, height());
    }

    painter.setRenderHint(QPainter::SmoothPixmapTransform);
    painter.drawImage(dest, m_image);
}
