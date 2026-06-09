// Tests for CPUVideoSurface and GPUVideoSurface
// Tests: widget creation, frame display, clear, resize

#include <QtTest>
#include <QImage>
#include <QApplication>

#include "cpu_video_surface.h"
#include "gpu_video_surface.h"

class TestVideoSurface : public QObject
{
    Q_OBJECT

private:
    // Create test BGRA image data
    std::vector<uint8_t> createTestImage(int width, int height, int* outStride) {
        int stride = ((width * 4) + 31) & ~31;
        *outStride = stride;

        std::vector<uint8_t> data(stride * height);

        for (int y = 0; y < height; ++y) {
            uint8_t* row = data.data() + y * stride;
            for (int x = 0; x < width; ++x) {
                row[x * 4 + 0] = static_cast<uint8_t>(x * 255 / width);  // B
                row[x * 4 + 1] = static_cast<uint8_t>(y * 255 / height); // G
                row[x * 4 + 2] = 128;  // R
                row[x * 4 + 3] = 255;  // A
            }
        }

        return data;
    }

private slots:
    // ========================================================================
    // CPUVideoSurface tests
    // ========================================================================

    void test_cpu_creation() {
        CPUVideoSurface widget;
        QCOMPARE(widget.frameWidth(), 0);
        QCOMPARE(widget.frameHeight(), 0);
    }

    void test_cpu_set_frame() {
        CPUVideoSurface widget;

        int stride;
        auto data = createTestImage(640, 480, &stride);

        widget.setFrameData(data.data(), 640, 480, stride);

        QCOMPARE(widget.frameWidth(), 640);
        QCOMPARE(widget.frameHeight(), 480);
    }

    void test_cpu_clear() {
        CPUVideoSurface widget;

        int stride;
        auto data = createTestImage(640, 480, &stride);

        widget.setFrameData(data.data(), 640, 480, stride);
        QCOMPARE(widget.frameWidth(), 640);

        widget.clearFrame();
        QCOMPARE(widget.frameWidth(), 0);
        QCOMPARE(widget.frameHeight(), 0);
    }

    void test_cpu_null_data_clears() {
        CPUVideoSurface widget;

        int stride;
        auto data = createTestImage(640, 480, &stride);

        widget.setFrameData(data.data(), 640, 480, stride);
        QCOMPARE(widget.frameWidth(), 640);

        widget.setFrameData(nullptr, 0, 0, 0);
        QCOMPARE(widget.frameWidth(), 0);
    }

    void test_cpu_different_sizes() {
        CPUVideoSurface widget;

        int stride1;
        auto data1 = createTestImage(1920, 1080, &stride1);
        widget.setFrameData(data1.data(), 1920, 1080, stride1);
        QCOMPARE(widget.frameWidth(), 1920);
        QCOMPARE(widget.frameHeight(), 1080);

        int stride2;
        auto data2 = createTestImage(640, 480, &stride2);
        widget.setFrameData(data2.data(), 640, 480, stride2);
        QCOMPARE(widget.frameWidth(), 640);
        QCOMPARE(widget.frameHeight(), 480);
    }

    void test_cpu_paint_doesnt_crash() {
        CPUVideoSurface widget;
        widget.resize(800, 600);

        int stride;
        auto data = createTestImage(640, 480, &stride);
        widget.setFrameData(data.data(), 640, 480, stride);

        widget.show();
        widget.repaint();
        QApplication::processEvents();

        QVERIFY(true);
    }

    void test_cpu_paint_empty_doesnt_crash() {
        CPUVideoSurface widget;
        widget.resize(800, 600);

        widget.show();
        widget.repaint();
        QApplication::processEvents();

        QVERIFY(true);
    }

    void test_cpu_stride_handling() {
        CPUVideoSurface widget;

        int width = 100;
        int height = 100;
        int stride = 512; // Much larger than width * 4 = 400

        std::vector<uint8_t> data(stride * height);

        for (int y = 0; y < height; ++y) {
            uint8_t* row = data.data() + y * stride;
            for (int x = 0; x < width; ++x) {
                row[x * 4 + 0] = 255;
                row[x * 4 + 1] = 0;
                row[x * 4 + 2] = 0;
                row[x * 4 + 3] = 255;
            }
        }

        widget.setFrameData(data.data(), width, height, stride);

        QCOMPARE(widget.frameWidth(), width);
        QCOMPARE(widget.frameHeight(), height);
    }

#ifdef __APPLE__
    // ========================================================================
    // GPUVideoSurface tests (macOS only)
    // ========================================================================

    void test_gpu_available() {
        // On macOS with Metal, this should be true
        QVERIFY(GPUVideoSurface::isAvailable());
    }

    void test_gpu_creation() {
        if (!GPUVideoSurface::isAvailable()) QSKIP("GPU not available");

        GPUVideoSurface widget;
        QCOMPARE(widget.frameWidth(), 0);
        QCOMPARE(widget.frameHeight(), 0);
    }

    void test_gpu_clear() {
        if (!GPUVideoSurface::isAvailable()) QSKIP("GPU not available");

        GPUVideoSurface widget;
        widget.clearFrame();
        QCOMPARE(widget.frameWidth(), 0);
        QCOMPARE(widget.frameHeight(), 0);
    }

    void test_gpu_set_frame_null() {
        if (!GPUVideoSurface::isAvailable()) QSKIP("GPU not available");

        GPUVideoSurface widget;
        widget.setFrame(nullptr);
        QCOMPARE(widget.frameWidth(), 0);
    }

    void test_gpu_resize() {
        if (!GPUVideoSurface::isAvailable()) QSKIP("GPU not available");

        GPUVideoSurface widget;
        widget.resize(800, 600);
        widget.resize(1024, 768);
        QVERIFY(true); // No crash
    }
#endif
};

QTEST_MAIN(TestVideoSurface)
#include "test_video_surface.moc"
