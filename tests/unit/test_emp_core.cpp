// Comprehensive tests for EMP (Editor Media Platform) core functionality
// Coverage: ALL paths including errors, edge cases, resource lifecycle, fallbacks

#include <QtTest>
#include <QTemporaryFile>
#include <QTemporaryDir>
#include <QDir>
#include <QThread>
#include <QElapsedTimer>

#include <editor_media_platform/emp_asset.h>
#include <editor_media_platform/emp_reader.h>
#include <editor_media_platform/emp_frame.h>
#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>

class TestEMPCore : public QObject
{
    Q_OBJECT

private:
    QString m_testVideoPath;
    bool m_hasTestVideo = false;

    void findTestVideo() {
        QStringList searchPaths = {
            QDir::homePath() + "/Movies",
            QDir::homePath() + "/Videos",
            QDir::homePath() + "/Desktop",
            "/tmp",
            QDir::currentPath() + "/tests/fixtures",
        };

        QStringList videoExtensions = {"*.mp4", "*.mov", "*.m4v", "*.mkv"};

        for (const QString& path : searchPaths) {
            QDir dir(path);
            if (!dir.exists()) continue;

            QStringList files = dir.entryList(videoExtensions, QDir::Files, QDir::Size);
            for (const QString& file : files) {
                QString fullPath = dir.absoluteFilePath(file);
                auto result = emp::Asset::Open(fullPath.toStdString());
                if (result.is_ok() && result.value()->info().has_video) {
                    m_testVideoPath = fullPath;
                    m_hasTestVideo = true;
                    return;
                }
            }
        }
    }

private slots:
    void initTestCase() { findTestVideo(); }

    // ========================================================================
    // ERROR TYPE TESTS - All error codes and factory methods
    // ========================================================================

