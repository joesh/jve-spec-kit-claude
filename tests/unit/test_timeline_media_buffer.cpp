// Tests for TimelineMediaBuffer (TMB) core functionality
// Coverage: video decode, gap handling, clip switch, reader pool, offline, pre-buffer

#include <QtTest>
#include <QDir>
#include <QFile>

#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <editor_media_platform/emp_time.h>

using namespace emp;

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
        auto result = tmb->GetVideoFrame(1, 100);
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
        tmb->SetTrackClips(1, clips);

        // Frame 15 is in the gap
        auto result = tmb->GetVideoFrame(1, 15);
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
        tmb->SetTrackClips(1, clips);

        auto result = tmb->GetVideoFrame(1, 0);
        QVERIFY(result.frame != nullptr);
        QCOMPARE(result.clip_id, std::string("clip1"));
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
        tmb->SetTrackClips(1, clips);

        // Timeline frame 120 → source = 10 + (120-100) = 30
        auto result = tmb->GetVideoFrame(1, 120);
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
        tmb->SetTrackClips(1, clips);

        // Last frame of clipA
        auto r1 = tmb->GetVideoFrame(1, 49);
        QCOMPARE(r1.clip_id, std::string("clipA"));
        QCOMPARE(r1.source_frame, (int64_t)49);

        // First frame of clipB
        auto r2 = tmb->GetVideoFrame(1, 50);
        QCOMPARE(r2.clip_id, std::string("clipB"));
        QCOMPARE(r2.source_frame, (int64_t)0);
    }

    void test_video_cache_hit() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        // First decode
        auto r1 = tmb->GetVideoFrame(1, 5);
        QVERIFY(r1.frame != nullptr);

        // Second access should hit cache (same frame pointer)
        auto r2 = tmb->GetVideoFrame(1, 5);
        QVERIFY(r2.frame != nullptr);
        QVERIFY(r1.frame.get() == r2.frame.get());
    }

    // ── Offline ──

    void test_offline_detection() {
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/path/video.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        auto result = tmb->GetVideoFrame(1, 0);
        QVERIFY(result.frame == nullptr);
        QVERIFY(result.offline);
        QCOMPARE(result.clip_id, std::string("clip1"));
    }

    void test_offline_persists() {
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/path/video.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        // First access marks offline
        tmb->GetVideoFrame(1, 0);

        // Second access should still be offline (no retry)
        auto result = tmb->GetVideoFrame(1, 5);
        QVERIFY(result.offline);
    }

    // ── Reader pool ──

    void test_reader_reuse_same_track() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        // Multiple frames from same clip should reuse the reader
        auto r1 = tmb->GetVideoFrame(1, 0);
        auto r2 = tmb->GetVideoFrame(1, 1);
        auto r3 = tmb->GetVideoFrame(1, 2);
        QVERIFY(r1.frame != nullptr);
        QVERIFY(r2.frame != nullptr);
        QVERIFY(r3.frame != nullptr);
    }

    void test_max_readers_eviction() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetMaxReaders(2);

        // Set up 3 tracks using the same file (different track IDs = different readers)
        for (int i = 1; i <= 3; ++i) {
            std::vector<ClipInfo> clips = {
                {"clip" + std::to_string(i), m_testVideoPath.toStdString(),
                 0, 100, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(i, clips);
        }

        // Access all 3 tracks — 3rd should evict 1st
        tmb->GetVideoFrame(1, 0);
        tmb->GetVideoFrame(2, 0);
        tmb->GetVideoFrame(3, 0);

        // Track 1 should still work (re-opens reader)
        auto result = tmb->GetVideoFrame(1, 1);
        QVERIFY(result.frame != nullptr);
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

        tmb->SetTrackClips(1, clips1);
        tmb->SetTrackClips(2, clips2);

        // Track 1, frame 25 → source = 0 + (25-0) = 25
        auto r1 = tmb->GetVideoFrame(1, 25);
        QCOMPARE(r1.source_frame, (int64_t)25);
        QCOMPARE(r1.clip_id, std::string("t1_clip"));

        // Track 2, frame 25 → source = 5 + (25-10) = 20
        auto r2 = tmb->GetVideoFrame(2, 25);
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
        tmb->SetTrackClips(1, clips);
        tmb->GetVideoFrame(1, 0);  // open reader

        tmb->ReleaseTrack(1);

        // After release, track should be gone
        auto result = tmb->GetVideoFrame(1, 0);
        QVERIFY(result.frame == nullptr);
        QVERIFY(!result.offline);  // gap, not offline
    }

    void test_release_all() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);
        tmb->SetTrackClips(2, clips);
        tmb->GetVideoFrame(1, 0);
        tmb->GetVideoFrame(2, 0);

        tmb->ReleaseAll();

        auto r1 = tmb->GetVideoFrame(1, 0);
        auto r2 = tmb->GetVideoFrame(2, 0);
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
        tmb->SetTrackClips(1, clips);

        // Seek near boundary (frame 48, within threshold of 48 frames)
        tmb->SetPlayhead(48, 1, 1.0f);

        // Give workers time to pre-buffer
        QThread::msleep(200);

        // Frame 50 (first frame of clipB) should be cached
        auto result = tmb->GetVideoFrame(1, 50);
        QVERIFY(result.frame != nullptr);
        QCOMPARE(result.clip_id, std::string("clipB"));
    }

    // ── Metadata passthrough ──

    void test_rotation_passthrough() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        auto result = tmb->GetVideoFrame(1, 0);
        QVERIFY(result.frame != nullptr);
        // rotation should be a valid value (0, 90, 180, or 270)
        QVERIFY(result.rotation >= 0 && result.rotation < 360);
    }
    // ── Audio: GetTrackAudio ──

    void test_audio_gap_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        // No clips on track → gap
        auto result = tmb->GetTrackAudio(1, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_no_track_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        auto result = tmb->GetTrackAudio(99, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr);
    }

    void test_audio_offline_returns_null() {
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/audio.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(1, clips);

        auto result = tmb->GetTrackAudio(1, 0, 100000,
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
        tmb->SetTrackClips(1, clips);

        // Request first ~0.1s (100000 us)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 0, 100000, fmt);
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
        tmb->SetTrackClips(1, clips);

        // Request at 1.5s (mid-clip)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 1500000, 1600000, fmt);
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
        tmb->SetTrackClips(1, clips);

        // Request 1.5s to 2.5s — should clamp to clip end (2.0s)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 1500000, 2500000, fmt);
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
        tmb->SetTrackClips(1, clips);

        // Request starts after clip end → gap
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 2000000, 3000000, fmt);
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
        tmb->SetTrackClips(1, clips);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 0, 100000, fmt);
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
        tmb->SetTrackClips(1, clips);

        // Request 0.5s of timeline audio
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 0, 500000, fmt);
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
        tmb->SetTrackClips(1, clips);

        auto result = tmb->GetTrackAudio(1, 0, 100000,
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
        tmb->SetTrackClips(1, clips);

        // Request at clip's start — zero-duration clip should never match
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 416666, 500000, fmt);
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
        tmb->SetTrackClips(1, clips);

        // Request [0.5s, 1.5s) — t0 is before clip start (1.0s)
        // find_clip_at_us(t0=500000) won't find the clip → nullptr (gap before clip)
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto result = tmb->GetTrackAudio(1, 500000, 1500000, fmt);
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
        tmb->SetTrackClips(1, clips);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};

        // Request in clip1's range (0.5s)
        auto r1 = tmb->GetTrackAudio(1, 0, 500000, fmt);
        QVERIFY(r1 != nullptr);
        QCOMPARE(r1->start_time_us(), (int64_t)0);

        // Request in clip2's range (1.0s - 1.5s)
        auto r2 = tmb->GetTrackAudio(1, 1000000, 1500000, fmt);
        QVERIFY(r2 != nullptr);
        QCOMPARE(r2->start_time_us(), (int64_t)1000000);
    }
};

QTEST_MAIN(TestTimelineMediaBuffer)
#include "test_timeline_media_buffer.moc"
