// Tests for TimelineMediaBuffer (TMB) core functionality
// Coverage: video decode, gap handling, clip switch, reader pool, offline, pre-buffer

#include <QtTest>
#include <QDir>
#include <QFile>

#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <editor_media_platform/emp_time.h>

using namespace emp;

// Shorthand for test readability
static const TrackId V1{TrackType::Video, 1};
static const TrackId V2{TrackType::Video, 2};
static const TrackId V3{TrackType::Video, 3};
static const TrackId A1{TrackType::Audio, 1};

class TestTimelineMediaBuffer : public QObject {
    Q_OBJECT

private:
    QString m_testVideoPath;
    bool m_hasTestVideo = false;
    bool m_hasTestAudio = false;

    void findTestVideo() {
        QStringList candidates = {
            QDir::homePath() + "/Local/jve-spec-kit-claude/fixtures/media/test_bars_tone.mp4",
            QDir::homePath() + "/Local/jve-spec-kit-claude/fixtures/test_video.mp4",
            QDir::homePath() + "/Local/jve-spec-kit-claude/fixtures/countdown_24fps.mp4",
        };

        // Also search in fixtures/
        QDir fixturesDir(QDir::currentPath() + "/../fixtures");
        if (fixturesDir.exists()) {
            QStringList videos = fixturesDir.entryList(
                QStringList() << "*.mp4" << "*.mov" << "*.mkv",
                QDir::Files);
            for (const auto& v : videos) {
                candidates.prepend(fixturesDir.absoluteFilePath(v));
            }
        }

        for (const auto& path : candidates) {
            if (QFile::exists(path)) {
                m_testVideoPath = path;
                m_hasTestVideo = true;
                return;
            }
        }
    }

private slots:
    void initTestCase() {
        findTestVideo();
        if (m_hasTestVideo) {
            auto probe = TimelineMediaBuffer::ProbeFile(m_testVideoPath.toStdString());
            if (probe.is_ok() && probe.value().has_audio) {
                m_hasTestAudio = true;
            }
        }
    }

    // ── Create / Destroy ──

    void test_create_default() {
        auto tmb = TimelineMediaBuffer::Create();
        QVERIFY(tmb != nullptr);
    }

    void test_create_zero_threads() {
        auto tmb = TimelineMediaBuffer::Create(0);
        QVERIFY(tmb != nullptr);
    }

    // ── Gap handling ──

    void test_get_video_empty_track() {
        auto tmb = TimelineMediaBuffer::Create(0);
        auto result = tmb->GetVideoFrame(V1, 100);
        QVERIFY(result.frame == nullptr);
        QVERIFY(!result.offline);
        QVERIFY(result.clip_id.empty());
    }