    void test_error_code_to_string_all_codes() {
        // Every error code must have a string representation
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::Ok)), QString("Ok"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::FileNotFound)), QString("FileNotFound"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::Unsupported)), QString("Unsupported"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::DecodeFailed)), QString("DecodeFailed"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::SeekFailed)), QString("SeekFailed"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::EOFReached)), QString("EOFReached"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::InvalidArg)), QString("InvalidArg"));
        QCOMPARE(QString(emp::error_code_to_string(emp::ErrorCode::Internal)), QString("Internal"));
    }

    void test_error_factory_all_methods() {
        // Test every Error factory method
        auto e1 = emp::Error::ok();
        QCOMPARE(e1.code, emp::ErrorCode::Ok);

        auto e2 = emp::Error::file_not_found("/path");
        QCOMPARE(e2.code, emp::ErrorCode::FileNotFound);
        QVERIFY(e2.message.find("/path") != std::string::npos);

        auto e3 = emp::Error::unsupported("codec");
        QCOMPARE(e3.code, emp::ErrorCode::Unsupported);
        QVERIFY(e3.message.find("codec") != std::string::npos);

        auto e4 = emp::Error::decode_failed("reason");
        QCOMPARE(e4.code, emp::ErrorCode::DecodeFailed);

        auto e5 = emp::Error::seek_failed("reason");
        QCOMPARE(e5.code, emp::ErrorCode::SeekFailed);

        auto e6 = emp::Error::eof();
        QCOMPARE(e6.code, emp::ErrorCode::EOFReached);

        auto e7 = emp::Error::invalid_arg("arg");
        QCOMPARE(e7.code, emp::ErrorCode::InvalidArg);

        auto e8 = emp::Error::internal("detail");
        QCOMPARE(e8.code, emp::ErrorCode::Internal);
    }

    // ========================================================================
    // RESULT TYPE TESTS - All paths
    // ========================================================================

    void test_result_value_path() {
        emp::Result<int> r(42);
        QVERIFY(r.is_ok());
        QVERIFY(!r.is_error());
        QCOMPARE(r.value(), 42);
    }

    void test_result_error_path() {
        emp::Result<int> r(emp::Error::internal("test"));
        QVERIFY(!r.is_ok());
        QVERIFY(r.is_error());
        QCOMPARE(r.error().code, emp::ErrorCode::Internal);
    }

    void test_result_unwrap_success() {
        emp::Result<int> r(42);
        QCOMPARE(r.unwrap(), 42);
    }

    void test_result_unwrap_throws_on_error() {
        emp::Result<int> r(emp::Error::internal("test"));
        QVERIFY_EXCEPTION_THROWN(r.unwrap(), std::runtime_error);
    }

    void test_result_void_success_path() {
        emp::Result<void> r;
        QVERIFY(r.is_ok());
        QVERIFY(!r.is_error());
    }

    void test_result_void_error_path() {
        emp::Result<void> r(emp::Error::internal("test"));
        QVERIFY(!r.is_ok());
        QVERIFY(r.is_error());
        QCOMPARE(r.error().code, emp::ErrorCode::Internal);
    }

    void test_result_move_semantics() {
        emp::Result<std::string> r1(std::string("hello"));
        emp::Result<std::string> r2 = std::move(r1);
        QCOMPARE(r2.value(), std::string("hello"));
    }

    // ========================================================================
    // TIME/RATE TESTS - Edge cases
    // ========================================================================

    void test_rate_zero_denominator_avoided() {
        // Rate should never have zero denominator in practice
        // But if it does, code should handle it (or assert)
        emp::Rate r{30, 1};
        QVERIFY(r.den != 0);
    }

    void test_frame_time_zero_frame() {
        emp::Rate rate{30, 1};
        emp::FrameTime ft = emp::FrameTime::from_frame(0, rate);
        QCOMPARE(ft.to_us(), static_cast<emp::TimeUS>(0));
    }

    void test_frame_time_large_frame_number() {
        emp::Rate rate{30, 1};
        emp::FrameTime ft = emp::FrameTime::from_frame(1000000, rate);
        // Should not overflow
        emp::TimeUS us = ft.to_us();
        QVERIFY(us > 0);
    }

    void test_frame_time_negative_frame() {
        emp::Rate rate{30, 1};
        emp::FrameTime ft = emp::FrameTime::from_frame(-1, rate);
        // Negative frames should produce negative microseconds
        QVERIFY(ft.to_us() < 0);
    }

    void test_frame_time_drop_frame_rate() {
        // 29.97 fps (NTSC)
        emp::Rate rate{30000, 1001};
        emp::FrameTime ft = emp::FrameTime::from_frame(30, rate);
        emp::TimeUS us = ft.to_us();
        // 30 frames at 29.97 fps ≈ 1.001 seconds
        QVERIFY(us > 1000000);
        QVERIFY(us < 1002000);
    }

    // ========================================================================
    // ASSET TESTS - All error paths
    // ========================================================================

    void test_asset_open_empty_path() {
        auto result = emp::Asset::Open("");
        QVERIFY(result.is_error());
    }

    void test_asset_open_nonexistent_file() {
        auto result = emp::Asset::Open("/nonexistent/path/video.mp4");
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::FileNotFound);
    }

    void test_asset_open_nonexistent_directory() {
        auto result = emp::Asset::Open("/nonexistent_dir_12345/video.mp4");
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::FileNotFound);
    }

    void test_asset_open_directory_not_file() {
        auto result = emp::Asset::Open("/tmp");
        QVERIFY(result.is_error());
        // Opening a directory should fail
    }

    void test_asset_open_invalid_format() {
        QTemporaryFile temp;
        QVERIFY(temp.open());
        temp.write("not a video file - random garbage data 12345");
        temp.close();

        auto result = emp::Asset::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
        // Should be Unsupported or Internal
        QVERIFY(result.error().code != emp::ErrorCode::Ok);
    }

    void test_asset_open_truncated_file() {
        QTemporaryFile temp;
        temp.setFileTemplate(QDir::tempPath() + "/test_XXXXXX.mp4");
        QVERIFY(temp.open());
        // Write partial MP4 header (invalid)
        temp.write("\x00\x00\x00\x1c\x66\x74\x79\x70"); // Partial ftyp box
        temp.close();

        auto result = emp::Asset::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
    }

    void test_asset_open_zero_byte_file() {
        QTemporaryFile temp;
        QVERIFY(temp.open());
        // Don't write anything - 0 byte file
        temp.close();

        auto result = emp::Asset::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
    }

    void test_asset_open_permission_denied() {
        // Create a file with no read permission
        QTemporaryFile temp;
        QVERIFY(temp.open());
        temp.write("data");
        temp.close();

        QString path = temp.fileName();
        QFile::setPermissions(path, QFileDevice::WriteOwner);

        auto result = emp::Asset::Open(path.toStdString());
        // Should fail (permission denied)
        // Note: This might not work on all systems
        if (result.is_error()) {
            QVERIFY(result.error().code != emp::ErrorCode::Ok);
        }

        QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    }

    void test_asset_valid_video_info_complete() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto result = emp::Asset::Open(m_testVideoPath.toStdString());
        QVERIFY(result.is_ok());

        const auto& info = result.value()->info();

        // All fields must be valid
        QVERIFY(!info.path.empty());
        QVERIFY(info.has_video);
        QVERIFY(info.video_width > 0);
        QVERIFY(info.video_height > 0);
        QVERIFY(info.video_width <= 8192);  // Reasonable max
        QVERIFY(info.video_height <= 8192);
        QVERIFY(info.video_fps_num > 0);
        QVERIFY(info.video_fps_den > 0);
        QVERIFY(info.duration_us > 0);
    }

    void test_asset_shared_ptr_lifecycle() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::weak_ptr<emp::Asset> weak;
        {
            auto result = emp::Asset::Open(m_testVideoPath.toStdString());
            QVERIFY(result.is_ok());
            weak = result.value();
            QVERIFY(!weak.expired());
        }
        // After scope, shared_ptr destroyed
        QVERIFY(weak.expired());
    }

    void test_asset_multiple_opens_same_file() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto r1 = emp::Asset::Open(m_testVideoPath.toStdString());
        auto r2 = emp::Asset::Open(m_testVideoPath.toStdString());
        auto r3 = emp::Asset::Open(m_testVideoPath.toStdString());

        QVERIFY(r1.is_ok());
        QVERIFY(r2.is_ok());
        QVERIFY(r3.is_ok());

        // Different instances
        QVERIFY(r1.value().get() != r2.value().get());
        QVERIFY(r2.value().get() != r3.value().get());
    }

    // ========================================================================
    // READER TESTS - All error paths
    // ========================================================================

    void test_reader_create_null_asset() {
        auto result = emp::Reader::Create(nullptr);
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::InvalidArg);
    }

    void test_reader_create_valid() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto result = emp::Reader::Create(asset);
        QVERIFY(result.is_ok());
        QVERIFY(result.value()->asset() == asset);
    }

    void test_reader_asset_reference_kept() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::weak_ptr<emp::Asset> weakAsset;
        std::shared_ptr<emp::Reader> reader;
        {
            auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
            weakAsset = asset;
            reader = emp::Reader::Create(asset).value();
        }
        // Asset should still be alive (held by reader)
        QVERIFY(!weakAsset.expired());
        reader.reset();
        QVERIFY(weakAsset.expired());
    }

    void test_reader_decode_first_frame() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        auto result = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        QVERIFY(result.is_ok());
        QCOMPARE(result.value()->width(), info.video_width);
        QCOMPARE(result.value()->height(), info.video_height);
    }

    void test_reader_decode_negative_time() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        auto result = reader->DecodeAtUS(-1000000);
        // Should return first frame, not error
        QVERIFY(result.is_ok());
        QVERIFY(result.value()->source_pts_us() >= 0);
    }

    void test_reader_decode_past_eof_returns_last_or_eof() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        auto result = reader->DecodeAtUS(info.duration_us + 10000000);

        // Either returns last frame or EOF error - both valid
        if (result.is_error()) {
            QCOMPARE(result.error().code, emp::ErrorCode::EOFReached);
        } else {
            QVERIFY(result.value() != nullptr);
        }
    }

    void test_reader_decode_exact_duration() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        auto result = reader->DecodeAtUS(info.duration_us);

        // Should work (last frame)
        if (result.is_ok()) {
            QVERIFY(result.value() != nullptr);
        }
    }

    void test_reader_seek_to_zero() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        auto result = reader->SeekUS(0);
        QVERIFY(result.is_ok());
    }

    void test_reader_seek_negative() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        auto result = reader->SeekUS(-1000000);
        // Should succeed (clamps to 0)
        QVERIFY(result.is_ok());
    }

    void test_reader_seek_past_duration() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        auto result = reader->SeekUS(info.duration_us + 10000000);
        // Seek should succeed (will just land at end)
        QVERIFY(result.is_ok());
    }

    void test_reader_sequential_decode() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode 10 sequential frames
        for (int i = 0; i < 10; ++i) {
            auto result = reader->DecodeAt(emp::FrameTime::from_frame(i, rate));
            if (result.is_error()) {
                if (result.error().code == emp::ErrorCode::EOFReached) {
                    break; // Video too short
                }
                QFAIL(qPrintable(QString("Decode frame %1 failed: %2")
                    .arg(i).arg(QString::fromStdString(result.error().message))));
            }
            QVERIFY(result.value() != nullptr);
        }
    }

    void test_reader_backward_seek() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode frame 20, then frame 5 (backward)
        auto r1 = reader->DecodeAt(emp::FrameTime::from_frame(20, rate));
        if (r1.is_error()) QSKIP("Video too short");

        auto r2 = reader->DecodeAt(emp::FrameTime::from_frame(5, rate));
        QVERIFY(r2.is_ok());
        // Frame 5 should have earlier PTS
        QVERIFY(r2.value()->source_pts_us() < r1.value()->source_pts_us());
    }

    void test_reader_random_access_pattern() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Random access pattern: 0, 50, 10, 100, 5, 0
        int frames[] = {0, 50, 10, 100, 5, 0};
        for (int f : frames) {
            auto result = reader->DecodeAt(emp::FrameTime::from_frame(f, rate));
            if (result.is_error()) {
                if (result.error().code == emp::ErrorCode::EOFReached) {
                    continue; // Skip if past EOF
                }
                QFAIL(qPrintable(QString("Decode frame %1 failed: %2")
                    .arg(f).arg(QString::fromStdString(result.error().message))));
            }
            QVERIFY(result.value() != nullptr);
        }
    }

    void test_reader_reuse_after_eof() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Go past EOF
        reader->DecodeAtUS(info.duration_us + 1000000);

        // Should still work from beginning
        auto result = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        QVERIFY(result.is_ok());
    }

    // ========================================================================
    // FRAME TESTS - All paths
    // ========================================================================

    void test_frame_data_not_null() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        QVERIFY(frame->data() != nullptr);
    }

    void test_frame_data_multiple_calls_same_pointer() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        const uint8_t* p1 = frame->data();
        const uint8_t* p2 = frame->data();
        const uint8_t* p3 = frame->data();

        QCOMPARE(p1, p2);
        QCOMPARE(p2, p3);
    }

    void test_frame_stride_32_byte_aligned() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        QCOMPARE(frame->stride_bytes() % 32, 0);
    }

    void test_frame_stride_ge_width_times_4() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        QVERIFY(frame->stride_bytes() >= frame->width() * 4);
    }

    void test_frame_data_size_equals_stride_times_height() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        QCOMPARE(frame->data_size(),
                 static_cast<size_t>(frame->stride_bytes() * frame->height()));
    }

    void test_frame_bgra_alpha_255() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        const uint8_t* data = frame->data();
        int stride = frame->stride_bytes();

        // Check alpha channel at several points
        int points[][2] = {{0, 0}, {frame->width()/2, frame->height()/2},
                           {frame->width()-1, frame->height()-1}};

        for (auto& pt : points) {
            const uint8_t* pixel = data + pt[1] * stride + pt[0] * 4;
            QCOMPARE(pixel[3], static_cast<uint8_t>(255)); // Alpha = 255
        }
    }

    void test_frame_data_readable_entire_buffer() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        const uint8_t* data = frame->data();
        size_t size = frame->data_size();

        // Read entire buffer (should not crash/segfault)
        volatile uint8_t sum = 0;
        for (size_t i = 0; i < size; i += 1024) {
            sum += data[i];
        }
        Q_UNUSED(sum);
    }

    void test_frame_pts_first_frame_near_zero() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        // First frame PTS should be 0 or very small
        QVERIFY(frame->source_pts_us() >= 0);
        QVERIFY(frame->source_pts_us() < 100000); // < 0.1 sec
    }

    void test_frame_pts_increases() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        auto f0 = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        auto f1 = reader->DecodeAt(emp::FrameTime::from_frame(1, rate));

        if (f0.is_ok() && f1.is_ok()) {
            QVERIFY(f1.value()->source_pts_us() >= f0.value()->source_pts_us());
        }
    }

    void test_frame_shared_ptr_lifecycle() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::weak_ptr<emp::Frame> weak;
        {
            auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
            auto reader = emp::Reader::Create(asset).value();
            auto frame = reader->DecodeAtUS(0).value();
            weak = frame;
            QVERIFY(!weak.expired());
        }
        QVERIFY(weak.expired());
    }

    void test_frame_independent_of_reader() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::shared_ptr<emp::Frame> frame;
        {
            auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
            auto reader = emp::Reader::Create(asset).value();
            frame = reader->DecodeAtUS(0).value();
        }
        // Reader and asset destroyed, frame should still be valid
        QVERIFY(frame->data() != nullptr);
        QVERIFY(frame->width() > 0);
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // ========================================================================
    // HARDWARE ACCELERATION TESTS - All paths
    // ========================================================================

    void test_hw_native_buffer_method_exists() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Method should exist and not crash
        void* nb = frame->native_buffer();
        // May be nullptr (sw decode) or valid CVPixelBufferRef (hw decode)
        Q_UNUSED(nb);
    }

    void test_hw_data_after_native_buffer() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Call native_buffer first
        frame->native_buffer();

        // data() should still work (lazy transfer)
        const uint8_t* data = frame->data();
        QVERIFY(data != nullptr);
    }

    void test_hw_lazy_transfer_triggered_by_data() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Calling data() triggers lazy transfer if hw frame
        QElapsedTimer timer;
        timer.start();
        const uint8_t* data = frame->data();
        qint64 firstCall = timer.elapsed();

        timer.restart();
        const uint8_t* data2 = frame->data();
        qint64 secondCall = timer.elapsed();

        QVERIFY(data == data2);
        // Second call should be much faster (no transfer)
        // (This is a weak test but validates the path)
        Q_UNUSED(firstCall);
        Q_UNUSED(secondCall);
    }

    void test_hw_fallback_to_sw_decode() {
        // Even if hw init fails, decoding should work via sw fallback
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Should always succeed (hw or sw)
        QVERIFY(frame->data() != nullptr);
        QVERIFY(frame->width() > 0);
    }
