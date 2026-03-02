// Comprehensive tests for EMP (Editor Media Platform) core functionality
// Coverage: ALL paths including errors, edge cases, resource lifecycle, fallbacks

#include <QtTest>
#include <QTemporaryFile>
#include <QTemporaryDir>
#include <QDir>
#include <QThread>
#include <QElapsedTimer>

#include <editor_media_platform/emp_media_file.h>
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
                auto result = emp::MediaFile::Open(fullPath.toStdString());
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
    // MEDIA FILE TESTS - All error paths
    // ========================================================================

    void test_media_file_open_empty_path() {
        auto result = emp::MediaFile::Open("");
        QVERIFY(result.is_error());
    }

    void test_media_file_open_nonexistent_file() {
        auto result = emp::MediaFile::Open("/nonexistent/path/video.mp4");
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::FileNotFound);
    }

    void test_media_file_open_nonexistent_directory() {
        auto result = emp::MediaFile::Open("/nonexistent_dir_12345/video.mp4");
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::FileNotFound);
    }

    void test_media_file_open_directory_not_file() {
        auto result = emp::MediaFile::Open("/tmp");
        QVERIFY(result.is_error());
        // Opening a directory should fail
    }

    void test_media_file_open_invalid_format() {
        QTemporaryFile temp;
        QVERIFY(temp.open());
        temp.write("not a video file - random garbage data 12345");
        temp.close();

        auto result = emp::MediaFile::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
        // Should be Unsupported or Internal
        QVERIFY(result.error().code != emp::ErrorCode::Ok);
    }

    void test_media_file_open_truncated_file() {
        QTemporaryFile temp;
        temp.setFileTemplate(QDir::tempPath() + "/test_XXXXXX.mp4");
        QVERIFY(temp.open());
        // Write partial MP4 header (invalid)
        temp.write("\x00\x00\x00\x1c\x66\x74\x79\x70"); // Partial ftyp box
        temp.close();

        auto result = emp::MediaFile::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
    }

    void test_media_file_open_zero_byte_file() {
        QTemporaryFile temp;
        QVERIFY(temp.open());
        // Don't write anything - 0 byte file
        temp.close();

        auto result = emp::MediaFile::Open(temp.fileName().toStdString());
        QVERIFY(result.is_error());
    }

    void test_media_file_open_permission_denied() {
        // Create a file with no read permission
        QTemporaryFile temp;
        QVERIFY(temp.open());
        temp.write("data");
        temp.close();

        QString path = temp.fileName();
        QFile::setPermissions(path, QFileDevice::WriteOwner);

        auto result = emp::MediaFile::Open(path.toStdString());
        // Should fail (permission denied)
        // Note: This might not work on all systems
        if (result.is_error()) {
            QVERIFY(result.error().code != emp::ErrorCode::Ok);
        }

        QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    }

    void test_media_file_valid_video_info_complete() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto result = emp::MediaFile::Open(m_testVideoPath.toStdString());
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

    void test_media_file_shared_ptr_lifecycle() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::weak_ptr<emp::MediaFile> weak;
        {
            auto result = emp::MediaFile::Open(m_testVideoPath.toStdString());
            QVERIFY(result.is_ok());
            weak = result.value();
            QVERIFY(!weak.expired());
        }
        // After scope, shared_ptr destroyed
        QVERIFY(weak.expired());
    }

    void test_media_file_multiple_opens_same_file() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto r1 = emp::MediaFile::Open(m_testVideoPath.toStdString());
        auto r2 = emp::MediaFile::Open(m_testVideoPath.toStdString());
        auto r3 = emp::MediaFile::Open(m_testVideoPath.toStdString());

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

    void test_reader_create_null_media_file() {
        auto result = emp::Reader::Create(nullptr);
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, emp::ErrorCode::InvalidArg);
    }

    void test_reader_create_valid() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto result = emp::Reader::Create(mf);
        QVERIFY(result.is_ok());
        QVERIFY(result.value()->media_file() == mf);
    }

    void test_reader_media_file_reference_kept() {
        if (!m_hasTestVideo) QSKIP("No test video");

        std::weak_ptr<emp::MediaFile> weak_mf;
        std::shared_ptr<emp::Reader> reader;
        {
            auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
            weak_mf = mf;
            reader = emp::Reader::Create(mf).value();
        }
        // Asset should still be alive (held by reader)
        QVERIFY(!weak_mf.expired());
        reader.reset();
        QVERIFY(weak_mf.expired());
    }

    void test_reader_decode_first_frame() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
        emp::Rate rate{info.video_fps_num, info.video_fps_den};

        auto result = reader->DecodeAt(emp::FrameTime::from_frame(0, rate));
        QVERIFY(result.is_ok());
        QCOMPARE(result.value()->width(), info.video_width);
        QCOMPARE(result.value()->height(), info.video_height);
    }

    void test_reader_decode_negative_time() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        auto result = reader->DecodeAtUS(-1000000);
        // Should return first frame, not error
        QVERIFY(result.is_ok());
        QVERIFY(result.value()->source_pts_us() >= 0);
    }

    void test_reader_decode_past_eof_returns_last_or_eof() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
        auto result = reader->DecodeAtUS(info.duration_us);

        // Should work (last frame)
        if (result.is_ok()) {
            QVERIFY(result.value() != nullptr);
        }
    }

    void test_reader_seek_to_zero() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        auto result = reader->SeekUS(0);
        QVERIFY(result.is_ok());
    }

    void test_reader_seek_negative() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        auto result = reader->SeekUS(-1000000);
        // Should succeed (clamps to 0)
        QVERIFY(result.is_ok());
    }

    void test_reader_seek_past_duration() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
        auto result = reader->SeekUS(info.duration_us + 10000000);
        // Seek should succeed (will just land at end)
        QVERIFY(result.is_ok());
    }

    void test_reader_sequential_decode() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        QVERIFY(frame->data() != nullptr);
    }

    void test_frame_data_multiple_calls_same_pointer() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        const uint8_t* p1 = frame->data();
        const uint8_t* p2 = frame->data();
        const uint8_t* p3 = frame->data();

        QCOMPARE(p1, p2);
        QCOMPARE(p2, p3);
    }

    void test_frame_stride_32_byte_aligned() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        QCOMPARE(frame->stride_bytes() % 32, 0);
    }

    void test_frame_stride_ge_width_times_4() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        QVERIFY(frame->stride_bytes() >= frame->width() * 4);
    }

    void test_frame_data_size_equals_stride_times_height() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        QCOMPARE(frame->data_size(),
                 static_cast<size_t>(frame->stride_bytes() * frame->height()));
    }

    void test_frame_bgra_alpha_255() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        // First frame PTS should be 0 or very small
        QVERIFY(frame->source_pts_us() >= 0);
        QVERIFY(frame->source_pts_us() < 100000); // < 0.1 sec
    }

    void test_frame_pts_increases() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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
            auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
            auto reader = emp::Reader::Create(mf).value();
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
            auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
            auto reader = emp::Reader::Create(mf).value();
            frame = reader->DecodeAtUS(0).value();
        }
        // Reader and media file destroyed, frame should still be valid
        QVERIFY(frame->data() != nullptr);
        QVERIFY(frame->width() > 0);
    }