    void test_get_video_gap_between_clips() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Two clips with a gap between them (frames 0-10 and 20-30)
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 10, 0, 24, 1, 1.0f},
            {"clip2", m_testVideoPath.toStdString(), 20, 10, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Frame 15 is in the gap
        auto result = tmb->GetVideoFrame(V1, 15);
        QVERIFY(result.frame == nullptr);
        QVERIFY(!result.offline);
    }

    // ── Video decode ──

    void test_get_video_first_frame() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame != nullptr);
        QCOMPARE(result.clip_id, std::string("clip1"));
        QCOMPARE(result.media_path, m_testVideoPath.toStdString());
        QCOMPARE(result.source_frame, (int64_t)0);
        QCOMPARE(result.clip_start_frame, (int64_t)0);
        QCOMPARE(result.clip_end_frame, (int64_t)100);
        QVERIFY(!result.offline);
    }

    void test_get_video_mid_clip() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Clip starts at timeline frame 100, source_in = 10
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 100, 50, 10, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Timeline frame 120 → source = 10 + (120-100) = 30
        auto result = tmb->GetVideoFrame(V1, 120);
        QVERIFY(result.frame != nullptr);
        QCOMPARE(result.source_frame, (int64_t)30);
    }

    void test_get_video_clip_switch() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Last frame of clipA
        auto r1 = tmb->GetVideoFrame(V1, 49);
        QCOMPARE(r1.clip_id, std::string("clipA"));
        QCOMPARE(r1.source_frame, (int64_t)49);

        // First frame of clipB
        auto r2 = tmb->GetVideoFrame(V1, 50);
        QCOMPARE(r2.clip_id, std::string("clipB"));
        QCOMPARE(r2.source_frame, (int64_t)0);
    }

    void test_video_cache_hit() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // First decode
        auto r1 = tmb->GetVideoFrame(V1, 5);
        QVERIFY(r1.frame != nullptr);

        // Second access should hit cache (same frame pointer)
        auto r2 = tmb->GetVideoFrame(V1, 5);
        QVERIFY(r2.frame != nullptr);
        QVERIFY(r1.frame.get() == r2.frame.get());
    }

    // ── Offline ──

    void test_offline_detection() {
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/path/video.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame == nullptr);
        QVERIFY(result.offline);
        QCOMPARE(result.clip_id, std::string("clip1"));
    }

    void test_offline_persists() {
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/path/video.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // First access marks offline
        tmb->GetVideoFrame(V1, 0);

        // Second access should still be offline (no retry)
        auto result = tmb->GetVideoFrame(V1, 5);
        QVERIFY(result.offline);
    }

    // ── Reader pool ──

    void test_reader_reuse_same_track() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Multiple frames from same clip should reuse the reader
        auto r1 = tmb->GetVideoFrame(V1, 0);
        auto r2 = tmb->GetVideoFrame(V1, 1);
        auto r3 = tmb->GetVideoFrame(V1, 2);
        QVERIFY(r1.frame != nullptr);
        QVERIFY(r2.frame != nullptr);
        QVERIFY(r3.frame != nullptr);
    }

    void test_max_readers_eviction() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetMaxReaders(2);

        // Set up 3 tracks using the same file (different track IDs = different readers)
        const TrackId video_tracks[] = {V1, V2, V3};
        for (int i = 0; i < 3; ++i) {
            std::vector<ClipInfo> clips = {
                {"clip" + std::to_string(i + 1), m_testVideoPath.toStdString(),
                 0, 100, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(video_tracks[i], clips);
        }

        // Access all 3 tracks — 3rd should evict 1st
        tmb->GetVideoFrame(V1, 0);
        tmb->GetVideoFrame(V2, 0);
        tmb->GetVideoFrame(V3, 0);

        // Track 1 should still work (re-opens reader)
        auto result = tmb->GetVideoFrame(V1, 1);
        QVERIFY(result.frame != nullptr);
    }

    void test_two_clips_same_file_no_thrash() {
        // Two clips from the same file on the same track at very different source
        // positions should not thrash each other's reader cache. Before the fix,
        // both clips shared one Reader keyed by (track, path) — the Reader's
        // stale-session logic cleared its cache on every alternating decode.
        // Now readers are keyed by (track, clip_id), so each clip gets its own.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // clip1 at source_in=0, clip2 at source_in=100 (far apart in source space)
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 100, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Alternate between clips multiple times — both should always decode OK
        for (int i = 0; i < 5; ++i) {
            auto rA = tmb->GetVideoFrame(V1, 10);
            QVERIFY2(rA.frame != nullptr,
                      qPrintable(QString("clipA decode failed on iteration %1").arg(i)));
            QCOMPARE(rA.clip_id, std::string("clipA"));

            auto rB = tmb->GetVideoFrame(V1, 60);
            QVERIFY2(rB.frame != nullptr,
                      qPrintable(QString("clipB decode failed on iteration %1").arg(i)));
            QCOMPARE(rB.clip_id, std::string("clipB"));
        }
    }

    // ── Multi-track ──

    void test_multi_track_independent() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Track 1: clip at frames 0-50
        std::vector<ClipInfo> clips1 = {
            {"t1_clip", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
        };
        // Track 2: clip at frames 10-60 with different source_in
        std::vector<ClipInfo> clips2 = {
            {"t2_clip", m_testVideoPath.toStdString(), 10, 50, 5, 24, 1, 1.0f},
        };

        tmb->SetTrackClips(V1, clips1);
        tmb->SetTrackClips(V2, clips2);

        // Track 1, frame 25 → source = 0 + (25-0) = 25
        auto r1 = tmb->GetVideoFrame(V1, 25);
        QCOMPARE(r1.source_frame, (int64_t)25);
        QCOMPARE(r1.clip_id, std::string("t1_clip"));

        // Track 2, frame 25 → source = 5 + (25-10) = 20
        auto r2 = tmb->GetVideoFrame(V2, 25);
        QCOMPARE(r2.source_frame, (int64_t)20);
        QCOMPARE(r2.clip_id, std::string("t2_clip"));
    }

    // ── Release ──

    void test_release_track() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);
        tmb->GetVideoFrame(V1, 0);  // open reader

        tmb->ReleaseTrack(V1);

        // After release, track should be gone
        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame == nullptr);
        QVERIFY(!result.offline);  // gap, not offline
    }

    void test_release_all() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);
        tmb->SetTrackClips(V2, clips);
        tmb->GetVideoFrame(V1, 0);
        tmb->GetVideoFrame(V2, 0);

        tmb->ReleaseAll();

        auto r1 = tmb->GetVideoFrame(V1, 0);
        auto r2 = tmb->GetVideoFrame(V2, 0);
        QVERIFY(r1.frame == nullptr);
        QVERIFY(r2.frame == nullptr);
    }

    // ── ProbeFile ──

    void test_probe_file_valid() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto result = TimelineMediaBuffer::ProbeFile(m_testVideoPath.toStdString());
        QVERIFY(result.is_ok());

        const auto& info = result.value();
        QVERIFY(info.has_video);
        QVERIFY(info.video_width > 0);
        QVERIFY(info.video_height > 0);
        QVERIFY(info.video_fps_num > 0);
    }

    void test_probe_file_missing() {
        auto result = TimelineMediaBuffer::ProbeFile("/nonexistent/video.mp4");
        QVERIFY(result.is_error());
        QCOMPARE(result.error().code, ErrorCode::FileNotFound);
    }

    // ── SetPlayhead + pre-buffer ──

    void test_set_playhead_basic() {
        auto tmb = TimelineMediaBuffer::Create(0);  // no workers
        // Should not crash
        tmb->SetPlayhead(100, 1, 1.0f);
    }

    void test_pre_buffer_fires() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);

        // Two adjacent clips
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Seek near boundary (frame 48, within threshold of 48 frames)
        tmb->SetPlayhead(48, 1, 1.0f);

        // Give workers time to pre-buffer
        QThread::msleep(200);

        // Frame 50 (first frame of clipB) should be cached
        auto result = tmb->GetVideoFrame(V1, 50);
        QVERIFY(result.frame != nullptr);
        QCOMPARE(result.clip_id, std::string("clipB"));
    }

    void test_pre_buffer_survives_playback_across_boundary() {
        // Verifies that the pre-buffer covers enough frames so the main thread
        // NEVER falls through to a Reader decode during boundary playback.
        //
        // Any Reader decode on the main thread is a potential hitch — h264
        // decode at certain stream positions can take 100ms+. The pre-buffer
        // must move ALL decodes to the background worker.
        //
        // Tests the structural property (cache miss count), not timing,
        // so it works regardless of test video h264 complexity.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,50), clipB [50,100) — both from same file, source_in=0
        std::vector<ClipInfo> both_clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> clip_b_only = {
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };

        // Park near boundary, let pre-buffer run
        emp::SetDecodeMode(emp::DecodeMode::Park);
        tmb->SetTrackClips(V1, both_clips);
        tmb->SetPlayhead(48, 1, 1.0f);
        tmb->GetVideoFrame(V1, 48);  // park decode of clipA
        QThread::msleep(800);         // pre-buffer worker decodes clipB

        // Press play — reset miss counter AFTER clipA playback
        emp::SetDecodeMode(emp::DecodeMode::Play);

        // Play clipA's last frames (these will have Reader decodes — that's OK)
        for (int f = 40; f <= 49; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            tmb->SetTrackClips(V1, both_clips);
            tmb->GetVideoFrame(V1, f);
        }

        // Reset counter — from here, clipB frames must ALL be TMB cache hits
        tmb->ResetVideoCacheMissCount();

        // Play 2 seconds of clipB (frames 50..97)
        for (int f = 50; f <= 97; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            tmb->SetTrackClips(V1, clip_b_only);
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("frame %1 null").arg(f)));
        }

        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses == 0,
                 qPrintable(QString("Pre-buffer gap: %1 cache misses during clipB "
                                    "playback (each miss = potential 100ms+ hitch)")
                            .arg(misses)));

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    // ── Metadata passthrough ──

    void test_rotation_passthrough() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame != nullptr);
        // rotation should be a valid value (0, 90, 180, or 270)
        QVERIFY(result.rotation >= 0 && result.rotation < 360);
    }
    // ── Audio: GetTrackAudio ──

    void test_audio_gap_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // No clips on track → gap
        auto result = tmb->GetTrackAudio(A1, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_no_track_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        auto result = tmb->GetTrackAudio(TrackId{TrackType::Audio, 99}, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_offline_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/audio.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        auto result = tmb->GetTrackAudio(A1, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_basic_decode() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip at timeline frame 0, 100 frames long, source_in = 0
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request first ~0.1s (100000 us)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 0, 100000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
        QCOMPARE(result->sample_rate(), 48000);
        QCOMPARE(result->channels(), 2);
        QCOMPARE(result->start_time_us(), (int64_t)0);
    }

    void test_audio_mid_clip() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip starts at timeline frame 24 (= 1.0s at 24fps), source_in = 0
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 24, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request at 1.5s (mid-clip)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 1500000, 1600000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
        // Start time should be rebased to timeline
        QCOMPARE(result->start_time_us(), (int64_t)1500000);
    }

    void test_audio_clamps_to_clip_end() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip: 48 frames at 24fps = 2.0s (timeline frames 0-47)
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 48, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request 1.5s to 2.5s — should clamp to clip end (2.0s)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 1500000, 2500000, fmt);
        QVERIFY(result != nullptr);

        // Should get ~0.5s of audio (not 1.0s)
        int64_t expected_frames = (500000LL * 48000) / 1000000; // ~24000
        // Allow some tolerance for rounding
        QVERIFY(result->frames() <= expected_frames + 10);
        QVERIFY(result->frames() >= expected_frames - 10);
    }

    void test_audio_request_past_clip_end() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        if (!m_hasTestAudio) QSKIP("No test audio");

        // Clip: 24 frames = 1.0s
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request starts after clip end → gap
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 2000000, 3000000, fmt);
        QVERIFY(result == nullptr);
    }

    void test_audio_with_source_in() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip starts at source frame 12 (0.5s into media at 24fps)
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 48, 12, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 0, 100000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
        QCOMPARE(result->start_time_us(), (int64_t)0);
    }

    void test_audio_conform_speed_ratio() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(30, 1);

        // 24fps media in 30fps sequence: speed_ratio = 30/24 = 1.25
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.25f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request 0.5s of timeline audio
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 0, 500000, fmt);
        QVERIFY(result != nullptr);

        // Should get ~0.5s of output (timeline duration), not 0.625s (source)
        int64_t expected = (500000LL * 48000) / 1000000; // 24000 frames
        QVERIFY(result->frames() >= expected - 10);
        QVERIFY(result->frames() <= expected + 10);
    }

    void test_set_sequence_rate() {
        auto tmb = TimelineMediaBuffer::Create(0);
        // Should not crash
        tmb->SetSequenceRate(30, 1);
        tmb->SetSequenceRate(24, 1);
        tmb->SetSequenceRate(24000, 1001);
    }

    // ── Audio: edge cases ──

    void test_audio_empty_clips_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Track exists but has empty clip vector
        std::vector<ClipInfo> clips = {};
        tmb->SetTrackClips(A1, clips);

        auto result = tmb->GetTrackAudio(A1, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_zero_duration_clip_returns_null() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip with duration=0 → timeline_end() == timeline_start, half-open range [s,s) is empty
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 10, 0, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request at clip's start — zero-duration clip should never match
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 416666, 500000, fmt);
        QVERIFY(result == nullptr);
    }

    void test_audio_request_clamps_to_clip_start() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Clip starts at timeline frame 24 (1.0s at 24fps)
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 24, 48, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request [0.5s, 1.5s) — t0 is before clip start (1.0s)
        // find_clip_at_us(t0=500000) won't find the clip → nullptr (gap before clip)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 500000, 1500000, fmt);
        QVERIFY(result == nullptr);
    }

    void test_audio_multiple_clips_correct_selection() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Two adjacent clips: clip1 at [0, 24) frames, clip2 at [24, 48) frames
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 24, 0, 24, 1, 1.0f},
            {"clip2", m_testVideoPath.toStdString(), 24, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};

        // Request in clip1's range (0.5s)
        auto r1 = tmb->GetTrackAudio(A1, 0, 500000, fmt);
        QVERIFY(r1 != nullptr);
        QCOMPARE(r1->start_time_us(), (int64_t)0);

        // Request in clip2's range (1.0s - 1.5s)
        auto r2 = tmb->GetTrackAudio(A1, 1000000, 1500000, fmt);
        QVERIFY(r2 != nullptr);
        QCOMPARE(r2->start_time_us(), (int64_t)1000000);
    }

    // ── Phase 2c: Boundary-spanning audio ──

    void test_audio_boundary_spanning() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // Two adjacent clips: clip1 [0,24) = 0.0s-1.0s, clip2 [24,48) = 1.0s-2.0s
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 24, 0, 24, 1, 1.0f},
            {"clip2", m_testVideoPath.toStdString(), 24, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request spans boundary: [0.5s, 1.5s)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 500000, 1500000, fmt);
        QVERIFY(result != nullptr);

        // Should get full 1.0s of audio (not truncated 0.5s)
        int64_t expected_frames = (1000000LL * 48000) / 1000000; // 48000
        QVERIFY2(result->frames() >= expected_frames - 10,
                 qPrintable(QString("frames=%1 expected>=%2").arg(result->frames()).arg(expected_frames - 10)));
        QVERIFY2(result->frames() <= expected_frames + 10,
                 qPrintable(QString("frames=%1 expected<=%2").arg(result->frames()).arg(expected_frames + 10)));
        QCOMPARE(result->start_time_us(), (int64_t)500000);
    }

    void test_audio_gap_between_clips_filled() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // clip1 [0,24) = 0.0s-1.0s, clip2 [48,72) = 2.0s-3.0s
        // Gap from 1.0s to 2.0s
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 24, 0, 24, 1, 1.0f},
            {"clip2", m_testVideoPath.toStdString(), 48, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request [0.5s, 2.5s) — spans clip1 end, gap, and into clip2
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 500000, 2500000, fmt);
        QVERIFY(result != nullptr);

        // Should get full 2.0s of audio covering both clips + gap
        int64_t expected_frames = (2000000LL * 48000) / 1000000; // 96000
        QVERIFY2(result->frames() >= expected_frames - 10,
                 qPrintable(QString("frames=%1 expected>=%2").arg(result->frames()).arg(expected_frames - 10)));
        QVERIFY2(result->frames() <= expected_frames + 10,
                 qPrintable(QString("frames=%1 expected<=%2").arg(result->frames()).arg(expected_frames + 10)));
        QCOMPARE(result->start_time_us(), (int64_t)500000);

        // Verify gap region [1.0s, 2.0s) is silent
        // In output coords: gap starts at offset 0.5s, ends at 1.5s
        const float* data = result->data_f32();
        const int ch = 2;
        int64_t gap_start_sample = (500000LL * 48000) / 1000000;  // 24000
        int64_t gap_end_sample = (1500000LL * 48000) / 1000000;   // 72000
        float max_gap_val = 0.0f;
        for (int64_t i = gap_start_sample; i < gap_end_sample && i < result->frames(); ++i) {
            for (int c = 0; c < ch; ++c) {
                float v = std::abs(data[i * ch + c]);
                if (v > max_gap_val) max_gap_val = v;
            }
        }
        QVERIFY2(max_gap_val < 0.001f, "Gap region should be silent");
    }

    void test_audio_boundary_second_clip_offline() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // clip1 valid, clip2 offline — request spans boundary
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 24, 0, 24, 1, 1.0f},
            {"clip2", "/nonexistent/offline_media.mp4", 24, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request [0.5s, 1.5s) — first clip OK, second offline
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 500000, 1500000, fmt);
        QVERIFY(result != nullptr);

        // Should get truncated first-clip audio (~0.5s), NOT crash or full 1.0s
        int64_t expected_frames = (500000LL * 48000) / 1000000; // 24000
        QVERIFY2(result->frames() >= expected_frames - 10,
                 qPrintable(QString("frames=%1 expected>=%2").arg(result->frames()).arg(expected_frames - 10)));
        QVERIFY2(result->frames() <= expected_frames + 10,
                 qPrintable(QString("frames=%1 expected<=%2").arg(result->frames()).arg(expected_frames + 10)));
    }

    void test_audio_boundary_with_conform() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(30, 1);

        // clip1: 24fps media in 30fps sequence (speed_ratio=1.25)
        // clip2: 30fps media in 30fps sequence (speed_ratio=1.0)
        // Both 30 timeline frames = 1.0s each at 30fps
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 30, 0, 24, 1, 1.25f},
            {"clip2", m_testVideoPath.toStdString(), 30, 30, 0, 30, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Request spans boundary: [0.5s, 1.5s)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(A1, 500000, 1500000, fmt);
        QVERIFY(result != nullptr);

        // Should get full 1.0s of timeline audio despite different conform ratios
        int64_t expected_frames = (1000000LL * 48000) / 1000000; // 48000
        QVERIFY2(result->frames() >= expected_frames - 10,
                 qPrintable(QString("frames=%1 expected>=%2").arg(result->frames()).arg(expected_frames - 10)));
        QVERIFY2(result->frames() <= expected_frames + 10,
                 qPrintable(QString("frames=%1 expected<=%2").arg(result->frames()).arg(expected_frames + 10)));
        QCOMPARE(result->start_time_us(), (int64_t)500000);
    }

    // ── Phase 2d: Audio pre-buffering at clip boundaries ──

    void test_audio_pre_buffer_fires() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        // Two adjacent clips: clip1 [0,50) clip2 [50,100)
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Seek near boundary (frame 48 — within PRE_BUFFER_THRESHOLD of 48)
        tmb->SetPlayhead(48, 1, 1.0f);

        // Give workers time to pre-buffer
        QThread::msleep(300);

        // Audio at clip2 entry point should be pre-buffered
        // clip2 starts at frame 50 → 50/24 = 2.083333s
        TimeUS clip2_start = FrameTime::from_frame(50, Rate{24, 1}).to_us();
        TimeUS clip2_end = clip2_start + 200000; // 200ms
        auto result = tmb->GetTrackAudio(A1, clip2_start, clip2_end, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }

    void test_audio_pre_buffer_cleared_on_set_clips() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        // Two adjacent clips
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Trigger pre-buffer
        tmb->SetPlayhead(48, 1, 1.0f);
        QThread::msleep(300);

        // Now replace clips with different layout — cache should be cleared
        std::vector<ClipInfo> clips2 = {
            {"clipC", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips2);

        // Audio should still work (fresh decode, not stale cache)
        auto result = tmb->GetTrackAudio(A1, 0, 100000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }

    void test_audio_pre_buffer_no_crash_zero_threads() {
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0); // no workers
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        // Two adjacent clips
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // SetPlayhead near boundary — no workers, should not crash
        tmb->SetPlayhead(48, 1, 1.0f);

        // GetTrackAudio works on-demand (no pre-buffer, no crash)
        TimeUS clip2_start = FrameTime::from_frame(50, Rate{24, 1}).to_us();
        auto result = tmb->GetTrackAudio(A1, clip2_start, clip2_start + 100000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }

    void test_audio_pre_buffer_sub_range_extraction() {
        // Pre-buffer caches 200ms, but GetTrackAudio requests a narrower sub-range
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        // Two adjacent clips: clip1 [0,50) clip2 [50,100)
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, clips);

        // Trigger pre-buffer (caches ~200ms from clip2 entry)
        tmb->SetPlayhead(48, 1, 1.0f);
        QThread::msleep(300);

        // Request only 50ms starting 50ms into clip2 (sub-range of cached 200ms)
        TimeUS clip2_start = FrameTime::from_frame(50, Rate{24, 1}).to_us();
        TimeUS req_t0 = clip2_start + 50000;  // 50ms in
        TimeUS req_t1 = req_t0 + 50000;       // 50ms duration
        auto result = tmb->GetTrackAudio(A1, req_t0, req_t1, fmt);
        QVERIFY(result != nullptr);

        // Should get ~50ms worth of samples (2400 frames at 48kHz)
        int64_t expected = (50000LL * 48000) / 1000000; // 2400
        QVERIFY2(result->frames() >= expected - 10,
                 qPrintable(QString("frames=%1 expected>=%2").arg(result->frames()).arg(expected - 10)));
        QVERIFY2(result->frames() <= expected + 10,
                 qPrintable(QString("frames=%1 expected<=%2").arg(result->frames()).arg(expected + 10)));
        // Verify start time is the requested sub-range start
        QCOMPARE(result->start_time_us(), req_t0);
    }

    void test_audio_cache_eviction_at_capacity() {
        // Fill audio cache past MAX_AUDIO_CACHE (4), verify no crash and audio still works
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        // 6 adjacent clips (more than MAX_AUDIO_CACHE=4)
        std::vector<ClipInfo> clips;
        for (int i = 0; i < 6; ++i) {
            clips.push_back({
                "clip" + std::to_string(i),
                m_testVideoPath.toStdString(),
                static_cast<int64_t>(i * 50), 50, 0, 24, 1, 1.0f
            });
        }
        tmb->SetTrackClips(A1, clips);

        // Trigger pre-buffer at each boundary, wait for 1 worker to finish each pair
        for (int i = 0; i < 5; ++i) {
            int64_t boundary_frame = (i + 1) * 50;
            tmb->SetPlayhead(boundary_frame - 2, 1, 1.0f);
            QThread::msleep(300); // enough for 1 worker to process VIDEO + AUDIO jobs
        }

        // Wait for final jobs to complete
        QThread::msleep(300);

        // Audio at last clip should still work (on-demand decode, not stale cache)
        TimeUS last_clip_start = FrameTime::from_frame(250, Rate{24, 1}).to_us();
        auto result = tmb->GetTrackAudio(A1, last_clip_start, last_clip_start + 100000, fmt);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }
};

QTEST_MAIN(TestTimelineMediaBuffer)
#include "test_timeline_media_buffer.moc"