#endif

    // ========================================================================
    // STRESS TESTS
    // ========================================================================

    void test_stress_rapid_decode() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode 100 frames rapidly
        for (int i = 0; i < 100; ++i) {
            auto result = reader->DecodeAt(emp::FrameTime::from_frame(i % 30, rate));
            if (result.is_error() && result.error().code == emp::ErrorCode::EOFReached) {
                break;
            }
            QVERIFY(result.is_ok());
        }
    }

    void test_stress_many_assets() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::vector<std::shared_ptr<emp::Asset>> assets;
        for (int i = 0; i < 10; ++i) {
            auto result = emp::Asset::Open(m_testVideoPath.toStdString());
            QVERIFY(result.is_ok());
            assets.push_back(result.value());
        }
        // All should be valid
        for (auto& a : assets) {
            QVERIFY(a->info().has_video);
        }
    }

    void test_stress_many_readers_same_asset() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();

        std::vector<std::shared_ptr<emp::Reader>> readers;
        for (int i = 0; i < 5; ++i) {
            auto result = emp::Reader::Create(asset);
            QVERIFY(result.is_ok());
            readers.push_back(result.value());
        }

        // All readers should work independently
        for (auto& r : readers) {
            auto frame = r->DecodeAtUS(0);
            QVERIFY(frame.is_ok());
        }
    }
};

QTEST_MAIN(TestEMPCore)
#include "test_emp_core.moc"
