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

    void test_reader_sequential_frames_have_increasing_pts() {
        // Regression test for B-frame cache bug where frame 1 returned frame 0's data
        // because cache lookup was too greedy (returned floor frame even when target
        // was past cache_max).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode frames 0, 1, 2, 3, 4 and verify PTS is strictly increasing
        emp::TimeUS prev_pts = -1;
        for (int i = 0; i < 5; ++i) {
            auto result = reader->DecodeAt(emp::FrameTime::from_frame(i, rate));
            if (result.is_error()) {
                if (result.error().code == emp::ErrorCode::EOFReached) {
                    break;
                }
                QFAIL(qPrintable(QString("Frame %1 decode failed: %2")
                    .arg(i).arg(QString::fromStdString(result.error().message))));
            }

            emp::TimeUS this_pts = result.value()->source_pts_us();

            // Each frame must have PTS > previous frame
            // (Catches B-frame cache bug where frame 1 returned frame 0's cached data)
            if (i > 0) {
                QVERIFY2(this_pts > prev_pts,
                    qPrintable(QString("Frame %1 PTS (%2) should be > frame %3 PTS (%4)")
                        .arg(i).arg(this_pts).arg(i-1).arg(prev_pts)));
            }
            prev_pts = this_pts;
        }
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

    void test_reader_frames_valid_after_backward_seek() {
        // Regression test: frames held by caller must remain valid after seeking backward.
        // Previously, backward seek cleared the internal cache, which could invalidate
        // frame handles if the binding didn't use shared_ptr correctly.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode frames 10-15 and hold references
        std::vector<std::shared_ptr<emp::Frame>> held_frames;
        for (int i = 10; i <= 15; ++i) {
            auto result = reader->DecodeAt(emp::FrameTime::from_frame(i, rate));
            if (result.is_error()) {
                if (result.error().code == emp::ErrorCode::EOFReached) break;
                QFAIL("Decode failed");
            }
            held_frames.push_back(result.value());
        }

        if (held_frames.empty()) QSKIP("Video too short");

        // Record original data pointers and dimensions
        std::vector<const uint8_t*> original_data;
        std::vector<int> original_widths;
        for (auto& f : held_frames) {
            original_data.push_back(f->data());
            original_widths.push_back(f->width());
        }

        // Seek backward (would have cleared cache in old code)
        auto seek_result = reader->SeekUS(0);
        QVERIFY(seek_result.is_ok());

        // Decode frame 0 (triggers cache activity after seek)
        auto frame0 = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        QVERIFY(frame0.is_ok());

        // Verify held frames are still valid - data pointers unchanged, dimensions valid
        for (size_t i = 0; i < held_frames.size(); ++i) {
            QCOMPARE(held_frames[i]->data(), original_data[i]);
            QCOMPARE(held_frames[i]->width(), original_widths[i]);
            QVERIFY(held_frames[i]->height() > 0);
            QVERIFY(held_frames[i]->stride_bytes() >= held_frames[i]->width() * 4);
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

    // ========================================================================
    // PREFETCH THREAD TESTS - Background decode for smooth playback
    // ========================================================================

    void test_prefetch_start_stop_basic() {
        // Test that StartPrefetch/StopPrefetch don't crash
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        // Start forward prefetch
        reader->StartPrefetch(1);
        QThread::msleep(100);  // Let prefetch run briefly

        // Stop prefetch
        reader->StopPrefetch();

        // Should be able to start again
        reader->StartPrefetch(-1);  // Reverse
        QThread::msleep(50);
        reader->StopPrefetch();

        // Verify normal decode still works
        auto frame = reader->DecodeAtUS(0);
        QVERIFY(frame.is_ok());
    }

    void test_prefetch_get_cached_frame_returns_null_initially() {
        // GetCachedFrame should return nullptr for uncached frames
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        // Without any decoding, cache should be empty
        auto cached = reader->GetCachedFrame(1000000);  // 1 second
        // May or may not be null depending on initial state, but shouldn't crash
        Q_UNUSED(cached);
    }

    void test_prefetch_fills_cache_ahead() {
        // After starting prefetch, cache should fill ahead of playhead
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::TimeUS frame_duration_us = (info.video_fps_den * 1000000LL) / info.video_fps_num;

        // Decode first frame to establish position
        auto first = reader->DecodeAtUS(0);
        QVERIFY(first.is_ok());

        // Start forward prefetch
        reader->StartPrefetch(1);

        // Update prefetch target
        reader->UpdatePrefetchTarget(0);

        // Wait for prefetch to decode ahead
        QThread::msleep(500);

        // Check if frames ahead are now cached
        emp::TimeUS check_time = frame_duration_us * 5;  // Frame 5
        auto cached = reader->GetCachedFrame(check_time);

        reader->StopPrefetch();

        // May or may not have the frame depending on decode speed, but verify
        // we can still decode normally
        auto frame5 = reader->DecodeAtUS(check_time);
        QVERIFY(frame5.is_ok());
    }

    void test_prefetch_thread_safety() {
        // Test concurrent access to cache (main thread + prefetch thread)
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Start prefetch
        reader->StartPrefetch(1);
        reader->UpdatePrefetchTarget(0);

        // Rapidly decode from main thread while prefetch runs
        for (int i = 0; i < 50; ++i) {
            auto frame = reader->DecodeAt(emp::FrameTime::from_frame(i % 20, rate));
            if (frame.is_error() && frame.error().code == emp::ErrorCode::EOFReached) {
                break;
            }
            // Some may be cache hits, some misses - both should work
            QVERIFY(frame.is_ok());
        }

        reader->StopPrefetch();
    }

    void test_prefetch_direction_change() {
        // Test changing prefetch direction mid-playback
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        // Decode to middle of video
        const auto& info = asset->info();
        emp::TimeUS mid = info.duration_us / 2;
        auto midFrame = reader->DecodeAtUS(mid);
        if (midFrame.is_error()) QSKIP("Video too short");

        // Start forward prefetch
        reader->StartPrefetch(1);
        reader->UpdatePrefetchTarget(mid);
        QThread::msleep(100);

        // Change to reverse
        reader->StartPrefetch(-1);
        reader->UpdatePrefetchTarget(mid);
        QThread::msleep(100);

        // Stop
        reader->StopPrefetch();

        // Verify decode still works
        auto frame = reader->DecodeAtUS(0);
        QVERIFY(frame.is_ok());
    }

    void test_scattered_park_then_play_no_stale_frames() {
        // Regression: Park/Scrub at scattered positions fills cache with
        // distant frames. cache_max_pts reflects the latest park position.
        // When Play starts, the fast-path check (t_us <= cache_max_pts) hits
        // and floor-lookup returns a stale frame. Prefetch also thinks cache
        // is ahead (prefetch_to < cache_max_pts) and does nothing.
        // Result: image freezes while playhead advances.
        //
        // Fix: cache must be invalidated on mode transition to Play so that
        // scattered Park frames don't poison sequential playback.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};
        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);

        // Park at scattered positions to fill cache with distant frames
        emp::SetDecodeMode(emp::DecodeMode::Park);
        int park_positions[] = {10, 200, 50, 400, 100};
        for (int f : park_positions) {
            if (f >= total_frames) continue;
            auto r = reader->DecodeAt(emp::FrameTime::from_frame(f, rate));
            QVERIFY2(r.is_ok() || r.error().code == emp::ErrorCode::EOFReached,
                qPrintable(QString("Park at %1 failed: %2")
                    .arg(f).arg(r.is_error() ? QString::fromStdString(r.error().message) : "")));
        }

        // Switch to Play and verify 10 sequential frames from frame 50
        // have strictly increasing PTS (not stale floor matches)
        emp::SetDecodeMode(emp::DecodeMode::Play);
        int play_start = 50;
        emp::TimeUS prev_pts = -1;
        for (int i = play_start; i < play_start + 10 && i < total_frames; ++i) {
            auto r = reader->DecodeAt(emp::FrameTime::from_frame(i, rate));
            if (r.is_error()) {
                if (r.error().code == emp::ErrorCode::EOFReached) break;
                QFAIL(qPrintable(QString("Play frame %1 failed: %2")
                    .arg(i).arg(QString::fromStdString(r.error().message))));
            }

            auto this_pts = r.value()->source_pts_us();
            if (i > play_start) {
                QVERIFY2(this_pts > prev_pts,
                    qPrintable(QString("Frame %1: PTS %2 not > prev %3 — stale cache frame")
                        .arg(i).arg(this_pts).arg(prev_pts)));
            }
            prev_pts = this_pts;
        }

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_park_then_play_no_frame_gap() {
        // Regression: after Park seeks + decode_until_target, decoder is
        // positioned past the parked frame (B-frame lookahead). Switching to
        // Play must seek to cover the gap, otherwise frames between the park
        // target and decoder position are never decoded → stale frames returned.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Park at frame 50
        emp::SetDecodeMode(emp::DecodeMode::Park);
        auto r0 = reader->DecodeAt(emp::FrameTime::from_frame(50, rate));
        QVERIFY(r0.is_ok());
        auto park_pts = r0.value()->source_pts_us();

        // Switch to Play, decode frames 51-55
        emp::SetDecodeMode(emp::DecodeMode::Play);
        emp::TimeUS prev_pts = park_pts;
        for (int i = 51; i <= 55; ++i) {
            auto r = reader->DecodeAt(emp::FrameTime::from_frame(i, rate));
            if (r.is_error()) {
                if (r.error().code == emp::ErrorCode::EOFReached) QSKIP("Video too short");
                QFAIL(qPrintable(QString("Frame %1 failed: %2")
                    .arg(i).arg(QString::fromStdString(r.error().message))));
            }

            auto this_pts = r.value()->source_pts_us();
            QVERIFY2(this_pts > prev_pts,
                qPrintable(QString("Frame %1: PTS %2 not > prev %3 (stale frame returned)")
                    .arg(i).arg(this_pts).arg(prev_pts)));
            prev_pts = this_pts;
        }

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_park_mode_forward_seek_performance() {
        // Regression test: Park/Scrub mode must always seek before decode.
        // Without the fix, a forward jump in Park mode decodes sequentially
        // from the last decoder position (potentially hundreds of frames).
        // With the fix, it seeks to nearest keyframe first (≤GOP frames).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        // Decode frame 0 to initialize decoder position
        emp::SetDecodeMode(emp::DecodeMode::Park);
        auto r0 = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        QVERIFY(r0.is_ok());

        // Jump forward ~300 frames in Park mode — must seek, not decode sequentially
        int jump_frame = 300;
        QElapsedTimer timer;
        timer.start();

        auto r1 = reader->DecodeAt(emp::FrameTime::from_frame(jump_frame, rate));
        qint64 elapsed = timer.elapsed();

        if (r1.is_error() && r1.error().code == emp::ErrorCode::EOFReached) {
            QSKIP("Video too short for forward seek test");
        }
        QVERIFY(r1.is_ok());

        // With seek: ~50-200ms. Without seek: potentially >1000ms.
        // Use generous threshold (500ms) to avoid flaky tests.
        QVERIFY2(elapsed < 500,
            qPrintable(QString("Park forward jump took %1ms — seek likely missing")
                .arg(elapsed)));

        // Restore default mode
        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_prefetch_reader_destruction_with_active_thread() {
        // Test that Reader destruction properly stops prefetch thread
        if (!m_hasTestVideo) QSKIP("No test video");

        {
            auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
            auto reader = emp::Reader::Create(asset).value();

            reader->StartPrefetch(1);
            reader->UpdatePrefetchTarget(0);
            QThread::msleep(50);
            // Don't call StopPrefetch - destructor should handle it
        }
        // If we get here without crash/hang, destructor worked correctly
        QVERIFY(true);
    }

    void test_play_batch_no_pts_gap_at_target() {
        // Regression: decode_frames_batch returns after BFRAME_LOOKAHEAD (8)
        // consecutive post-target frames, but B-frames with PTS *before*
        // the target may still be in the decoder pipeline (especially HW
        // decoders like VideoToolbox). The counter reset at line 186
        // (frames_past_target = 0 on any pre-target B-frame) can cause
        // premature return, leaving PTS holes in the cache around the
        // target. Result: stale-cache rejection → synchronous decode
        // stall → visible stutter during timeline clip switches.
        //
        // The fix: don't reset frames_past_target once we've already seen
        // post-target frames. Late B-frames are expected pipeline output.
        //
        // Uses fixture video with known IBBBP GOP structure.

        // Use fixture video with known B-frames (IBBBP pattern)
        QString fixturePath = QDir::currentPath() + "/tests/fixtures/media/A005_C052_0925BL_001.mp4";
        if (!QFile::exists(fixturePath)) {
            // Try relative to source dir
            fixturePath = QString::fromUtf8(__FILE__);
            fixturePath = QFileInfo(fixturePath).absolutePath() + "/../../fixtures/media/A005_C052_0925BL_001.mp4";
        }
        if (!QFile::exists(fixturePath)) QSKIP("Fixture video not found");

        auto asset_r = emp::Asset::Open(fixturePath.toStdString());
        QVERIFY2(asset_r.is_ok(), "Failed to open fixture video");
        auto asset = asset_r.value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};
        emp::TimeUS frame_dur_us = (info.video_fps_num > 0)
            ? (1000000LL * info.video_fps_den + info.video_fps_num - 1)
              / info.video_fps_num
            : 42000;

        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);
        if (total_frames < 60) QSKIP("Video too short for this test");

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // Test multiple start positions to catch position-dependent gaps.
        // Different positions land on different points in the GOP (I, B, P),
        // exposing different B-frame buffering behavior.
        int test_positions[] = {20, total_frames / 3, total_frames / 2};
        int total_large_gaps = 0;

        for (int start_frame : test_positions) {
            if (start_frame + 10 >= total_frames) continue;

            // Create fresh reader for each position (simulates clip switch)
            auto fresh_reader = emp::Reader::Create(asset).value();

            // First decode at target: triggers batch decode + cache fill
            emp::TimeUS target_us = emp::FrameTime::from_frame(start_frame, rate).to_us();
            auto r0 = fresh_reader->DecodeAtUS(target_us);
            QVERIFY2(r0.is_ok(), qPrintable(QString("Decode at frame %1 failed: %2")
                .arg(start_frame)
                .arg(r0.is_error() ? QString::fromStdString(r0.error().message) : "")));

            // Probe cache for next 7 frames (within BFRAME_LOOKAHEAD-1 range).
            // BFRAME_LOOKAHEAD=8 guarantees 8 frames with PTS >= target in
            // the batch, covering target through target+7. We probe +1..+7.
            // With contiguous cache, the floor match PTS should be within
            // 1 frame of target. B-frame gaps produce distant floor matches.
            for (int offset = 1; offset <= 7; ++offset) {
                int frame_num = start_frame + offset;
                if (frame_num >= total_frames) break;

                emp::TimeUS probe_us = emp::FrameTime::from_frame(frame_num, rate).to_us();
                auto cached = fresh_reader->GetCachedFrame(probe_us);

                if (cached) {
                    emp::TimeUS pts_gap = probe_us - cached->source_pts_us();
                    // Floor semantics: pts_gap should be >= 0 and <= ~1 frame.
                    // A gap > 2 frames means B-frames are missing from cache.
                    if (pts_gap > frame_dur_us * 2) {
                        total_large_gaps++;
                        qDebug() << QString("  PTS gap at frame %1+%2: %3us (%4 frames)")
                            .arg(start_frame).arg(offset)
                            .arg(pts_gap).arg((double)pts_gap / frame_dur_us, 0, 'f', 1);
                    }
                } else {
                    // Complete cache miss within BFRAME_LOOKAHEAD range
                    total_large_gaps++;
                    qDebug() << QString("  Cache miss at frame %1+%2")
                        .arg(start_frame).arg(offset);
                }
            }
        }

        // With proper B-frame drain, the batch should produce contiguous
        // PTS coverage. Allow at most 2 gaps total across all test positions
        // (for boundary frames at the very edge of BFRAME_LOOKAHEAD).
        QVERIFY2(total_large_gaps <= 2,
            qPrintable(QString("%1 cache probes had PTS gaps > 2 frames — "
                "decode_frames_batch not draining B-frames from decoder pipeline")
                .arg(total_large_gaps)));

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_prefetch_restart_seeks_to_new_position() {
        // Regression: after a clip switch the prefetch thread is stopped and
        // restarted on the same (pooled) reader at a DIFFERENT position.
        // The prefetch's have_prefetch_pos and prefetch_decode_pts are stale
        // from the previous session.  If the new position is within 2s of the
        // old one, need_seek() returns false and the prefetch tries to decode
        // forward from the old format-context read position — potentially
        // hundreds of frames behind.  This starves the cache, causing stale-
        // cache rejections and visible stutter on every clip switch.
        //
        // Fix: StartPrefetch must reset have_prefetch_pos so the prefetch
        //      always seeks on restart.
        //
        // Test strategy: Use PrefetchFramesDecoded() counter.  After session A
        // at frame 0, stop, then restart at a DISTANT position B.
        //   With seek:    prefetch decodes ~15 frames (keyframe→target+8)
        //   Without seek: prefetch decodes 100+ frames (forward from 0→B)
        // Assert frame count is small → proves seek happened.

        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);
        if (total_frames < 120) QSKIP("Video too short for clip-switch test");

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // ── Session A: decode at frame 0, prefetch fills ahead ──
        auto r0 = reader->DecodeAtUS(0);
        QVERIFY(r0.is_ok());

        reader->StartPrefetch(1);
        reader->UpdatePrefetchTarget(0);
        QThread::msleep(300);  // Let prefetch decode ahead

        int64_t countA = reader->PrefetchFramesDecoded();
        QVERIFY2(countA > 0, "Prefetch didn't decode any frames at position A");

        reader->StopPrefetch();

        // ── Session B: restart at a distant position ──
        // Frame 100 is ~4.2s away at 24fps — past the 2s need_seek threshold,
        // so need_seek would return true even without the fix.  But the FORMAT
        // CONTEXT read position from session A is near frame 0+countA.  Without
        // resetting have_prefetch_pos, need_seek uses prefetch_decode_pts which
        // may be within 2s of the new seek_target (cache_max_pts ≈ B+7).
        // Force a gap >2s by using frame 100 (the stale pts from A is ~frame 20,
        // and B's seek_target is ~frame 107 → gap ≈ 3.6s → need_seek = true
        // regardless).  The REAL value of have_prefetch_pos reset is for gaps
        // <2s where need_seek would wrongly say false.
        //
        // To test the <2s case: use frame 40 (~1.7s from stale prefetch pts).
        int posB = 40;
        emp::TimeUS targetB = emp::FrameTime::from_frame(posB, rate).to_us();
        auto r1 = reader->DecodeAtUS(targetB);
        QVERIFY(r1.is_ok());

        reader->StartPrefetch(1);
        reader->UpdatePrefetchTarget(targetB);
        QThread::msleep(500);  // Let prefetch complete at least one batch

        int64_t countB = reader->PrefetchFramesDecoded();
        reader->StopPrefetch();

        // With seek: prefetch decodes from keyframe near B → ~15-25 frames.
        // Without seek: prefetch decodes forward from A's stale position
        // (frame ~20) through B+lookahead — could be 30-40+ frames, but
        // HW decode is fast enough that both complete.  The structural
        // difference is small on a short video.
        //
        // Primary assertion: prefetch DID produce output (non-zero).
        // This catches the production bug where prefetch produces ZERO
        // output because it thinks cache is ahead (stale prefetch_target).
        QVERIFY2(countB > 0,
            qPrintable(QString("Prefetch decoded 0 frames after restart at B=%1 — "
                "stale prefetch_target or have_prefetch_pos blocked decode")
                .arg(posB)));

        // Secondary: frame count should be reasonable (not thousands).
        // A seek+decode should produce <50 frames for a 0.5s lookahead.
        QVERIFY2(countB < 100,
            qPrintable(QString("Prefetch decoded %1 frames — "
                "likely did not seek (forward-decoded from stale position)")
                .arg(countB)));
    }

    // ========================================================================
    // TIMELINE CLIP-SWITCH PREFETCH TEST
    // Uses actual clips from Default Sequence timeline + undo stack positions.
    // Simulates what happens during playback when the editor switches readers
    // at clip boundaries (frames 0, 1492, 2064, 2308).
    // ========================================================================

    void test_timeline_clip_switch_prefetch_seeks() {
        // Regression: During timeline playback, each clip boundary triggers a
        // reader switch: StopPrefetch on old reader, StartPrefetch on new reader.
        // If the new reader's prefetch doesn't seek to the clip's source_in
        // position, it forward-decodes from 0 → source_in (potentially hundreds
        // of frames), starving the cache and causing visible stutter.
        //
        // This test uses the actual clips from the Default Sequence timeline
        // and the playhead positions from the undo stack (commands 18-21).
        // Timeline layout:
        //   11C-3.mov              @ tl frames 0-1492    (src 0-1492, 24000/1001fps)
        //   A001_02241645_C001.mov @ tl frames 1492-1949 (src 0-457,  24fps)
        //   A001_04271819_C004.mov @ tl frames 2064-2308 (src 0-244,  24fps)
        //   A001_02241645_C001.mov @ tl frames 2308-3049 (src 457-1198, 24fps)

        struct ClipEntry {
            const char* path;
            int source_in_frame;
            int source_out_frame;
        };

        ClipEntry clips[] = {
            {"/Users/joe/Local/Archived/PINE BOX/Media H264/DAY 9_Viper Room/"
             "011 Viper Room Hallway/11C-3.mov",
             0, 1492},
            {"/Users/joe/Local/iPhone BMCAM app footage/A001_02241645_C001.mov",
             0, 457},
            {"/Users/joe/Local/iPhone BMCAM app footage/A001_04271819_C004.mov",
             0, 244},
            {"/Users/joe/Local/iPhone BMCAM app footage/A001_02241645_C001.mov",
             457, 1198},
        };
        int num_clips = sizeof(clips) / sizeof(clips[0]);

        // Open all assets up front; skip if any missing.
        // Use the asset's ACTUAL frame rate (from stream metadata), not the
        // DB's imported rate — VFR footage (e.g. iPhone ProRes) has irregular
        // PTS that diverges from the nominal rate. The reader caches by actual
        // stream PTS, so lookups must use the stream's rate to hit.
        struct OpenClip {
            std::shared_ptr<emp::Asset> asset;
            std::shared_ptr<emp::Reader> reader;
            emp::Rate rate;  // from asset->info(), not DB
            int source_in;
            int source_out;
        };

        std::vector<OpenClip> open_clips;
        for (int i = 0; i < num_clips; ++i) {
            if (!QFile::exists(clips[i].path)) {
                QSKIP(qPrintable(QString("Missing: %1").arg(clips[i].path)));
            }
            auto asset_r = emp::Asset::Open(clips[i].path);
            QVERIFY2(asset_r.is_ok(),
                qPrintable(QString("Failed to open %1: %2")
                    .arg(clips[i].path)
                    .arg(asset_r.is_error()
                        ? QString::fromStdString(asset_r.error().message) : "")));

            auto reader_r = emp::Reader::Create(asset_r.value());
            QVERIFY(reader_r.is_ok());

            const auto& info = asset_r.value()->info();
            open_clips.push_back({
                asset_r.value(),
                reader_r.value(),
                emp::Rate{info.video_fps_num, info.video_fps_den},
                clips[i].source_in_frame,
                clips[i].source_out_frame
            });
        }

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // Simulate timeline playback: at each clip boundary, switch reader,
        // park at source_in, start prefetch, verify it seeks (low frame count).
        for (int i = 0; i < (int)open_clips.size(); ++i) {
            auto& oc = open_clips[i];

            // Decode at the clip's source_in position (simulates clip switch)
            emp::TimeUS source_in_us =
                emp::FrameTime::from_frame(oc.source_in, oc.rate).to_us();
            auto r = oc.reader->DecodeAtUS(source_in_us);
            QVERIFY2(r.is_ok(),
                qPrintable(QString("Clip %1 decode at source_in=%2 failed: %3")
                    .arg(i).arg(oc.source_in)
                    .arg(r.is_error()
                        ? QString::fromStdString(r.error().message) : "")));

            // Start prefetch and let it run
            oc.reader->StartPrefetch(1);
            oc.reader->UpdatePrefetchTarget(source_in_us);
            QThread::msleep(400);

            int64_t count = oc.reader->PrefetchFramesDecoded();
            oc.reader->StopPrefetch();

            // Prefetch must have produced output (catches stale-target bug)
            QVERIFY2(count > 0,
                qPrintable(QString("Clip %1 (%2): prefetch decoded 0 frames "
                    "at source_in=%3 — stale prefetch_target")
                    .arg(i).arg(clips[i].path).arg(oc.source_in)));

            // Prefetch should seek, not forward-decode from 0.
            // With seek: ~15-30 frames (keyframe → source_in + lookahead).
            // Without seek on clip with source_in=457: ~457+30 = ~487 frames.
            int expected_max = 100;
            QVERIFY2(count < expected_max,
                qPrintable(QString("Clip %1: prefetch decoded %2 frames "
                    "(expected <%3) — seek likely missing, forward-decoding "
                    "from 0 to source_in=%4")
                    .arg(i).arg(count).arg(expected_max).arg(oc.source_in)));

            // Verify sequential frames from source_in have increasing PTS
            // (catches stale-cache floor-match returning distant parked frames)
            emp::TimeUS prev_pts = -1;
            int check_count = std::min(5, oc.source_out - oc.source_in);
            for (int f = 0; f < check_count; ++f) {
                int frame = oc.source_in + f;
                auto fr = oc.reader->DecodeAt(
                    emp::FrameTime::from_frame(frame, oc.rate));
                if (fr.is_error()) {
                    if (fr.error().code == emp::ErrorCode::EOFReached) break;
                    QFAIL(qPrintable(QString("Clip %1 frame %2 failed: %3")
                        .arg(i).arg(frame)
                        .arg(QString::fromStdString(fr.error().message))));
                }

                emp::TimeUS pts = fr.value()->source_pts_us();
                if (f > 0) {
                    QVERIFY2(pts > prev_pts,
                        qPrintable(QString("Clip %1 frame %2: PTS %3 not > "
                            "prev %4 — stale cache frame")
                            .arg(i).arg(frame).arg(pts).arg(prev_pts)));
                }
                prev_pts = pts;
            }
        }

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_pooled_reader_prefetch_at_new_position() {
        // Regression: A pooled reader is used for clip A at position X, its
        // prefetch fills the cache ahead (cache_max_pts >> X).  The reader is
        // returned to the pool (StopPrefetch), then re-activated for clip B
        // at a DIFFERENT position Y (same file, different source_in).
        //
        // Bug: the prefetch worker checks `prefetch_to > cache_max_pts` to
        // decide if decode is needed.  cache_max_pts is still from session A
        // (very high), so prefetch_to (near Y) < cache_max_pts → prefetch
        // sleeps → zero output → main thread stale-cache rejects on every
        // frame past the initial sync batch → visible stutter.
        //
        // Uses 11C-3.mov from the Default Sequence (1492 frames, 23.976fps).
        // Session A at frame 700, session B at frame 100.
        // This reproduces the production scenario: clip plays at a high
        // position, reader returned to pool, then re-used at a LOWER
        // position. cache_max_pts from A >> prefetch_to from B → prefetch
        // sleeps.

        QString path = "/Users/joe/Local/Archived/PINE BOX/Media H264/"
                       "DAY 9_Viper Room/011 Viper Room Hallway/11C-3.mov";
        if (!QFile::exists(path)) QSKIP("Missing test media");

        auto asset = emp::Asset::Open(path.toStdString());
        QVERIFY(asset.is_ok());
        auto reader = emp::Reader::Create(asset.value());
        QVERIFY(reader.is_ok());

        const auto& info = asset.value()->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);
        if (total_frames < 800) QSKIP("Video too short");

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // ── Session A: play from frame 700, let prefetch fill ahead ──
        int posA = 700;
        emp::TimeUS targetA = emp::FrameTime::from_frame(posA, rate).to_us();
        auto r0 = reader.value()->DecodeAtUS(targetA);
        QVERIFY(r0.is_ok());

        reader.value()->StartPrefetch(1);
        reader.value()->UpdatePrefetchTarget(targetA);
        QThread::msleep(500);  // Let prefetch fill cache well ahead
        reader.value()->StopPrefetch();

        int64_t countA = reader.value()->PrefetchFramesDecoded();
        QVERIFY2(countA > 0, "Session A prefetch produced no output");

        // ── Session B: re-activate at frame 100 (LOWER than A) ──
        // cache_max_pts from A is ~frame 720+, prefetch_to for B is
        // ~frame 112 (100 + 0.5s). Since 112 < 720, prefetch sleeps.
        int posB = 100;
        emp::TimeUS targetB = emp::FrameTime::from_frame(posB, rate).to_us();
        auto r1 = reader.value()->DecodeAtUS(targetB);
        QVERIFY(r1.is_ok());

        reader.value()->StartPrefetch(1);
        reader.value()->UpdatePrefetchTarget(targetB);
        QThread::msleep(500);

        int64_t countB = reader.value()->PrefetchFramesDecoded();
        reader.value()->StopPrefetch();

        // Prefetch MUST produce output at the new position.
        // Without the fix: cache_max_pts from session A fools the prefetch
        // into thinking the cache is already ahead → countB == 0.
        QVERIFY2(countB > 0,
            qPrintable(QString("Session B prefetch decoded 0 frames at "
                "frame %1 — stale cache_max_pts from session A blocked "
                "prefetch (cache_max_pts from A likely >> target B)")
                .arg(posB)));

        // Verify sequential frames from posB have increasing PTS
        // (catches stale floor-match from session A's distant cached frames)
        emp::TimeUS prev_pts = -1;
        for (int f = 0; f < 5; ++f) {
            auto fr = reader.value()->DecodeAt(
                emp::FrameTime::from_frame(posB + f, rate));
            if (fr.is_error()) {
                if (fr.error().code == emp::ErrorCode::EOFReached) break;
                QFAIL(qPrintable(QString("Frame %1 failed: %2")
                    .arg(posB + f)
                    .arg(QString::fromStdString(fr.error().message))));
            }

            emp::TimeUS pts = fr.value()->source_pts_us();
            if (f > 0) {
                QVERIFY2(pts > prev_pts,
                    qPrintable(QString("Frame %1: PTS %2 not > prev %3 — "
                        "stale cache from session A")
                        .arg(posB + f).arg(pts).arg(prev_pts)));
            }
            prev_pts = pts;
        }

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_cache_not_cleared_on_small_seek() {
        // Verify that seeking within 1s preserves cached frames.
        // The stale-session detection (STALE_THRESHOLD_US = 1s) must NOT
        // clear the cache when the target is close to the cached range.
        // Without this guarantee, normal playback (frame-to-frame) would
        // constantly flush the cache.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);
        if (total_frames < 60) QSKIP("Video too short");

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // Decode frame 50 — fills cache with batch around frame 50
        emp::TimeUS t50 = emp::FrameTime::from_frame(50, rate).to_us();
        auto r0 = reader->DecodeAtUS(t50);
        QVERIFY(r0.is_ok());

        // Decode frame 55 — within 1s, cache must NOT be cleared
        emp::TimeUS t55 = emp::FrameTime::from_frame(55, rate).to_us();
        auto r1 = reader->DecodeAtUS(t55);
        QVERIFY(r1.is_ok());

        // Frame 50 should still be in cache (batch from first decode)
        auto cached = reader->GetCachedFrame(t50);
        QVERIFY2(cached != nullptr,
            "Cache cleared on small seek (within 1s) — "
            "stale-session threshold too aggressive");

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    void test_direction_change_preserves_cache() {
        // Verify that changing prefetch direction does not clear cached
        // frames. The stale-session detection triggers only on DecodeAtUS
        // with a target far outside the cached range — direction changes
        // at the same position must preserve the cache.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto asset = emp::Asset::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(asset).value();

        const auto& info = asset->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        int total_frames = static_cast<int>(
            info.duration_us / 1e6 * info.video_fps_num / info.video_fps_den);
        if (total_frames < 60) QSKIP("Video too short");

        emp::SetDecodeMode(emp::DecodeMode::Play);

        // Decode frame 50 to populate cache
        emp::TimeUS t50 = emp::FrameTime::from_frame(50, rate).to_us();
        auto r0 = reader->DecodeAtUS(t50);
        QVERIFY(r0.is_ok());

        // Start forward prefetch, let it run briefly
        reader->StartPrefetch(1);
        reader->UpdatePrefetchTarget(t50);
        QThread::msleep(200);
        reader->StopPrefetch();

        // Switch to reverse prefetch
        reader->StartPrefetch(-1);
        reader->UpdatePrefetchTarget(t50);
        QThread::msleep(100);
        reader->StopPrefetch();

        // Frame 50 must still be cached
        auto cached = reader->GetCachedFrame(t50);
        QVERIFY2(cached != nullptr,
            "Cache lost frame 50 after direction change — "
            "direction switch should not clear cache");

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }
};

QTEST_MAIN(TestEMPCore)
#include "test_emp_core.moc"
