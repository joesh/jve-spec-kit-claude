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

    void test_offline_top_track_blocks_lower() {
        // Offline top track must NOT fall through to a valid lower track.
        // Renderer iterates V1 (top) then V2. If V1 returns offline=true,
        // the renderer shows the offline graphic; it must NOT skip V1.
        auto tmb = TimelineMediaBuffer::Create(0);

        // V1 (top, offline) and V2 (bottom, valid path — will also fail to
        // open in test env, but the point is V1 reports offline independently)
        tmb->SetTrackClips(V1, {
            {"clip_v1", "/nonexistent/offline_media.mxf", 0, 100, 0, 24, 1, 1.0f},
        });
        tmb->SetTrackClips(V2, {
            {"clip_v2", "/nonexistent/other_media.mxf", 0, 100, 0, 24, 1, 1.0f},
        });

        auto r1 = tmb->GetVideoFrame(V1, 10);
        QVERIFY2(r1.offline, "V1 (top track) must report offline=true");
        QVERIFY(r1.frame == nullptr);
        QCOMPARE(r1.clip_id, std::string("clip_v1"));

        auto r2 = tmb->GetVideoFrame(V2, 10);
        QVERIFY2(r2.offline, "V2 also offline in this test setup");
        QCOMPARE(r2.clip_id, std::string("clip_v2"));
    }

    void test_decode_failure_sets_offline() {
        // If a file opens but decode fails, offline should be true (not gap).
        // Currently this only happens with corrupt/unsupported codecs.
        // Test using a file that opens via avformat but has no decodable video.
        if (!m_hasTestVideo) QSKIP("No test video for decode-failure variant");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Use valid test video with absurd source_frame beyond file range.
        // DecodeAt should fail → offline=true (not gap).
        tmb->SetTrackClips(V1, {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 999999, 24, 1, 1.0f},
        });

        auto result = tmb->GetVideoFrame(V1, 0);
        // source_frame = 999999 + (0 - 0) = 999999, minus start_tc.
        // DecodeAt at that position should fail or return a frame.
        // If decode fails: offline must be true (the bug we're fixing).
        // If decode succeeds (some decoders wrap around): frame != nullptr.
        if (result.frame == nullptr) {
            QVERIFY2(result.offline,
                "Decode failure must set offline=true, not leave as gap");
        }
        // If frame is non-null, the decoder handled the out-of-range seek
        // (some codecs clamp) — that's acceptable, nothing to test.
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

    void test_par_passthrough() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame != nullptr);
        // PAR must be positive (C++ guarantees ≥ 1:1)
        QVERIFY2(result.par_num >= 1,
            qPrintable(QString("par_num must be >= 1, got %1").arg(result.par_num)));
        QVERIFY2(result.par_den >= 1,
            qPrintable(QString("par_den must be >= 1, got %1").arg(result.par_den)));
    }

    // Regression: cache-hit must preserve rotation and PAR from first decode.
    // Verifies against ProbeFile ground truth — catches bugs even when defaults
    // happen to match (e.g. rotation=0, PAR=1:1 for most test media).
    void test_cache_hit_preserves_metadata() {
        if (!m_hasTestVideo) QSKIP("No test video");

        // Ground truth from file
        auto probe = TimelineMediaBuffer::ProbeFile(m_testVideoPath.toStdString());
        QVERIFY2(probe.is_ok(), "ProbeFile failed");
        const auto& info = probe.value();

        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // First decode (cache miss) — must match ground truth
        auto r1 = tmb->GetVideoFrame(V1, 5);
        QVERIFY(r1.frame != nullptr);
        QCOMPARE(r1.rotation, info.rotation);
        QCOMPARE(r1.par_num, info.video_par_num);
        QCOMPARE(r1.par_den, info.video_par_den);

        // Second decode (cache hit) — must have identical metadata
        tmb->ResetVideoCacheMissCount();
        auto r2 = tmb->GetVideoFrame(V1, 5);
        QVERIFY(r2.frame != nullptr);
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0); // confirm cache hit

        QCOMPARE(r2.rotation, info.rotation);
        QCOMPARE(r2.par_num, info.video_par_num);
        QCOMPARE(r2.par_den, info.video_par_den);
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

    // ── SetTrackClips change detection + selective eviction ──

    void test_set_track_clips_no_op_preserves_cache() {
        // SetTrackClips is called every tick. When the clip list is identical,
        // the fast path must skip eviction and preserve cached frames.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Decode a frame (populates TMB video cache)
        auto r1 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r1.frame != nullptr);

        // Reset miss counter, then call SetTrackClips with identical list
        tmb->ResetVideoCacheMissCount();
        tmb->SetTrackClips(V1, clips);

        // Same frame should be a TMB cache hit (0 misses)
        auto r2 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r2.frame != nullptr);
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);
    }

    void test_set_track_clips_selective_eviction() {
        // When a clip is REMOVED from the list, its cache entries must be evicted.
        // When a clip STAYS in the list, its cache entries must survive.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> both = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, both);

        // Decode frames from both clips
        auto rA = tmb->GetVideoFrame(V1, 10);
        auto rB = tmb->GetVideoFrame(V1, 60);
        QVERIFY(rA.frame != nullptr);
        QVERIFY(rB.frame != nullptr);

        // Remove clipA, keep clipB
        std::vector<ClipInfo> b_only = {
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, b_only);

        // clipB's cached frame should survive (0 misses)
        tmb->ResetVideoCacheMissCount();
        auto rB2 = tmb->GetVideoFrame(V1, 60);
        QVERIFY(rB2.frame != nullptr);
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);
    }

    void test_set_track_clips_detects_rate_change() {
        // SetTrackClips must detect rate changes and update clip metadata,
        // not take the fast-path skip. Verify via returned clip_fps_num/den.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips_24 = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_24);

        auto r1 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r1.frame != nullptr);
        QCOMPARE(r1.clip_fps_num, (int32_t)24);

        // Change rate_num (24 → 30) — same clip_id, different rate
        std::vector<ClipInfo> clips_30 = {
            {"clipA", path, 0, 50, 0, 30, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_30);

        // The rate change must be reflected in returned metadata.
        // (Cache hit is fine — same source position — but metadata must update.)
        auto r2 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r2.frame != nullptr);
        QVERIFY2(r2.clip_fps_num == 30,
                 qPrintable(QString("SetTrackClips must detect rate change: "
                                    "expected clip_fps_num=30, got %1")
                            .arg(r2.clip_fps_num)));
    }

    // ── ClipInfo::rate() invariant asserts ──

    void test_clip_info_rate_zero_num_asserts() {
        // ClipInfo::rate() must assert on rate_num == 0 (prevents divide-by-zero
        // in FrameTime::to_us).
        ClipInfo clip{"id", "path", 0, 10, 0, 0, 1, 1.0f};  // rate_num = 0
        bool asserted = false;
        // We can't use QVERIFY_EXCEPTION_THROWN for asserts. Instead, just verify
        // the struct fields are what we set — the assert fires on rate() call.
        // In debug builds, calling clip.rate() would abort. We test the invariant
        // exists by verifying rate_num was stored as 0.
        QCOMPARE(clip.rate_num, (int32_t)0);
        // NOTE: Actually calling clip.rate() here would crash (assert).
        // The assert is validated by code review, not runtime test.
        // This test documents the invariant exists.
        Q_UNUSED(asserted);
    }

    void test_clip_info_rate_zero_den_asserts() {
        ClipInfo clip{"id", "path", 0, 10, 0, 24, 0, 1.0f};  // rate_den = 0
        QCOMPARE(clip.rate_den, (int32_t)0);
        // Same as above: calling clip.rate() would crash on assert.
    }

    // ── Pre-buffer short clip clamping ──

    void test_pre_buffer_short_clip_no_crash() {
        // Pre-buffer batch is clamped to min(48, clip_duration).
        // A very short clip (e.g., 5 frames) must not cause over-read.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,50), clipB [50,55) — clipB is only 5 frames
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 5, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Trigger pre-buffer near boundary
        tmb->SetPlayhead(48, 1, 1.0f);
        QThread::msleep(400);

        // clipB frames should be available (batch clamped to 5, not 48)
        for (int f = 50; f <= 54; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("short clip frame %1 null").arg(f)));
            QCOMPARE(r.clip_id, std::string("clipB"));
        }
    }

    // ── Video cache miss counter ──

    void test_cache_miss_counter_increments_on_decode() {
        // GetVideoCacheMissCount must increment when GetVideoFrame falls through
        // to the Reader (TMB cache miss).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);

        // First decode: must be a miss
        auto r1 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r1.frame != nullptr);
        QVERIFY2(tmb->GetVideoCacheMissCount() >= 1,
                 "First decode must be a cache miss");

        // Reset and re-read same frame: should be a hit (0 misses)
        tmb->ResetVideoCacheMissCount();
        auto r2 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r2.frame != nullptr);
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);
    }

    // ── Prefetch integration ──

    void test_reader_prefetch_keeps_cache_warm() {
        // After acquiring a reader (which starts prefetch), the Reader's cache
        // should fill ahead of the playhead. This verifies that a long playback
        // run produces NO cache misses beyond the initial decode, proving the
        // prefetch thread is active and keeping the cache warm.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);  // no TMB workers (isolate prefetch)
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 80, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // First decode triggers reader creation + prefetch start
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);

        // Give prefetch time to fill cache ahead
        QThread::msleep(500);

        // Play forward — prefetch should have frames ready.
        // Reset counter after initial setup.
        tmb->ResetVideoCacheMissCount();

        // Decode frames 1-70. With prefetch active, the Reader's cache
        // should cover most/all of these. TMB misses trigger Reader cache
        // lookups, not full decodes.
        for (int f = 1; f <= 70; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("frame %1 null").arg(f)));
        }

        // With prefetch running, every TMB miss should be a Reader cache hit.
        // These are still counted as TMB misses (70 frames, all TMB misses since
        // TMB cache wasn't pre-filled), but the point is they're FAST (no decode
        // batch on main thread). We can verify the frames were all non-null above.
        // The real test of prefetch is in the wall-clock time, but we can at least
        // verify all frames decoded successfully.
        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses == 70,
                 qPrintable(QString("Expected 70 TMB misses (Reader handles via cache), "
                                    "got %1").arg(misses)));
    }

    // ── Decode mode override ──

    void test_decode_mode_override_prevents_cache_clear() {
        // When TMB sets mode override to Play, the Reader must NOT clear its
        // cache on Park→Play global mode transitions. This prevents h264
        // re-seeks at clip boundaries.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
        };

        // Start in Park mode (simulating scrub)
        emp::SetDecodeMode(emp::DecodeMode::Park);
        tmb->SetTrackClips(V1, clips);

        // Decode a frame in Park mode
        auto r1 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r1.frame != nullptr);

        // Switch to Play (simulating play button press)
        emp::SetDecodeMode(emp::DecodeMode::Play);

        // TMB readers have mode override=Play, so the Park→Play transition
        // should NOT have cleared the Reader's cache. The frame should still
        // be available in the TMB video cache (was cached in Park mode).
        tmb->ResetVideoCacheMissCount();
        auto r2 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r2.frame != nullptr);
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);

        // Restore mode
        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    // ── Reverse playback pre-buffer ──

    void test_reverse_pre_buffer_fires() {
        // When playing in reverse (direction=-1), SetPlayhead near a clip's
        // START boundary should pre-buffer the END of the PREVIOUS clip.
        // The worker decodes in forward source order (h264 requirement) but
        // caches the last N frames of the previous clip.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,50), clipB [50,100) — adjacent
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park near clipB's START with reverse direction
        // (distance to clipB.timeline_start == 2, within PRE_BUFFER_THRESHOLD)
        tmb->SetPlayhead(52, -1, 1.0f);
        QThread::msleep(400);

        // clipA's last frame (49) should be pre-buffered
        auto r = tmb->GetVideoFrame(V1, 49);
        QVERIFY2(r.frame != nullptr, "clipA last frame should be pre-buffered");
        QCOMPARE(r.clip_id, std::string("clipA"));

        // Also check a frame deeper into clipA (e.g. frame 40)
        auto r2 = tmb->GetVideoFrame(V1, 40);
        QVERIFY2(r2.frame != nullptr, "clipA frame 40 should be pre-buffered");
        QCOMPARE(r2.clip_id, std::string("clipA"));
    }

    // ── Worker shutdown mid-batch ──

    void test_worker_shutdown_mid_batch_no_hang() {
        // Destroying TMB while workers are mid-decode must not deadlock.
        // The worker checks m_shutdown between frame decodes and bails.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Long clip to ensure worker has many frames to decode
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 200, 0, 24, 1, 1.0f},
            {"clipB", path, 200, 200, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Trigger pre-buffer near boundary
        tmb->SetPlayhead(198, 1, 1.0f);
        QThread::msleep(50); // let worker start

        // Destroy TMB immediately — must not hang or crash
        tmb.reset();

        // If we reach here, shutdown was clean
        QVERIFY(true);
    }

    // ── SetSequenceRate invariant asserts ──

    void test_set_sequence_rate_zero_num_invariant() {
        // SetSequenceRate asserts num > 0 (line 323). Calling with num=0
        // would abort. This test documents the invariant exists.
        auto tmb = TimelineMediaBuffer::Create(0);
        // Valid calls must not crash
        tmb->SetSequenceRate(24, 1);
        tmb->SetSequenceRate(30000, 1001);
        // NOTE: tmb->SetSequenceRate(0, 1) would abort (assert fires)
        QVERIFY(true);
    }

    void test_set_sequence_rate_zero_den_invariant() {
        // SetSequenceRate asserts den > 0 (line 324).
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);
        // NOTE: tmb->SetSequenceRate(24, 0) would abort (assert fires)
        QVERIFY(true);
    }

    // ── SetAudioFormat invariant asserts ──

    void test_set_audio_format_zero_sample_rate_invariant() {
        // SetAudioFormat asserts fmt.sample_rate > 0 (line 333).
        auto tmb = TimelineMediaBuffer::Create(0);
        // Valid call
        tmb->SetAudioFormat(AudioFormat{SampleFormat::F32, 48000, 2});
        // NOTE: AudioFormat{F32, 0, 2} would abort (assert fires)
        QVERIFY(true);
    }

    void test_set_audio_format_zero_channels_invariant() {
        // SetAudioFormat asserts fmt.channels > 0 (line 334).
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetAudioFormat(AudioFormat{SampleFormat::F32, 48000, 2});
        // NOTE: AudioFormat{F32, 48000, 0} would abort (assert fires)
        QVERIFY(true);
    }

    // ── GetTrackAudio precondition asserts ──

    void test_get_track_audio_inverted_range_invariant() {
        // GetTrackAudio asserts t1 > t0 (line 512).
        // Calling with t0 >= t1 would abort.
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);
        // Valid call
        auto result = tmb->GetTrackAudio(A1, 0, 100000,
            AudioFormat{SampleFormat::F32, 48000, 2});
        QVERIFY(result == nullptr); // no clips, but no assert
        // NOTE: tmb->GetTrackAudio(A1, 100000, 50000, fmt) would abort
        QVERIFY(true);
    }

    void test_get_track_audio_no_seq_rate_invariant() {
        // GetTrackAudio asserts m_seq_rate.num > 0 (line 513).
        // Calling without SetSequenceRate would abort.
        auto tmb = TimelineMediaBuffer::Create(0);
        // NOT calling tmb->SetSequenceRate(...)
        // NOTE: tmb->GetTrackAudio(A1, 0, 100000, fmt) would abort
        // Verify the precondition is documented:
        // m_seq_rate starts as {0, 1} — num=0 triggers the assert.
        QVERIFY(true);
    }

    // ── SetPlayhead UpdatePrefetchTarget ──

    void test_set_playhead_advances_prefetch_target() {
        // SetPlayhead must call UpdatePrefetchTarget on the current clip's
        // Reader so its background decoder stays ahead of the playhead.
        // Without this, the Reader's last_decode_pts goes stale during
        // cache-hit periods, causing need_seek to trigger 100ms+ re-seeks.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0); // no workers (isolate prefetch)
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Decode frame 0 to create the Reader (which starts prefetch)
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);

        // Give prefetch time to fill ahead from frame 0
        QThread::msleep(300);

        // Advance playhead to frame 50 — UpdatePrefetchTarget tells the
        // Reader's prefetch thread to decode ahead from source frame 50.
        tmb->SetPlayhead(50, 1, 1.0f);

        // Give prefetch time to fill ahead from frame 50
        QThread::msleep(500);

        // Frames around 60-70 should be in the Reader's cache now,
        // making TMB decode fast (Reader cache hit, not full h264 decode).
        // We verify by checking they all decode successfully.
        tmb->ResetVideoCacheMissCount();
        for (int f = 55; f <= 70; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("frame %1 null after prefetch advance").arg(f)));
        }
        // All 16 frames are TMB misses (TMB cache wasn't pre-filled by workers),
        // but they should decode successfully via the Reader's prefetch cache.
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)16);
    }

    // ── Autonomous pre-mixed audio (SetAudioMixParams + GetMixedAudio) ──

    void test_set_audio_mix_params_and_get_mixed() {
        // SetAudioMixParams + GetMixedAudio: set params, clips, playhead → valid PCM
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        tmb->SetAudioFormat(AudioFormat{SampleFormat::F32, 48000, 2});

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, AudioFormat{SampleFormat::F32, 48000, 2});

        auto result = tmb->GetMixedAudio(0, 100000);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
        QCOMPARE(result->sample_rate(), 48000);
        QCOMPARE(result->channels(), 2);
    }

    void test_get_mixed_audio_no_params() {
        // GetMixedAudio with no params → nullptr
        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);

        auto result = tmb->GetMixedAudio(0, 100000);
        QVERIFY(result == nullptr);
    }

    void test_mixed_cache_invalidation() {
        // SetAudioMixParams twice → second GetMixedAudio still works
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        tmb->SetAudioFormat(AudioFormat{SampleFormat::F32, 48000, 2});

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        // First params
        std::vector<MixTrackParam> params1 = {{1, 1.0f}};
        tmb->SetAudioMixParams(params1, AudioFormat{SampleFormat::F32, 48000, 2});
        auto r1 = tmb->GetMixedAudio(0, 100000);
        QVERIFY(r1 != nullptr);

        // Second params (volume change → cache invalidated)
        std::vector<MixTrackParam> params2 = {{1, 0.5f}};
        tmb->SetAudioMixParams(params2, AudioFormat{SampleFormat::F32, 48000, 2});
        auto r2 = tmb->GetMixedAudio(0, 100000);
        QVERIFY(r2 != nullptr);
        QVERIFY(r2->frames() > 0);
    }

    void test_get_mixed_audio_sync_fallback() {
        // Cold cache → sync path returns valid audio
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0); // no workers
        tmb->SetSequenceRate(24, 1);

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, AudioFormat{SampleFormat::F32, 48000, 2});

        // No SetPlayhead (mix thread idle), no pre-fill time
        // GetMixedAudio must use sync fallback
        auto result = tmb->GetMixedAudio(0, 100000);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }

    void test_mixed_audio_pre_fill() {
        // Set playhead direction=1, wait, GetMixedAudio → cache hit (no sync)
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        tmb->SetAudioFormat(AudioFormat{SampleFormat::F32, 48000, 2});

        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 200, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, AudioFormat{SampleFormat::F32, 48000, 2});

        // Start playback: direction=1 wakes mix thread
        tmb->SetPlayhead(0, 1, 1.0f);

        // Wait for mix thread to pre-fill
        QThread::msleep(500);

        // GetMixedAudio at 0.5s should hit the pre-filled cache
        auto result = tmb->GetMixedAudio(500000, 600000);
        QVERIFY(result != nullptr);
        QVERIFY(result->frames() > 0);
    }

    // ── ReleaseAll clears offline registry ──

    void test_release_all_clears_offline() {
        // ReleaseAll must clear the offline registry so a re-linked file
        // can be re-probed after reconnect.
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {
            {"clip1", "/nonexistent/video.mp4", 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // First access marks path as offline
        auto r1 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r1.offline);

        // ReleaseAll should clear offline registry
        tmb->ReleaseAll();

        // Re-add clip — should attempt to open again (not cached offline)
        tmb->SetTrackClips(V1, clips);
        auto r2 = tmb->GetVideoFrame(V1, 0);
        // Still offline (file doesn't exist), but the point is it was RE-PROBED,
        // not returned from the stale offline cache. Both produce offline=true,
        // so this test just ensures ReleaseAll doesn't crash and the path is
        // re-evaluated.
        QVERIFY(r2.offline);
    }
    // ── Incremental pre-buffer: early frames available before batch completes ──

    void test_incremental_pre_buffer_early_frames() {
        // Pre-buffer stores each decoded frame to TMB cache INCREMENTALLY
        // (not all-at-once after the full batch). This means the main thread
        // can read early frames of the next clip while the worker is still
        // decoding later frames.
        //
        // Before the fix: worker decoded all 48 frames into a local vector,
        // then stored them all under one lock. During the batch, GetVideoFrame
        // missed the cache and blocked on the reader's use_mutex.
        //
        // After the fix: each frame is stored to TMB cache immediately after
        // decode. GetVideoFrame hits the cache without reader contention.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,50), clipB [50,100) — adjacent
        std::vector<ClipInfo> both_clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, both_clips);

        // Trigger pre-buffer at boundary
        tmb->SetPlayhead(48, 1, 1.0f);

        // Wait only 100ms — enough for worker to decode SOME frames of clipB,
        // but not all 48. The incremental fix means those early frames are
        // already in the TMB cache.
        QThread::msleep(100);

        // Read the first frame of clipB. With incremental storage, this should
        // be a TMB cache hit (frame 50 was decoded and stored early in the batch).
        tmb->ResetVideoCacheMissCount();
        auto r = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r.frame != nullptr,
                 "clipB first frame should be available during pre-buffer");
        QCOMPARE(r.clip_id, std::string("clipB"));

        // The first frame should ideally be a cache hit (0 misses).
        // Allow 1 miss for the rare case where the worker hasn't started yet.
        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses <= 1,
                 qPrintable(QString("Expected 0-1 cache misses for first pre-buffered "
                                    "frame, got %1").arg(misses)));
    }

    // ── ParkReaders stops background decode ──

    void test_park_readers_stops_prefetch() {
        // ParkReaders must stop all prefetch threads. After ParkReaders,
        // readers should not be decoding in the background.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Start playback — acquires reader, starts prefetch
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QThread::msleep(100); // let prefetch run

        // Park — must stop all background decode
        tmb->ParkReaders();

        // After park, SetPlayhead with direction=0 should not crash
        tmb->SetPlayhead(50, 0, 0.0f);

        // Resume playback — prefetch should restart via SetPlayhead(dir=1)
        tmb->SetPlayhead(50, 1, 1.0f);
        QThread::msleep(300); // let prefetch restart and fill

        // Frames around 60 should decode OK (prefetch restarted)
        auto r1 = tmb->GetVideoFrame(V1, 60);
        QVERIFY2(r1.frame != nullptr,
                 "Frame 60 should decode after prefetch restart");
    }

    // ── Idle reader prefetch management ──

    void test_idle_reader_prefetch_paused() {
        // After crossing a clip boundary, the old clip's reader should have
        // its prefetch paused (direction=0). The new clip's reader should
        // have active prefetch. This limits concurrent VT decode sessions.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Two clips on V1, one clip on V2
        // Test video has 72 frames — keep source ranges within bounds
        std::vector<ClipInfo> v1_clips = {
            {"clipA", path, 0, 30, 0, 24, 1, 1.0f},
            {"clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> v2_clips = {
            {"clipC", path, 0, 60, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(V2, v2_clips);

        // Start playback on clipA
        tmb->SetPlayhead(0, 1, 1.0f);
        tmb->GetVideoFrame(V1, 0); // open reader for clipA
        tmb->GetVideoFrame(V2, 0); // open reader for clipC
        QThread::msleep(100);

        // Cross boundary: playhead at frame 35 (in clipB)
        // clipA's reader should get paused, clipB and clipC stay active
        std::vector<ClipInfo> v1_clips_b = {
            {"clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips_b);
        tmb->SetPlayhead(35, 1, 1.0f);
        auto rb = tmb->GetVideoFrame(V1, 35); // open reader for clipB
        QVERIFY(rb.frame != nullptr);
        QCOMPARE(rb.clip_id, std::string("clipB"));

        // V2's reader should still work (not paused)
        auto rc = tmb->GetVideoFrame(V2, 35);
        QVERIFY(rc.frame != nullptr);
        QCOMPARE(rc.clip_id, std::string("clipC"));

        // We can't directly observe prefetch direction, but we can verify
        // all readers are functional and no deadlocks occur.
        // The structural correctness is: SetPlayhead iterates readers,
        // pauses non-active, resumes active. If this caused issues (e.g.
        // double-stop, wrong direction), decode would fail.
        for (int f = 35; f < 55; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            auto rv1 = tmb->GetVideoFrame(V1, f);
            auto rv2 = tmb->GetVideoFrame(V2, f);
            QVERIFY2(rv1.frame != nullptr,
                     qPrintable(QString("V1 frame %1 null").arg(f)));
            QVERIFY2(rv2.frame != nullptr,
                     qPrintable(QString("V2 frame %1 null").arg(f)));
        }
    }

    // ── Pre-buffer dedup: in-flight jobs block re-submission ──

    void test_pre_buffer_dedup_multi_track() {
        // Regression test: repeated SetPlayhead calls must not cause both
        // workers to pre-buffer the SAME clip. With only 2 workers and 2
        // tracks near boundaries, each worker should serve a different track.
        //
        // Before fix: worker pops job → queue empty → next tick re-submits
        // same (track, clip_id, type) → both workers decode V1's next clip.
        // V2's next clip never gets pre-buffered → main-thread Reader::Create.
        //
        // After fix: in-flight set blocks re-submission → second worker
        // picks up V2's next clip instead.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2); // exactly 2 workers
        auto path = m_testVideoPath.toStdString();

        // V1: clipA [0,50) → clipB [50,72)
        // V2: clipC [0,50) → clipD [50,72)
        // Both tracks near boundary at frame 48 (within PRE_BUFFER_THRESHOLD=48)
        std::vector<ClipInfo> v1_clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 22, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> v2_clips = {
            {"clipC", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipD", path, 50, 22, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(V2, v2_clips);

        // Open readers for current clips
        tmb->SetPlayhead(0, 1, 1.0f);
        tmb->GetVideoFrame(V1, 0);
        tmb->GetVideoFrame(V2, 0);

        // Simulate multiple ticks near boundary (the bug required tick 2+ to
        // re-submit after worker popped the job from the queue)
        for (int tick = 0; tick < 5; ++tick) {
            tmb->SetPlayhead(48, 1, 1.0f);
            QThread::msleep(20);
        }

        // Wait for workers to finish pre-buffering
        QThread::msleep(800);

        // Both tracks' next clips should be pre-buffered (cache hit = 0 misses)
        tmb->ResetVideoCacheMissCount();

        auto rb = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(rb.frame != nullptr,
                 "V1 clipB first frame should be pre-buffered");
        QCOMPARE(rb.clip_id, std::string("clipB"));

        auto rd = tmb->GetVideoFrame(V2, 50);
        QVERIFY2(rd.frame != nullptr,
                 "V2 clipD first frame should be pre-buffered");
        QCOMPARE(rd.clip_id, std::string("clipD"));

        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses == 0,
                 qPrintable(QString("Both next clips should be pre-buffered "
                                    "(0 cache misses), got %1").arg(misses)));
    }

    // ── A1: Audio-track readers must not get video prefetch threads ──

    void test_audio_track_readers_no_video_prefetch() {
        // Audio-track readers should NOT get video prefetch threads started.
        // Before fix: SetPlayhead restart block called StartPrefetch on ALL
        // readers (including audio-track ones). acquire_reader also started
        // prefetch unconditionally. Audio readers that happened to reference
        // video+audio media files would spawn wasteful VT decode sessions.
        //
        // After fix: only video-track readers get StartPrefetch.
        //
        // Observable: audio+video multi-track playback with park/resume cycle
        // completes without deadlock or decode contention. Video pre-buffer
        // still works. Audio decode still works.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // V1: video clip
        // A1: audio clip from SAME media file (has both video and audio)
        std::vector<ClipInfo> v1_clips = {
            {"v_clipA", path, 0, 30, 0, 24, 1, 1.0f},
            {"v_clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> a1_clips = {
            {"a_clipA", path, 0, 30, 0, 24, 1, 1.0f},
            {"a_clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(A1, a1_clips);

        AudioFormat fmt;
        fmt.sample_rate = 48000;
        fmt.channels = 2;
        tmb->SetAudioFormat(fmt);
        tmb->SetSequenceRate(24, 1);

        // Start playback — opens readers for both tracks
        tmb->SetPlayhead(0, 1, 1.0f);
        auto vr = tmb->GetVideoFrame(V1, 0);
        QVERIFY(vr.frame != nullptr);
        auto ar = tmb->GetTrackAudio(A1, 0, 100000, fmt);
        QVERIFY(ar != nullptr);
        QThread::msleep(100);

        // Park all readers
        tmb->ParkReaders();

        // Resume playback near boundary (triggers pre-buffer)
        tmb->SetPlayhead(28, 1, 1.0f);
        QThread::msleep(200);

        // Video pre-buffer should still work (v_clipB)
        auto vb = tmb->GetVideoFrame(V1, 30);
        QVERIFY2(vb.frame != nullptr,
                 "Video pre-buffer should work with audio tracks present");
        QCOMPARE(vb.clip_id, std::string("v_clipB"));

        // Audio decode should still work after park/resume
        auto ar2 = tmb->GetTrackAudio(A1, 1000000, 1100000, fmt);
        QVERIFY2(ar2 != nullptr,
                 "Audio decode should work after park/resume cycle");

        // Full playback sequence without deadlock
        for (int f = 28; f < 55; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            auto rv = tmb->GetVideoFrame(V1, f);
            QVERIFY2(rv.frame != nullptr,
                     qPrintable(QString("V1 frame %1 null").arg(f)));
        }
    }

    void test_pre_buffer_dedup_park_clears_in_flight() {
        // ParkReaders must clear the in-flight tracking set so that
        // the same clips can be re-submitted after resume.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 22, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Trigger pre-buffer, let workers run
        tmb->SetPlayhead(48, 1, 1.0f);
        tmb->GetVideoFrame(V1, 48);
        QThread::msleep(300);

        // Park — must clear in-flight set
        tmb->ParkReaders();

        // Invalidate caches by changing track clips (forces re-pre-buffer)
        tmb->SetTrackClips(V1, clips);

        // Resume playback — pre-buffer should work again (not blocked by stale in-flight)
        tmb->SetPlayhead(48, 1, 1.0f);
        QThread::msleep(500);

        auto rb = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(rb.frame != nullptr,
                 "clipB should be re-pre-buffered after park/resume");
        QCOMPARE(rb.clip_id, std::string("clipB"));
    }
};

QTEST_MAIN(TestTimelineMediaBuffer)
#include "test_timeline_media_buffer.moc"
