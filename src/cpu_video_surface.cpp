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

void CPUVideoSurface::setRotation(int degrees) {
    // Normalize to 0, 90, 180, 270
    int normalized = degrees % 360;
    if (normalized < 0) normalized += 360;
    normalized = (normalized / 90) * 90;  // Snap to nearest 90
    if (m_rotation != normalized) {
        m_rotation = normalized;
        update();
    }
}

void CPUVideoSurface::paintEvent(QPaintEvent*) {
    QPainter painter(this);
    painter.fillRect(rect(), Qt::black);

    if (m_image.isNull()) return;

    // For 90/270 rotation, effective dimensions are swapped
    int img_w = m_image.width();
    int img_h = m_image.height();
    bool swap_dims = (m_rotation == 90 || m_rotation == 270);
    double frame_w = swap_dims ? img_h : img_w;
    double frame_h = swap_dims ? img_w : img_h;

    // Letterbox with effective dimensions
    double frame_aspect = frame_w / frame_h;
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

    if (m_rotation == 0) {
        painter.drawImage(dest, m_image);
    } else {
        // Apply rotation transform
        painter.save();
        painter.translate(dest.center());
        painter.rotate(m_rotation);
        // After rotation, draw centered on origin
        QRectF src_rect(0, 0, img_w, img_h);
        QRectF dst_rect;
        if (swap_dims) {
            // 90/270: dest rect has swapped effective size
            dst_rect = QRectF(-dest.height() / 2.0, -dest.width() / 2.0,
                              dest.height(), dest.width());
        } else {
            // 180: dest rect is same
            dst_rect = QRectF(-dest.width() / 2.0, -dest.height() / 2.0,
                              dest.width(), dest.height());
        }
        painter.drawImage(dst_rect, m_image, src_rect);
        painter.restore();
    }
}