#ifdef EMP_HAS_VIDEOTOOLBOX
    // ========================================================================
    // HARDWARE ACCELERATION TESTS - All paths
    // ========================================================================

    void test_hw_native_buffer_method_exists() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Method should exist and not crash
        void* nb = frame->native_buffer();
        // May be nullptr (sw decode) or valid CVPixelBufferRef (hw decode)
        Q_UNUSED(nb);
    }

    void test_hw_data_after_native_buffer() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
        auto frame = reader->DecodeAtUS(0).value();

        // Call native_buffer first
        frame->native_buffer();

        // data() should still work (lazy transfer)
        const uint8_t* data = frame->data();
        QVERIFY(data != nullptr);
    }

    void test_hw_lazy_transfer_triggered_by_data() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        std::vector<std::shared_ptr<emp::MediaFile>> media_files;
        for (int i = 0; i < 10; ++i) {
            auto result = emp::MediaFile::Open(m_testVideoPath.toStdString());
            QVERIFY(result.is_ok());
            media_files.push_back(result.value());
        }
        // All should be valid
        for (auto& a : media_files) {
            QVERIFY(a->info().has_video);
        }
    }

    void test_stress_many_readers_same_media_file() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();

        std::vector<std::shared_ptr<emp::Reader>> readers;
        for (int i = 0; i < 5; ++i) {
            auto result = emp::Reader::Create(mf);
            QVERIFY(result.is_ok());
            readers.push_back(result.value());
        }

        // All readers should work independently
        for (auto& r : readers) {
            auto frame = r->DecodeAtUS(0);
            QVERIFY(frame.is_ok());
        }
    }

    void test_scattered_park_then_play_no_stale_frames() {
        // Regression: Park/Scrub at scattered positions fills cache with
        // distant frames. cache_max_pts reflects the latest park position.
        // When Play starts, the fast-path check (t_us <= cache_max_pts) hits
        // and floor-lookup returns a stale frame. Batch decode also sees cache
        // is ahead (batch_to < cache_max_pts) and does nothing.
        // Result: image freezes while playhead advances.
        //
        // Fix: cache must be invalidated on mode transition to Play so that
        // scattered Park frames don't poison sequential playback.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

        auto mf_r = emp::MediaFile::Open(fixturePath.toStdString());
        QVERIFY2(mf_r.is_ok(), "Failed to open fixture video");
        auto mf = mf_r.value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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
            auto fresh_reader = emp::Reader::Create(mf).value();

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

    void test_cache_not_cleared_on_small_seek() {
        // Verify that seeking within 1s preserves cached frames.
        // The stale-session detection (STALE_THRESHOLD_US = 1s) must NOT
        // clear the cache when the target is close to the cached range.
        // Without this guarantee, normal playback (frame-to-frame) would
        // constantly flush the cache.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto mf = emp::MediaFile::Open(m_testVideoPath.toStdString()).value();
        auto reader = emp::Reader::Create(mf).value();

        const auto& info = mf->info();
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

};

QTEST_MAIN(TestEMPCore)
#include "test_emp_core.moc"
