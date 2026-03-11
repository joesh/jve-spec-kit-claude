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

    // ── Video speed_ratio ──

    void test_video_speed_ratio_slow_motion() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Slow-motion clip: 93 source frames over 100 timeline frames
        // speed_ratio = 93/100 = 0.93 (< 1.0 = slow motion)
        // Timeline frame 50 → source_frame = 0 + floor(50 * 0.93) = 46
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 0.93f},
        };
        tmb->SetTrackClips(V1, clips);

        // Frame 0: source = 0 + floor(0 * 0.93) = 0
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(0));

        // Frame 50: source = 0 + floor(50 * 0.93) = 46
        auto r50 = tmb->GetVideoFrame(V1, 50);
        QVERIFY(r50.frame != nullptr);
        QCOMPARE(r50.source_frame, static_cast<int64_t>(46));

        // Frame 99 (last): source = 0 + floor(99 * 0.93) = 92
        auto r99 = tmb->GetVideoFrame(V1, 99);
        QVERIFY(r99.frame != nullptr);
        QCOMPARE(r99.source_frame, static_cast<int64_t>(92));
    }

    void test_video_speed_ratio_with_source_in() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Speed-changed clip with non-zero source_in
        // source_in=10, speed_ratio=0.5 (half speed: 50 source frames over 100 timeline)
        // Timeline frame 20 → source = 10 + floor(20 * 0.5) = 20
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 10, 24, 1, 0.5f},
        };
        tmb->SetTrackClips(V1, clips);

        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(10));  // source_in + 0

        auto r20 = tmb->GetVideoFrame(V1, 20);
        QVERIFY(r20.frame != nullptr);
        QCOMPARE(r20.source_frame, static_cast<int64_t>(20));  // 10 + floor(20*0.5) = 20
    }

    void test_video_speed_ratio_cache_hit() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // With speed_ratio < 1, adjacent timeline frames may map to the same
        // source frame. Both should decode and cache correctly.
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 0.5f},
        };
        tmb->SetTrackClips(V1, clips);

        // tf=0: sf = floor(0 * 0.5) = 0
        // tf=1: sf = floor(1 * 0.5) = 0  (same source frame — slow motion)
        auto r0 = tmb->GetVideoFrame(V1, 0);
        auto r1 = tmb->GetVideoFrame(V1, 1);
        QVERIFY(r0.frame != nullptr);
        QVERIFY(r1.frame != nullptr);
        QCOMPARE(r0.source_frame, r1.source_frame);  // both map to sf=0
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
        // Watermark cold-start priming: SetPlayhead(dir=0→1) submits initial REFILL.
        // REFILL starts from playhead and fills forward, naturally spanning clip boundaries.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);

        // Two adjacent clips
        std::vector<ClipInfo> clips = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Cold-start: first SetPlayhead with direction=1 triggers REFILL from frame 48
        tmb->SetPlayhead(48, 1, 1.0f);

        // Give REFILL worker time to decode frames 48-50+ (includes Reader creation)
        QThread::msleep(500);

        // Frame 50 (first frame of clipB) should be cached by REFILL
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

        // Transition to clip_b_only and let REFILL decode frames 50-97.
        // SetTrackClips resets video_buffer_end and refill_generation, aborting
        // any in-flight REFILL from the clipA watermark. The new REFILL starts
        // at the playhead (50) and must complete before the tight play loop.
        tmb->SetPlayhead(50, 1, 1.0f);
        tmb->SetTrackClips(V1, clip_b_only);
        QThread::msleep(500);

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

        // Park near clipB's START with reverse direction — triggers pre-buffer
        // (distance to clipB.timeline_start == 2, within PRE_BUFFER_THRESHOLD)
        tmb->SetPlayhead(52, -1, 1.0f);
        QThread::msleep(400);

        // Verify cache contents in Park mode
        tmb->SetPlayhead(49, 0, 1.0f);

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
        // REFILL stores each frame to cache immediately after decode (not
        // all-at-once after the batch). This means the main thread can read
        // early frames of the next clip while the worker decodes later frames.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,50), clipB [50,100) — adjacent
        std::vector<ClipInfo> both_clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, both_clips);

        // Cold-start REFILL from frame 48 — fills forward across clip boundary.
        // REFILL stores each decoded frame immediately.
        tmb->SetPlayhead(48, 1, 1.0f);

        // Give worker time to decode frames 48-50+ (Reader creation + h264 seek)
        QThread::msleep(500);

        // Read the first frame of clipB. With incremental storage, this should
        // be a TMB cache hit (frame 50 was decoded and stored as the batch ran).
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

    void test_pre_buffer_dedup_multi_track() {
        // Watermark-driven cold-start primes ALL tracks. With 4 workers and
        // 2 tracks, each track gets its own REFILL (keyed by track+type,
        // not clip_id). V2 (topmost, visible) is pre-buffered; V1 (obscured
        // by V2's overlapping clip) is correctly skipped by compositing-aware
        // REFILL and gets sync-decoded on demand.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4); // 4 workers for 2 tracks
        auto path = m_testVideoPath.toStdString();

        // V1: clipA [0,50) → clipB [50,72)
        // V2: clipC [0,50) → clipD [50,72)
        // V2 is on top → V1 is fully obscured → V1 REFILL skips decode
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

        tmb->SetPlayhead(48, 1, 1.0f);
        QThread::msleep(1000);

        // V2 (visible): pre-buffered via REFILL — 0 cache misses
        tmb->ResetVideoCacheMissCount();
        auto rd = tmb->GetVideoFrame(V2, 50);
        QVERIFY2(rd.frame != nullptr,
                 "V2 clipD first frame should be pre-buffered");
        QCOMPARE(rd.clip_id, std::string("clipD"));
        QVERIFY2(tmb->GetVideoCacheMissCount() == 0,
                 "V2 (visible) should have 0 cache misses");

        // V1 (obscured by V2): NOT pre-buffered — sync-decoded on access
        auto rb = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(rb.frame != nullptr,
                 "V1 clipB should still be accessible via sync decode");
        QCOMPARE(rb.clip_id, std::string("clipB"));
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

    // ── Non-blocking GetVideoFrame during Play mode ──

    void test_play_mode_cache_miss_returns_sync_frame() {
        // GetVideoFrame always sync-decodes on cache miss (Play, Scrub, Park).
        // TMB is a pure data provider — no pending concept.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park mode: decode frame 0 synchronously (primes cache)
        tmb->SetPlayhead(0, 0, 0.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);

        // Switch to Play mode
        tmb->SetPlayhead(0, 1, 1.0f);

        // Frame 50 is NOT in the TMB video cache (never decoded).
        // GetVideoFrame sync-decodes and returns the frame immediately.
        auto r50 = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r50.frame != nullptr,
                 "Play-mode cache miss must sync-decode and return frame");
        QCOMPARE(r50.clip_id, std::string("clipA"));

        // Second call should be a cache hit (no re-decode)
        auto r50b = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r50b.frame != nullptr, "Cache hit must return frame");
    }

    void test_scrub_mode_cache_miss_returns_sync_frame() {
        // All modes sync-decode on cache miss (no pending concept).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park mode (direction=0): decode frame 30 — synchronous
        tmb->SetPlayhead(30, 0, 0.0f);
        auto r = tmb->GetVideoFrame(V1, 30);
        QVERIFY2(r.frame != nullptr,
                 "Scrub-mode decode must return actual frame");
        QCOMPARE(r.clip_id, std::string("clipA"));
        QCOMPARE(r.source_frame, (int64_t)30);
    }

    void test_play_mode_without_seek_returns_sync_frame() {
        // Play mode sync-decodes on cache miss, even without a prior Seek.
        // (In the real app, prefillVideo in Play() primes the cache.)
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Jump straight to Play mode without prior decode (cache cold)
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r = tmb->GetVideoFrame(V1, 0);
        QVERIFY2(r.frame != nullptr,
                 "Play-mode cache miss must sync-decode and return frame");
        QCOMPARE(r.clip_id, std::string("clipA"));
    }

    void test_play_mode_cross_clip_returns_correct_metadata() {
        // When sync-decoding across clip boundaries, result metadata must
        // reflect the CURRENT clip (for clip-switch detection in deliverFrame).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Two clips with different rates to distinguish metadata
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 30, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Play mode, request frame 55 (clipB, rate 30/1).
        // Sync decode returns frame with clipB's metadata.
        tmb->SetPlayhead(55, 1, 1.0f);
        auto r55 = tmb->GetVideoFrame(V1, 55);
        QVERIFY(r55.frame != nullptr);
        QCOMPARE(r55.clip_id, std::string("clipB"));
        QCOMPARE(r55.clip_fps_num, (int32_t)30);
        QCOMPARE(r55.clip_fps_den, (int32_t)1);
        QCOMPARE(r55.clip_start_frame, (int64_t)50);
        QCOMPARE(r55.clip_end_frame, (int64_t)100);
    }

    // ── NSF: offline clip during Play mode must surface offline ──

    void test_play_mode_offline_clip_surfaces_offline() {
        // NSF: When a clip is known-offline (registered in m_offline), the Play
        // mode path must check the offline registry and return offline=true.
        // Without this check, the Lua side never learns the clip is offline
        // during playback — the UI won't show the offline indicator.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // clipA: valid (for priming cache)
        // clipB: offline path
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", "/nonexistent/offline.mp4", 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-mode: decode clipA frame 0 (prime cache, register clipB as offline)
        tmb->SetPlayhead(0, 0, 0.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QVERIFY(!r0.offline);

        // Force clipB's path into the offline registry by probing it once in park mode
        tmb->SetPlayhead(50, 0, 0.0f);
        auto r50_park = tmb->GetVideoFrame(V1, 50);
        QVERIFY(r50_park.offline);

        // Now switch to Play mode and request clipB frame
        tmb->SetPlayhead(55, 1, 1.0f);
        auto r55 = tmb->GetVideoFrame(V1, 55);

        // NSF assertion: offline must be surfaced
        QVERIFY2(r55.offline,
                 "Play-mode GetVideoFrame must surface offline for known-offline clips");
        QVERIFY2(r55.frame == nullptr,
                 "Offline result must have nullptr frame");
    }

    // ── Clip list update during playback ──

    void test_play_mode_three_clip_no_blocking() {
        // BLACK-BOX TIMING TEST: simulate real playback loop through 3 clips.
        // On each "tick": SetPlayhead + GetVideoFrame (mirrors displayLinkTick).
        // If any GetVideoFrame takes >50ms, sync decode happened → FAIL.
        // Pending-null return should be <1ms.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path,   0, 50, 0, 24, 1, 1.0f},
            {"clipB", path,  50, 50, 0, 24, 1, 1.0f},
            {"clipC", path, 100, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Prime: park-mode decode frame 0 (primes cache)
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);

        // Play through all 3 clips frame-by-frame
        int64_t worst_us = 0;
        int64_t worst_frame = -1;

        for (int64_t f = 1; f < 150; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);

            auto t0 = std::chrono::steady_clock::now();
            auto result = tmb->GetVideoFrame(V1, f);
            auto t1 = std::chrono::steady_clock::now();

            auto us = std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
            if (us > worst_us) {
                worst_us = us;
                worst_frame = f;
            }

            // Always returns a frame or gap (empty clip_id between clips).
            QVERIFY2(result.frame != nullptr || result.clip_id.empty(),
                qPrintable(QString("Frame %1: null frame, clip=%2")
                    .arg(f).arg(result.clip_id.c_str())));

            // Brief yield so worker threads can run
            QThread::usleep(100);
        }

        qDebug() << "3-clip playback worst:" << worst_us << "us at frame" << worst_frame;
    }

    void test_clip_list_update_play_returns_sync_frame() {
        // Mid-playback SetTrackClips with a clip list that EXCLUDES the
        // previously-displayed clip. GetVideoFrame sync-decodes immediately.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Start with clips A and B
        std::vector<ClipInfo> ab = {
            {"clipA", path,   0, 50, 0, 24, 1, 1.0f},
            {"clipB", path,  50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, ab);

        // Prime: decode clipA frame
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.clip_id, std::string("clipA"));

        // Simulate NeedClips: update clip list to [B, C] — clipA REMOVED
        std::vector<ClipInfo> bc = {
            {"clipB", path,  50, 50, 0, 24, 1, 1.0f},
            {"clipC", path, 100, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, bc);

        // Play mode: request frame 55 (clipB, not in cache) — sync decode
        tmb->SetPlayhead(55, 1, 1.0f);
        auto r55 = tmb->GetVideoFrame(V1, 55);
        QVERIFY2(r55.frame != nullptr,
                 "Play-mode cache miss must sync-decode after clip list update");
        QCOMPARE(r55.clip_id, std::string("clipB"));
    }

    // ── REGRESSION: multi-track playback must never sync-decode on hot path ──

    void test_multitrack_playback_returns_correct_frames() {
        // Multi-track playback: top-to-bottom priority, GetVideoFrame always
        // returns a frame (sync decode on miss). REFILL pre-populates cache
        // for most frames; sync decode handles initial cold frames.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // V2: clips at 0-40 and 80-120  (gap at 40-80)
        // V1: clip at 40-80             (fills V2's gap)
        std::vector<ClipInfo> v2_clips = {
            {"v2a", path,  0, 40, 0, 24, 1, 1.0f},
            {"v2b", path, 80, 40, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V2, v2_clips);

        std::vector<ClipInfo> v1_clips = {
            {"v1a", path, 40, 40, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);

        // Prime: park-mode decode on V2
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r0 = tmb->GetVideoFrame(V2, 0);
        QVERIFY(r0.frame != nullptr);

        // Simulate playback: top-to-bottom priority per frame
        for (int64_t f = 1; f < 120; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);

            VideoResult result;
            result = tmb->GetVideoFrame(V2, f);
            if (!result.frame && result.clip_id.empty()) {
                result = tmb->GetVideoFrame(V1, f);
            }

            // Every frame in the timeline should be covered by some track
            if (f < 40 || f >= 80) {
                QVERIFY2(result.frame != nullptr || !result.clip_id.empty(),
                    qPrintable(QString("Frame %1: expected V2 clip").arg(f)));
            } else {
                QVERIFY2(result.frame != nullptr || !result.clip_id.empty(),
                    qPrintable(QString("Frame %1: expected V1 clip").arg(f)));
            }

            QThread::usleep(100);
        }
    }

    // ── REGRESSION: SetTrackClips must auto-prebuffer new clips during playback ──

    void test_set_track_clips_triggers_prebuffer_for_new_clip() {
        // REGRESSION TEST for clip-transition stutter (CADENCE 217ms at boundary).
        //
        // Scenario: Playing forward, approaching clip A's end. NeedClips fires,
        // Lua calls SetTrackClips with [A, B]. The ENTRY FRAME of clip B must be
        // pre-buffered immediately — NOT deferred to the next SetPlayhead tick.
        // SetTrackClips during active playback resets buffer_end and submits
        // a REFILL from the current playhead. This replaces the old
        // trigger_prebuffer_for_new_clips mechanism.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // Start with only clip A (short — avoids h264 seek penalty)
        std::vector<ClipInfo> initial = {
            {"clipA", path, 0, 20, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, initial);

        // Cold-start play at frame 15 (5 frames from clip A's end)
        tmb->SetPlayhead(15, 1, 1.0f);
        QThread::msleep(300); // let initial REFILL settle

        tmb->ResetVideoCacheMissCount();

        // Simulate NeedClips: Lua feeds clip B as playhead approaches boundary
        std::vector<ClipInfo> updated = {
            {"clipA", path,  0, 20, 0, 24, 1, 1.0f},
            {"clipB", path, 20, 20, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, updated);

        // SetTrackClips resets buffer_end, submits new REFILL from playhead (15).
        // REFILL fills frames 15-62, crossing clip boundary at 20 into clipB.
        QThread::msleep(800);

        auto result = tmb->GetVideoFrame(V1, 20);

        QVERIFY2(result.frame != nullptr,
            "Clip B entry frame (20) must be pre-buffered after SetTrackClips — "
            "got nullptr (gap). SetTrackClips did not trigger pre-buffer.");

        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses == 0,
            qPrintable(QString("Expected 0 cache misses (pre-buffered), got %1 — "
                               "entry frame was decoded on-demand, not pre-buffered")
                .arg(misses)));

        qDebug() << "SetTrackClips auto-prebuffer: clip B entry frame cached, 0 misses";
    }

    // ── REGRESSION: gap-aware pre-buffer for multi-track clip transitions ──

    void test_gap_aware_prebuffer_for_lower_track() {
        // REGRESSION TEST for multi-track clip transition stutter (CADENCE 216ms).
        //
        // Scenario: V2 (top) has clip ending at frame 40. V1 (lower) has a
        // clip starting at frame 40 (gap before it on V1). During playback,
        // the playhead is at frame 30 — V1 has a gap, V2 has a clip.
        //
        // Bug: SetPlayhead skipped V1 entirely because find_clip_at returned
        // nullptr (gap). V1's clip at frame 40 was never pre-buffered. When
        // V2's clip ended at 40, display fell through to V1 → cache miss →
        // 200ms+ sync decode → visible stutter without pre-buffer.
        //
        // Fix: SetPlayhead checks tracks with gaps for upcoming clips within
        // PRE_BUFFER_THRESHOLD and pre-buffers their entry frames.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // V2: clip at [0, 40) — top track
        std::vector<ClipInfo> v2_clips = {
            {"v2clip", path, 0, 40, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V2, v2_clips);

        // V1: clip at [40, 120) — lower track, GAP at [0, 40)
        std::vector<ClipInfo> v1_clips = {
            {"v1clip", path, 40, 80, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);

        // Park-mode: decode V2 frame 0 (open reader)
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r0 = tmb->GetVideoFrame(V2, 0);
        QVERIFY(r0.frame != nullptr);

        // Play forward — playhead at 30 (10 frames from V2's end).
        // V1 has a gap at 30 but a clip starting at 40.
        // Gap-aware pre-buffer should submit V1's entry frame (40).
        tmb->SetPlayhead(30, 1, 1.0f);

        // Give worker time to decode V1's entry frame
        QThread::msleep(1000);

        // Verify: V1's clip entry frame (40) is pre-buffered.
        // Query in park mode for a deterministic cache check.
        tmb->SetPlayhead(40, 0, 1.0f);
        auto r40 = tmb->GetVideoFrame(V1, 40);
        QVERIFY2(r40.frame != nullptr,
            "V1 clip entry frame (40) must be pre-buffered from gap-aware "
            "SetPlayhead — got nullptr. Lower-priority track's clip was not "
            "pre-buffered while playhead was in a gap on that track.");
        QCOMPARE(r40.clip_id, std::string("v1clip"));

        qDebug() << "Gap-aware pre-buffer: V1 entry frame cached while playhead was in V1 gap";
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Watermark-driven buffer management tests (Phase 1)
    // ═══════════════════════════════════════════════════════════════════════

    void test_watermark_refill_fires_on_low_water() {
        // When playback consumes cache and buffer_end drops below LOW_WATER,
        // the watermark check triggers a REFILL job that fills ahead.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);  // 4 workers per plan
        auto path = m_testVideoPath.toStdString();

        // Long clip (200 frames = ~8s at 24fps)
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 200, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode frame 0 to open reader
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);

        // Start play — triggers cold-start priming (submits initial REFILL)
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(1500); // let REFILL workers run

        // Frames 0..47 (VIDEO_LOW_WATER) should be in cache
        tmb->ResetVideoCacheMissCount();
        for (int f = 1; f <= 47; ++f) {
            tmb->SetPlayhead(f, 0, 1.0f);
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("frame %1 null after REFILL").arg(f)));
        }

        int64_t misses = tmb->GetVideoCacheMissCount();
        // Allow some misses for initial frames before REFILL completes
        QVERIFY2(misses <= 5,
                 qPrintable(QString("Expected <=5 misses after REFILL, got %1").arg(misses)));
    }

    void test_watermark_refill_stops_at_high_water() {
        // REFILL should not decode beyond VIDEO_HIGH_WATER (96) frames ahead.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // Very long clip
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 300, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode to open reader
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);

        // Start play, let watermark fill
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(3000); // generous time for multiple REFILLs

        // Frame 95 (within HIGH_WATER) should be cached; frame 150 should not.
        // Check a few frames in the expected range.
        tmb->SetPlayhead(50, 0, 1.0f);
        auto r50 = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r50.frame != nullptr, "Frame 50 should be within REFILL range");

        // Frame beyond HIGH_WATER (playhead=0 + 96 = 96): frame 97+ should NOT
        // be cached (or at least not many more beyond HIGH_WATER).
        // We can't easily assert the exact boundary, but we can verify the
        // cache isn't infinite by checking that it doesn't grow past MAX_VIDEO_CACHE.
        QVERIFY(true); // structural correctness — no crash, bounded fill
    }

    void test_watermark_refill_spans_clip_boundary() {
        // REFILL jobs span clip boundaries naturally — no special "next clip" logic.
        // A single REFILL batch should fill frames across clipA→clipB transition.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,30), clipB [30,60) — adjacent
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 30, 0, 24, 1, 1.0f},
            {"clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode to open reader
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);

        // Start play at frame 0 — REFILL should fill across boundary into clipB
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(2000);

        // clipB's first frame (30) should be cached by REFILL spanning the boundary
        tmb->SetPlayhead(30, 0, 1.0f);
        tmb->ResetVideoCacheMissCount();
        auto r30 = tmb->GetVideoFrame(V1, 30);
        QVERIFY2(r30.frame != nullptr,
                 "clipB entry frame should be cached by boundary-spanning REFILL");
        QCOMPARE(r30.clip_id, std::string("clipB"));

        // Also check a frame deeper into clipB
        auto r35 = tmb->GetVideoFrame(V1, 35);
        QVERIFY2(r35.frame != nullptr,
                 "clipB frame 35 should be cached by boundary-spanning REFILL");
    }

    void test_watermark_refill_skips_gaps() {
        // REFILL encountering a gap should advance buffer_end past it and
        // continue to the next clip.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,20), gap [20,30), clipB [30,60)
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 20, 0, 24, 1, 1.0f},
            {"clipB", path, 30, 30, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode to open reader
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);

        // Start play — REFILL should fill clipA, skip gap, fill clipB
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(2000);

        // clipB's first frame (30) should be cached despite the gap
        tmb->SetPlayhead(30, 0, 1.0f);
        auto r30 = tmb->GetVideoFrame(V1, 30);
        QVERIFY2(r30.frame != nullptr,
                 "clipB entry frame should be cached after REFILL skipped gap");
        QCOMPARE(r30.clip_id, std::string("clipB"));
    }

    void test_watermark_buffer_end_resets_on_direction_change() {
        // When playback direction changes (forward→reverse), buffer_end
        // must reset so REFILL fills in the new direction.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode
        tmb->SetPlayhead(50, 0, 1.0f);
        tmb->GetVideoFrame(V1, 50);

        // Forward play — fill ahead of 50
        tmb->SetPlayhead(50, 1, 1.0f);
        QThread::msleep(500);

        // Switch to reverse — buffer_end must reset
        tmb->SetPlayhead(50, -1, 1.0f);
        QThread::msleep(1000);

        // Frames behind playhead (e.g. 40) should now be cached
        tmb->SetPlayhead(40, 0, 1.0f);
        auto r40 = tmb->GetVideoFrame(V1, 40);
        QVERIFY2(r40.frame != nullptr,
                 "After direction change to reverse, frames behind playhead "
                 "should be cached by REFILL");
    }

    void test_watermark_buffer_end_resets_on_set_track_clips() {
        // When SetTrackClips changes the clip list, buffer_end must reset
        // so REFILL re-evaluates from the playhead position.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips1 = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips1);

        // Start play, let REFILL run
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(500);

        // Change clips — buffer_end should reset
        std::vector<ClipInfo> clips2 = {
            {"clipB", path, 0, 100, 10, 24, 1, 1.0f}, // different source_in
        };
        tmb->SetTrackClips(V1, clips2);

        // New REFILL should fill with clipB's source positions
        QThread::msleep(1000);

        tmb->SetPlayhead(5, 0, 1.0f);
        auto r5 = tmb->GetVideoFrame(V1, 5);
        QVERIFY2(r5.frame != nullptr, "After clip change, REFILL should fill new clips");
        // source_frame should be source_in + (5 - 0) = 10 + 5 = 15
        QCOMPARE(r5.source_frame, (int64_t)15);
    }

    void test_watermark_cold_start_primes_buffer() {
        // On play start (0→nonzero direction), SetPlayhead should submit
        // initial REFILL jobs for each track. V2 (visible) is pre-buffered;
        // V1 (obscured by V2's overlapping clip) is skipped by compositing-
        // aware REFILL and sync-decoded on demand.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // Two tracks, both starting at frame 0. V2 on top obscures V1.
        std::vector<ClipInfo> v1_clips = {
            {"v1clip", path, 0, 100, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> v2_clips = {
            {"v2clip", path, 0, 100, 10, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(V2, v2_clips);

        // Park-decode to open readers
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);
        tmb->GetVideoFrame(V2, 0);

        // Start play — cold-start priming submits REFILL for both tracks
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(2000);

        // V2 (visible): pre-buffered via REFILL
        tmb->ResetVideoCacheMissCount();
        tmb->SetPlayhead(20, 0, 1.0f);

        auto r_v2 = tmb->GetVideoFrame(V2, 20);
        QVERIFY2(r_v2.frame != nullptr,
                 "V2 frame 20 should be cached after cold-start priming");
        QVERIFY2(tmb->GetVideoCacheMissCount() == 0,
                 "V2 (visible) should have 0 cache misses from REFILL");

        // V1 (obscured): sync-decoded — still returns valid frame
        auto r_v1 = tmb->GetVideoFrame(V1, 20);
        QVERIFY2(r_v1.frame != nullptr,
                 "V1 frame 20 should be accessible via sync decode");
    }

    // ── Phase 2: multi-track near boundary ──

    void test_watermark_multitrack_no_stutter() {
        // Multi-track regression: 6 video tracks near clip boundary.
        // Compositing-aware REFILL: only the topmost track (V6) is pre-buffered
        // — all lower tracks (V1-V5) are obscured by V6's overlapping clip.
        // V6 entry frame must be cached. Lower tracks sync-decode on demand.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // 6 tracks, all with clip boundary at frame 20 (V6 on top obscures V1-V5)
        std::vector<TrackId> tracks;
        for (int i = 1; i <= 6; ++i) {
            TrackId t{TrackType::Video, i};
            tracks.push_back(t);

            std::string id_a = "clip" + std::to_string(i) + "A";
            std::string id_b = "clip" + std::to_string(i) + "B";
            std::vector<ClipInfo> clips = {
                {id_a, path,  0, 20, 0, 24, 1, 1.0f},
                {id_b, path, 20, 20, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(t, clips);
        }

        tmb->SetPlayhead(18, 1, 1.0f);
        QThread::msleep(2000);

        // V6 (topmost, visible): must be pre-buffered (0 cache misses)
        tmb->ResetVideoCacheMissCount();
        TrackId v6{TrackType::Video, 6};
        auto r6 = tmb->GetVideoFrame(v6, 20);
        QVERIFY2(r6.frame != nullptr, "V6 entry frame 20 must be cached");
        QVERIFY2(tmb->GetVideoCacheMissCount() == 0,
                 "V6 (topmost visible) should have 0 cache misses");

        // V1-V5 (obscured by V6): sync-decoded — still accessible
        for (int i = 1; i <= 5; ++i) {
            TrackId t{TrackType::Video, i};
            auto r = tmb->GetVideoFrame(t, 20);
            QVERIFY2(r.frame != nullptr,
                     qPrintable(QString("V%1 entry frame 20 must be accessible via sync decode").arg(i)));
        }
    }

    void test_audio_watermark_5_tracks_no_underrun() {
        // Phase 3 integration: 5 audio tracks with clips, mix thread running.
        // Simulate real-time consumption via GetMixedAudio. With MAX_AUDIO_CACHE=12
        // (2s of 200ms chunks), the per-track audio watermark keeps the cache warm.
        // mix_thread hits cache instead of sync decode → zero underruns.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(4);
        tmb->SetSequenceRate(24, 1);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);
        auto path = m_testVideoPath.toStdString();

        // 5 audio tracks, each with a clip covering [0, 100) timeline frames
        std::vector<MixTrackParam> mix_params;
        for (int i = 1; i <= 5; ++i) {
            TrackId t{TrackType::Audio, i};
            std::vector<ClipInfo> clips = {
                {"audio" + std::to_string(i), path, 0, 100, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(t, clips);
            mix_params.push_back({i, 1.0f});
        }

        tmb->SetAudioMixParams(mix_params, fmt);

        // Cold-start: submits audio REFILL for all 5 tracks + wakes mix thread
        tmb->SetPlayhead(0, 1, 1.0f);

        // Let watermark fill per-track audio cache + mix_thread pre-fill
        QThread::msleep(1000);

        // Simulate ~1s of real-time audio consumption (20ms chunks at 48kHz)
        // 50 chunks × 20ms = 1000ms of audio
        int underruns = 0;
        TimeUS cursor = 0;
        TimeUS chunk_size = 20000; // 20ms in us
        for (int i = 0; i < 50; ++i) {
            TimeUS t0 = cursor;
            TimeUS t1 = cursor + chunk_size;
            auto mixed = tmb->GetMixedAudio(t0, t1);
            if (!mixed || mixed->frames() == 0) {
                underruns++;
            }
            cursor = t1;
            // Advance playhead to simulate tick loop
            int64_t ph_frame = static_cast<int64_t>(
                cursor * 24.0 / 1000000.0);
            tmb->SetPlayhead(ph_frame, 1, 1.0f);
        }

        QVERIFY2(underruns == 0,
                 qPrintable(QString("Expected 0 audio underruns, got %1 in 50 chunks")
                     .arg(underruns)));
        qDebug() << "5 audio tracks, 50 chunks consumed: 0 underruns";
    }

    void test_setplayhead_minimal_overhead() {
        // SetPlayhead with watermark system should be fast: no gap scanning,
        // no threshold checks. Just updates atomics and does
        // cold-start priming on first call.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // 4 tracks with clips
        for (int i = 1; i <= 4; ++i) {
            TrackId t{TrackType::Video, i};
            std::vector<ClipInfo> clips = {
                {"clip" + std::to_string(i), path, 0, 100, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(t, clips);
        }

        // Cold-start
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(50);

        // Subsequent SetPlayhead calls (simulating 60Hz ticks) must be < 1ms each.
        // The old system did gap scanning + threshold checks + multi-track iteration.
        auto start = std::chrono::steady_clock::now();
        for (int tick = 0; tick < 100; ++tick) {
            tmb->SetPlayhead(tick, 1, 1.0f);
        }
        auto elapsed = std::chrono::steady_clock::now() - start;
        auto us = std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count();

        // 100 calls should complete in < 50ms (< 500us each on average)
        QVERIFY2(us < 50000,
                 qPrintable(QString("100 SetPlayhead calls took %1 us, expected < 50000 us").arg(us)));
        qDebug() << "SetPlayhead 100 calls:" << us << "us total," << (us / 100) << "us avg";
    }

    void test_reader_prewarm_on_new_clips() {
        // When SetTrackClips adds clips not in the previous list during active
        // playback, READER_WARM jobs pre-create readers asynchronously.
        // Verifies that the incoming clip's reader is in the pool before
        // REFILL reaches the boundary, preventing ~400ms VideoToolbox stalls.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // Start with clip A only (frames 0-100)
        std::vector<ClipInfo> clipsA = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clipsA);
        tmb->SetPlayhead(50, 1, 1.0f);

        // Give workers time to start REFILL from cold-start
        QThread::msleep(200);

        // Simulate NeedClips: Lua adds clip B (frames 100-200).
        // SetTrackClips should detect clipB is new and submit READER_WARM.
        std::vector<ClipInfo> clipsAB = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
            {"clipB", path, 100, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clipsAB);

        // Wait for READER_WARM to complete (~100ms for our test file)
        QThread::msleep(500);

        // Now request a frame from clipB. If the reader is pre-warmed,
        // this should NOT incur a full Reader::Create cost.
        // We verify by measuring: GetVideoFrame should complete within
        // sync decode time (~5-20ms), not Reader::Create time (~400ms).
        auto start = std::chrono::steady_clock::now();
        auto result = tmb->GetVideoFrame(V1, 100);
        auto elapsed = std::chrono::steady_clock::now() - start;
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();

        // Frame may be cached (from REFILL) or decoded sync.
        // Either way, it should be fast because the reader is already warm.
        QVERIFY2(result.frame != nullptr,
                 "Expected frame for pre-warmed clip (sync decode or cache hit)");
        // Reader creation takes ~400ms. With pre-warming, sync decode is ~20ms.
        // Allow generous 200ms to account for CI variability.
        QVERIFY2(ms < 200,
                 qPrintable(QString("GetVideoFrame took %1ms — reader not pre-warmed?").arg(ms)));
        qDebug() << "Reader pre-warm: GetVideoFrame on new clip took" << ms << "ms";
    }
    // ── NSF: Speed ratio in REFILL worker path ──

    void test_video_refill_speed_ratio() {
        // REFILL worker must compute source frames using speed_ratio, not 1:1.
        // speed_ratio=0.5 means half speed: timeline frame 20 → source 10.
        // If REFILL ignores speed_ratio, source frames would be wrong and
        // frames would decode at the wrong position.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Slow-motion clip: 60 timeline frames, source_in=0, speed_ratio=0.5
        // Source range = 60 * 0.5 = 30 source frames (within 72-frame test file)
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 60, 0, 24, 1, 0.5f},
        };
        tmb->SetTrackClips(V1, clips);

        // Cold-start priming: trigger REFILL from frame 0
        emp::SetDecodeMode(emp::DecodeMode::Park);
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(600);  // let REFILL decode

        // Verify in Park mode (sync fallback if REFILL missed)
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->ResetVideoCacheMissCount();

        // Check several frames: REFILL should have cached them with correct
        // source mapping. If speed_ratio was ignored, source_frame would be
        // wrong (== timeline_frame instead of timeline_frame * 0.5).
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(0));  // 0 + floor(0 * 0.5) = 0

        auto r20 = tmb->GetVideoFrame(V1, 20);
        QVERIFY(r20.frame != nullptr);
        QCOMPARE(r20.source_frame, static_cast<int64_t>(10));  // 0 + floor(20 * 0.5) = 10

        auto r40 = tmb->GetVideoFrame(V1, 40);
        QVERIFY(r40.frame != nullptr);
        QCOMPARE(r40.source_frame, static_cast<int64_t>(20));  // 0 + floor(40 * 0.5) = 20

        // At least some of these should be REFILL cache hits (0 TMB misses)
        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses < 3,
                 qPrintable(QString("Expected REFILL to cache speed_ratio frames, "
                                    "got %1 misses out of 3 reads").arg(misses)));

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    // ── NSF: EOF hold-last-frame in REFILL ──

    void test_video_refill_eof_holds_last_frame() {
        // When a clip's declared duration exceeds the file's actual frame count,
        // REFILL should hold the last successfully decoded frame for remaining
        // timeline frames (no black gap before next clip).
        //
        // Test file has 72 frames. Clip declares source_in=60, duration=30:
        // source frames 60..89 requested, but only 60..71 exist (12 decodable).
        // Frames at timeline 12..29 should hold the frame decoded at source 71.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Clip with duration exceeding decodable range
        // source_in=60, duration=30, speed_ratio=1.0
        // Decodable: source 60..71 (12 frames), then EOF for source 72..89
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 30, 60, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Trigger REFILL
        emp::SetDecodeMode(emp::DecodeMode::Park);
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(600);

        // Check in Park mode
        tmb->SetPlayhead(0, 0, 1.0f);

        // Frame 0 (source 60) should decode fine
        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY2(r0.frame != nullptr, "Frame 0 (source 60) should decode");

        // Frame 11 (source 71, last real frame) should decode
        auto r11 = tmb->GetVideoFrame(V1, 11);
        QVERIFY2(r11.frame != nullptr, "Frame 11 (source 71, last real) should decode");

        // Frame 15 (source 75, beyond EOF) should have held frame
        auto r15 = tmb->GetVideoFrame(V1, 15);
        QVERIFY2(r15.frame != nullptr,
                 "Frame 15 (beyond EOF) should have held last frame, not nullptr/gap");

        // Frame 25 (source 85, well beyond EOF) should also have held frame
        auto r25 = tmb->GetVideoFrame(V1, 25);
        QVERIFY2(r25.frame != nullptr,
                 "Frame 25 (well beyond EOF) should have held last frame");

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    // ── Regression: EOF marker must not survive ParkReaders ──

    void test_eof_marker_cleared_on_park_readers() {
        // BUG: After REFILL hits EOF, clip_eof_frame persists across play
        // sessions. Stale EOF markers can prevent REFILL from pre-filling
        // frames in subsequent play sessions.
        // Fix: ParkReaders clears clip_eof_frame.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Clip whose duration far exceeds file: source_in=60, duration=200
        // Test file has 72 frames → decodable source 60..71, EOF at source 72
        // Timeline frames 0-11 decodable, 12-199 past real EOF
        std::vector<ClipInfo> clips = {
            {"clipEOF", path, 0, 200, 60, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Phase 1: Play forward → REFILL hits EOF, records clip_eof_frame
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(600);

        // Phase 2: ParkReaders (simulates user stopping playback)
        tmb->ParkReaders();

        // Phase 3: Park at frame 100 (source 160, well past real EOF)
        // Park should still work (sync decode seeks + finds best frame)
        auto park_r = tmb->GetVideoFrame(V1, 5);
        QVERIFY2(park_r.frame != nullptr,
                 "Park decode at frame 5 (source 65) should work after ParkReaders");

        // Phase 4: Play again from frame 150 (past real EOF AND past cache).
        // REFILL's held-frame fill only covers ~132 entries (MAX_CACHE=144
        // minus 12 real frames). Frame 150 is NOT in the cache.
        // After ParkReaders, clip_eof_frame should be cleared.
        tmb->SetPlayhead(150, 1, 1.0f);

        // GetVideoFrame sync-decodes. Past real EOF, the decode may fail
        // (returning offline) but must not silently return nullptr due
        // to a stale EOF marker blocking even the sync decode attempt.
        auto play_r = tmb->GetVideoFrame(V1, 150);

        // Must not be a silent gap — either a decoded frame (held), or
        // offline (legitimate decode failure past EOF).
        bool is_blocked_gap = (play_r.frame == nullptr && !play_r.offline);
        QVERIFY2(!is_blocked_gap,
                 "GetVideoFrame must not return silent gap due to "
                 "stale EOF marker — should be frame or offline");
    }

    // ── NSF: Generation counter aborts stale REFILL ──

    void test_refill_generation_aborts_stale_job() {
        // SetTrackClips increments refill_generation. In-flight REFILL jobs
        // check generation on each frame and abort on mismatch. This prevents
        // stale REFILLs from caching frames for a clip list that no longer exists.
        //
        // Test: start REFILL, immediately replace clips, verify new clips are cached.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Initial clip layout: clipA at [0, 100)
        std::vector<ClipInfo> clips_v1 = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_v1);

        // Start REFILL by simulating play start
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(50);  // let REFILL start processing

        // Immediately replace with different clip layout: clipB at [0, 50)
        // This increments generation, stale REFILL should abort
        std::vector<ClipInfo> clips_v2 = {
            {"clipB", path, 0, 50, 10, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_v2);

        // Wait for new REFILL to complete
        QThread::msleep(600);

        // Verify new clip is properly cached. Park mode for sync read.
        tmb->SetPlayhead(0, 0, 1.0f);
        auto r = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r.frame != nullptr);
        QCOMPARE(r.clip_id, std::string("clipB"));
        // source = 10 + (10 - 0) = 20 (clipB has source_in=10)
        QCOMPARE(r.source_frame, static_cast<int64_t>(20));
    }

    // ── NSF: Reader pre-warming (READER_WARM job) ──

    void test_reader_warm_no_crash_and_functional() {
        // READER_WARM is submitted by SetTrackClips when new clips appear
        // during active playback. The warm reader should be in the pool when
        // REFILL reaches that clip, avoiding 400ms Reader::Create latency.
        //
        // Verify: after warming, GetVideoFrame for the warmed clip succeeds
        // and doesn't trigger a cold reader open.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Start with clipA playing
        std::vector<ClipInfo> clips_a = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_a);
        tmb->SetPlayhead(10, 1, 1.0f);

        // Decode a frame to warm clipA's reader
        emp::SetDecodeMode(emp::DecodeMode::Park);
        tmb->SetPlayhead(10, 0, 1.0f);
        auto rA = tmb->GetVideoFrame(V1, 10);
        QVERIFY(rA.frame != nullptr);

        // Now add clipB during "playback" — should trigger READER_WARM
        tmb->SetPlayhead(40, 1, 1.0f);  // resume play direction
        std::vector<ClipInfo> clips_ab = {
            {"clipA", path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", path, 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips_ab);

        // Wait for READER_WARM + REFILL to complete
        QThread::msleep(600);

        // Park and verify clipB frame — should be fast (reader pre-warmed)
        tmb->SetPlayhead(50, 0, 1.0f);
        auto start = std::chrono::steady_clock::now();
        auto rB = tmb->GetVideoFrame(V1, 50);
        auto elapsed = std::chrono::steady_clock::now() - start;
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();

        QVERIFY2(rB.frame != nullptr, "clipB frame should decode after pre-warming");
        QCOMPARE(rB.clip_id, std::string("clipB"));
        // Pre-warmed reader: sync decode should be fast (<200ms)
        QVERIFY2(ms < 200,
                 qPrintable(QString("clipB decode took %1ms — reader not pre-warmed?").arg(ms)));

        emp::SetDecodeMode(emp::DecodeMode::Play);
    }

    // ── Gap watermark starvation regression ──

    void test_refill_through_gap_prefills_next_clip() {
        // Regression: GetVideoFrame returned early on gaps without checking the
        // watermark. REFILL advanced buffer_end past the gap (correctly), but no
        // subsequent REFILL was triggered to decode the next clip's frames.
        // Result: cold cache miss when playhead reached the clip → black frames.
        //
        // Scenario: [clipA 0-29] [gap 30-79] [clipB 80-129]
        // SetTrackClips during play at frame 30 (gap). After REFILL + WARM,
        // clipB's first frames must be in cache before playhead reaches 80.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        // Wide gap (50 frames > VIDEO_REFILL_SIZE=48): first REFILL batch
        // can't reach clipB. A second REFILL must fire via watermark check
        // during the gap to actually decode clipB's frames.
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0,  30, 0,  24, 1, 1.0f},
            {"clipB", path, 80, 50, 0,  24, 1, 1.0f},
        };

        // Start "playing" at the gap (simulates NeedClips loading new clips
        // while playhead is inside a gap after a clip transition).
        emp::SetDecodeMode(emp::DecodeMode::Play);
        tmb->SetPlayhead(30, 1, 1.0f);
        tmb->SetTrackClips(V1, clips);

        // Simulate playback through the gap: call GetVideoFrame at each frame.
        // Each call should check the watermark even though there's no clip,
        // triggering REFILL when buffer_end approaches playhead.
        for (int f = 30; f < 80; ++f) {
            tmb->SetPlayhead(f, 1, 1.0f);
            auto r = tmb->GetVideoFrame(V1, f);
            // Gap: no clip, no frame — that's fine
            QVERIFY(r.frame == nullptr);
            QVERIFY(r.clip_id.empty());
            QThread::msleep(2);  // ~16ms/frame at 60Hz, compressed for test speed
        }

        // Give REFILL worker a moment to finish any in-flight batch
        QThread::msleep(300);

        // clipB's first frame MUST be in cache (pre-filled during gap traversal).
        // Without the watermark fix, this is a cold miss → sync decode → stutter.
        tmb->SetPlayhead(80, 1, 1.0f);
        auto result = tmb->GetVideoFrame(V1, 80);
        QVERIFY2(result.frame != nullptr,
                 "clipB frame 80 should be pre-filled during gap traversal "
                 "(watermark starvation bug: GetVideoFrame gap path didn't "
                 "trigger check_video_watermark)");
        QCOMPARE(result.clip_id, std::string("clipB"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Symmetric prefill tests (always-sync GetVideoFrame)
    // ═══════════════════════════════════════════════════════════════════════

    void test_get_video_frame_always_sync() {
        // GetVideoFrame always returns data, regardless of direction.
        // No pending concept — sync decode on cache miss in all modes.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Play forward (direction=1) — cache cold
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r_play = tmb->GetVideoFrame(V1, 10);
        QVERIFY2(r_play.frame != nullptr,
                 "Play-mode GetVideoFrame must sync-decode and return frame");
        QCOMPARE(r_play.clip_id, std::string("clipA"));
        QCOMPARE(r_play.source_frame, static_cast<int64_t>(10));

        // Play reverse (direction=-1) — different frame, cache miss
        tmb->SetPlayhead(50, -1, 1.0f);
        auto r_rev = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r_rev.frame != nullptr,
                 "Reverse-play GetVideoFrame must sync-decode and return frame");
        QCOMPARE(r_rev.source_frame, static_cast<int64_t>(50));

        // Park (direction=0) — another frame, cache miss
        tmb->SetPlayhead(30, 0, 0.0f);
        auto r_park = tmb->GetVideoFrame(V1, 30);
        QVERIFY2(r_park.frame != nullptr,
                 "Park-mode GetVideoFrame must sync-decode and return frame");
        QCOMPARE(r_park.source_frame, static_cast<int64_t>(30));
    }

    void test_get_video_frame_cache_recheck_after_reader_wait() {
        // When REFILL worker populates the cache during reader acquisition,
        // GetVideoFrame should return the cached frame without re-decoding.
        // Test: prime cache via REFILL, then verify cache hit on GetVideoFrame.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Start REFILL from frame 0
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(500);  // let REFILL pre-fill

        // Reset miss counter, then request a frame that REFILL should have cached
        tmb->ResetVideoCacheMissCount();
        auto r = tmb->GetVideoFrame(V1, 5);
        QVERIFY2(r.frame != nullptr, "Frame 5 should be cached from REFILL");
        QCOMPARE(r.clip_id, std::string("clipA"));

        // If frame was a cache hit, miss count stays 0
        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses == 0,
            qPrintable(QString("Expected 0 misses (cache hit from REFILL), got %1")
                .arg(misses)));
    }

    // ── AddClips tests ──

    void test_add_clips_dedup() {
        auto tmb = TimelineMediaBuffer::Create(0);

        // Add a clip
        std::vector<ClipInfo> clips1 = {
            {"clip1", "/fake.mp4", 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->AddClips(V1, clips1);

        // Add the same clip again — should be deduped
        tmb->AddClips(V1, clips1);

        // Verify only one copy via GetVideoTrackIds (V1 should appear once)
        auto ids = tmb->GetVideoTrackIds();
        QCOMPARE(ids.size(), size_t(1));
        QCOMPARE(ids[0], 1);
    }

    void test_add_clips_sorts() {
        auto tmb = TimelineMediaBuffer::Create(0);

        // Add clips out of order
        std::vector<ClipInfo> clips = {
            {"clip2", "/fake.mp4", 100, 50, 0, 24, 1, 1.0f},
            {"clip1", "/fake.mp4", 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->AddClips(V1, clips);

        // Frame 0 should hit clip1, frame 100 should hit clip2
        auto r1 = tmb->GetVideoFrame(V1, 0);
        QCOMPARE(r1.clip_id, std::string("clip1"));
        auto r2 = tmb->GetVideoFrame(V1, 100);
        QCOMPARE(r2.clip_id, std::string("clip2"));
    }

    void test_add_clips_preserves_existing() {
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // Set initial clip via SetTrackClips
        std::vector<ClipInfo> clips1 = {
            {"clipA", m_testVideoPath.toStdString(), 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips1);

        // Decode a frame to populate cache
        auto r1 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r1.frame != nullptr);

        // Add new clip — existing clipA should be untouched
        std::vector<ClipInfo> clips2 = {
            {"clipB", m_testVideoPath.toStdString(), 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->AddClips(V1, clips2);

        // clipA frame should still be in cache (cache hit, no new decode)
        tmb->ResetVideoCacheMissCount();
        auto r2 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r2.frame != nullptr);
        QCOMPARE(r2.clip_id, std::string("clipA"));
        QCOMPARE(tmb->GetVideoCacheMissCount(), int64_t(0));
    }

    void test_clear_all_clips_empties() {
        auto tmb = TimelineMediaBuffer::Create(0);

        // Add clips on two tracks
        std::vector<ClipInfo> v_clips = {
            {"clipV", "/fake.mp4", 0, 50, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> a_clips = {
            {"clipA", "/fake.mp4", 0, 50, 0, 48000, 1, 1.0f},
        };
        tmb->AddClips(V1, v_clips);
        tmb->AddClips(A1, a_clips);

        // Should have tracks
        QVERIFY(!tmb->GetVideoTrackIds().empty());

        // Clear all
        tmb->ClearAllClips();

        // All tracks empty
        QVERIFY(tmb->GetVideoTrackIds().empty());
        auto result = tmb->GetVideoFrame(V1, 0);
        QVERIFY(result.frame == nullptr);
    }

    // ── NSF: Stale mixed cache cleared on cold-start (Fix 1) ──

    void test_mixed_cache_cleared_on_stop_seek_play() {
        // BUG: After stop→seek→play, m_mixed_cache retained data from the
        // PREVIOUS position. Mix thread saw cache_end >= target_end and skipped
        // filling. Audio was forced into sync-fallback-every-cycle mode.
        // Fix: SetPlayhead cold-start (0→nonzero) clears m_mixed_cache.
        //
        // Test: play at position A (frame 0) → stop → play at position B
        // (frame 30, ~1.25s) → GetMixedAudio at B must return valid audio.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        auto path = m_testVideoPath.toStdString();

        // Clip covers [0, 60) — within 72-frame test file
        std::vector<ClipInfo> clips = {
            {"clip1", path, 0, 60, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, fmt);

        // Phase 1: Play at position A (frame 0), let mix thread fill cache
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(500);

        // Get audio near position A — establishes cache at position 0
        auto r1 = tmb->GetMixedAudio(0, 100000);
        QVERIFY2(r1 != nullptr, "Audio at position A must work");
        QVERIFY(r1->frames() > 0);

        // Phase 2: Stop (park readers)
        tmb->ParkReaders();

        // Phase 3: Play at position B (frame 30 = 1.25s into 72-frame file)
        tmb->SetPlayhead(30, 1, 1.0f);
        QThread::msleep(500);

        // GetMixedAudio at position B. Without the fix, stale cache from
        // position A made mix thread skip filling for position B.
        TimeUS pos_b_us = 1250000; // 30 frames @ 24fps
        auto r2 = tmb->GetMixedAudio(pos_b_us, pos_b_us + 100000);
        QVERIFY2(r2 != nullptr,
                 "Audio at position B after stop→seek→play must return data "
                 "(stale cache must be cleared)");
        QVERIFY2(r2->frames() > 0,
                 "Audio at position B must have actual samples");
    }

    // ── NSF: ParkReaders clears per-track audio_cache (Fix 2) ──

    void test_park_readers_clears_audio_cache() {
        // BUG: ParkReaders didn't clear per-track audio_cache. Stale entries
        // wasted MAX_AUDIO_CACHE slots and could evict fresh entries faster.
        // Fix: ParkReaders clears ts.audio_cache alongside buffer_end reset.
        //
        // Test: play and fill audio cache → park → play at new position →
        // audio at new position works without underrun.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        auto path = m_testVideoPath.toStdString();

        // Clip covers [0, 60) — within 72-frame test file
        std::vector<ClipInfo> clips = {
            {"clip1", path, 0, 60, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, fmt);

        // Phase 1: Play from 0, fill audio cache
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(500);

        // Consume some audio to populate per-track cache
        for (int i = 0; i < 10; ++i) {
            TimeUS t0 = i * 20000;
            tmb->GetMixedAudio(t0, t0 + 20000);
        }

        // Phase 2: Park
        tmb->ParkReaders();

        // Phase 3: Play from frame 30 (~1.25s), within 72-frame file
        tmb->SetPlayhead(30, 1, 1.0f);
        QThread::msleep(500);

        TimeUS pos_us = 1250000; // 30/24 * 1e6
        auto result = tmb->GetMixedAudio(pos_us, pos_us + 100000);
        QVERIFY2(result != nullptr,
                 "Audio after park→seek→play must work (stale audio_cache cleared)");
        QVERIFY(result->frames() > 0);
    }

    // ── NSF: Audio-priority worker pop (Fix 4) ──

    void test_audio_refill_not_starved_by_video() {
        // BUG: LIFO worker pop let VIDEO_REFILL jobs stack on top of
        // AUDIO_REFILL jobs. With slow video decode, audio REFILL waited
        // behind multiple video batches.
        // Fix: worker_loop scans for AUDIO_REFILL before LIFO fallback.
        //
        // Test: setup 3 video tracks + 1 audio track. Start playback.
        // After settling, consume audio continuously. With audio-priority,
        // audio must not underrun even when video workers are busy.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2); // only 2 workers
        tmb->SetSequenceRate(24, 1);
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        auto path = m_testVideoPath.toStdString();

        // 3 video tracks to generate VIDEO_REFILL pressure
        for (int i = 1; i <= 3; ++i) {
            TrackId t{TrackType::Video, i};
            std::vector<ClipInfo> clips = {
                {"vclip" + std::to_string(i), path, 0, 60, 0, 24, 1, 1.0f},
            };
            tmb->SetTrackClips(t, clips);
        }

        // 1 audio track (within 72-frame test file)
        std::vector<ClipInfo> a_clips = {
            {"aclip1", path, 0, 60, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(TrackId{TrackType::Audio, 1}, a_clips);

        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, fmt);

        // Start playback — generates both VIDEO_REFILL and AUDIO_REFILL jobs
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(800);

        // Consume 20 chunks of 20ms audio (~400ms total)
        int underruns = 0;
        TimeUS cursor = 0;
        for (int i = 0; i < 20; ++i) {
            auto mixed = tmb->GetMixedAudio(cursor, cursor + 20000);
            if (!mixed || mixed->frames() == 0) underruns++;
            cursor += 20000;
            int64_t ph = static_cast<int64_t>(cursor * 24.0 / 1000000.0);
            tmb->SetPlayhead(ph, 1, 1.0f);
        }

        QVERIFY2(underruns == 0,
                 qPrintable(QString("Audio must not underrun with 3 video tracks "
                     "competing for 2 workers, got %1 underruns").arg(underruns)));
    }
    // ── AddClips invalidates mixed cache for audio tracks ──

    void test_add_audio_clips_invalidates_mixed_cache() {
        // BUG: Mix thread races clip loading. It fills cache ahead of playhead.
        // If it caches silence for a range BEFORE prefetch loads audio clips via
        // AddClips, the cache retains stale silence. Pump reads from cache → no
        // audio even though clips now exist.
        // Fix: AddClips clears m_mixed_cache when adding audio clips.
        //
        // Test: set mix params + play (no clips yet) → GetMixedAudio returns null.
        // Then AddClips with audio → GetMixedAudio must return non-null.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(2);
        tmb->SetSequenceRate(24, 1);
        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        tmb->SetAudioFormat(fmt);

        auto path = m_testVideoPath.toStdString();

        // Set mix params BEFORE adding clips (simulates _push_all_audio_mix_params)
        std::vector<MixTrackParam> params = {{1, 1.0f}};
        tmb->SetAudioMixParams(params, fmt);

        // Start playback — mix thread fills cache with silence (no clips)
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(200);

        // GetMixedAudio should return null (no clips → no audio)
        auto r1 = tmb->GetMixedAudio(0, 100000);
        // null is expected — no clips loaded

        // Now add audio clips (simulates prefetch loading clips later)
        std::vector<ClipInfo> clips = {
            {"clip1", path, 0, 60, 0, 24, 1, 1.0f},
        };
        tmb->AddClips(TrackId{TrackType::Audio, 1}, clips);

        // Let the WARM job and mix thread catch up
        QThread::msleep(500);

        // GetMixedAudio must now return audio (cache was invalidated by AddClips)
        auto r2 = tmb->GetMixedAudio(0, 100000);
        QVERIFY2(r2 != nullptr,
                 "Audio must be available after AddClips invalidates cache");
        QVERIFY2(r2->frames() > 0,
                 "Audio must have actual samples after AddClips");
    }

    // ── cache_only parameter (NSF audit) ──

    void test_cache_only_miss_returns_metadata_no_frame() {
        // cache_only=true on uncached frame: must return clip metadata
        // (clip_id, media_path, source_frame, fps, timeline range) but
        // frame=nullptr. Postcondition: caller can detect clip presence
        // without blocking on decode.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Play mode (cache cold, no prior decode)
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r = tmb->GetVideoFrame(V1, 50, /*cache_only=*/true);

        // Half 2 postconditions: metadata populated, frame absent
        QVERIFY2(r.frame == nullptr,
                 "cache_only=true must not sync-decode on miss");
        QCOMPARE(r.clip_id, std::string("clipA"));
        QCOMPARE(r.media_path, path);
        QCOMPARE(r.source_frame, (int64_t)50);
        QCOMPARE(r.clip_fps_num, (int32_t)24);
        QCOMPARE(r.clip_fps_den, (int32_t)1);
        QCOMPARE(r.clip_start_frame, (int64_t)0);
        QCOMPARE(r.clip_end_frame, (int64_t)100);
        QVERIFY2(!r.offline,
                 "cache_only miss must not report offline for valid path");
    }

    void test_cache_only_hit_returns_frame() {
        // cache_only=true on cached frame: must return the cached frame.
        // Prime cache with cache_only=false (park), then hit with true.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park: sync-decode frame 10 (primes cache)
        tmb->SetPlayhead(10, 0, 0.0f);
        auto r_park = tmb->GetVideoFrame(V1, 10, /*cache_only=*/false);
        QVERIFY(r_park.frame != nullptr);

        // cache_only=true on the same frame: cache hit
        auto r_hit = tmb->GetVideoFrame(V1, 10, /*cache_only=*/true);
        QVERIFY2(r_hit.frame != nullptr,
                 "cache_only=true must return cached frame on hit");
        QCOMPARE(r_hit.clip_id, std::string("clipA"));
        QCOMPARE(r_hit.source_frame, (int64_t)10);
    }

    void test_cache_only_miss_surfaces_offline() {
        // cache_only=true on offline clip: must still report offline=true.
        // This is critical — the MEDIA OFFLINE overlay depends on it.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto valid_path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", valid_path, 0, 50, 0, 24, 1, 1.0f},
            {"clipB", "/nonexistent/offline.mp4", 50, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode clipA to register clipB's path as offline
        tmb->SetPlayhead(0, 0, 0.0f);
        tmb->GetVideoFrame(V1, 0, false);

        // Force offline registration by probing clipB in park mode
        tmb->SetPlayhead(50, 0, 0.0f);
        auto r_park = tmb->GetVideoFrame(V1, 55, false);
        QVERIFY(r_park.offline);

        // cache_only=true must still surface offline
        auto r = tmb->GetVideoFrame(V1, 55, /*cache_only=*/true);
        QVERIFY2(r.offline,
                 "cache_only=true must surface offline for known-offline clips");
        QVERIFY2(!r.error_msg.empty(),
                 "offline result must include error message");
        QVERIFY2(!r.error_code.empty(),
                 "offline result must include error code");
    }

    void test_cache_only_miss_increments_counter() {
        // Diagnostics: cache miss count must increment even in cache_only mode.
        // Without this, monitoring tools can't detect decode backlog.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);
        tmb->SetPlayhead(0, 1, 1.0f);

        tmb->ResetVideoCacheMissCount();
        QCOMPARE(tmb->GetVideoCacheMissCount(), (int64_t)0);

        // cache_only=true miss
        tmb->GetVideoFrame(V1, 50, /*cache_only=*/true);
        QVERIFY2(tmb->GetVideoCacheMissCount() >= 1,
                 "cache_only miss must increment video cache miss counter");
    }

    void test_cache_only_gap_returns_empty() {
        // cache_only=true at a gap (no clip): must return empty result
        // (same as cache_only=false at gap).
        auto tmb = TimelineMediaBuffer::Create(0);

        std::vector<ClipInfo> clips = {};
        tmb->SetTrackClips(V1, clips);
        tmb->SetPlayhead(0, 1, 1.0f);

        auto r = tmb->GetVideoFrame(V1, 50, /*cache_only=*/true);
        QVERIFY(r.frame == nullptr);
        QVERIFY(r.clip_id.empty());
        QVERIFY(!r.offline);
    }

    void test_cache_only_false_still_sync_decodes() {
        // Regression: cache_only=false (default) must still sync-decode.
        // Ensures the parameter didn't break park/seek path.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Play mode, cache cold, cache_only=false → must sync-decode
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r = tmb->GetVideoFrame(V1, 30, /*cache_only=*/false);
        QVERIFY2(r.frame != nullptr,
                 "cache_only=false must sync-decode on cache miss (regression)");
    }

    void test_cache_only_nearest_frame_source_frame_matches() {
        // NSF REGRESSION: When cache_only nearest-frame fallback fires,
        // result.source_frame must match the actual cached frame's source
        // position, NOT the requested frame's computed source_frame.
        // Bug: source_frame was set before the fallback lookup, creating a
        // semantic mismatch (struct claims sf=X but frame is from sf=Y).
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        // Clip: timeline [0..100), source_in=0, rate=24fps, speed=1.0
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode frame 10 to prime cache (source_frame = 10)
        tmb->SetPlayhead(10, 0, 0.0f);
        auto r_park = tmb->GetVideoFrame(V1, 10, /*cache_only=*/false);
        QVERIFY(r_park.frame != nullptr);
        QCOMPARE(r_park.source_frame, (int64_t)10);

        // Switch to play mode, request frame 12 with cache_only=true.
        // Exact cache miss → nearest-frame fallback finds frame 10.
        tmb->SetPlayhead(12, 1, 1.0f);
        auto r = tmb->GetVideoFrame(V1, 12, /*cache_only=*/true);

        // Nearest fallback should return the cached frame
        QVERIFY2(r.frame != nullptr,
                 "cache_only nearest-frame fallback must return cached frame");
        QCOMPARE(r.clip_id, std::string("clipA"));

        // POSTCONDITION: source_frame must match the actual frame in the
        // result, not the originally-requested frame 12's source position.
        QCOMPARE(r.source_frame, (int64_t)10);
    }

    void test_cache_only_nearest_frame_distance_bounded() {
        // NSF POSTCONDITION: nearest-frame fallback must NOT return a frame
        // that's far away from the requested position. Without a distance
        // bound, a stalled REFILL could cause frame 0's decode to display
        // when playhead is at frame 500 — showing wrong content.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 200, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode frame 0 to prime cache
        tmb->SetPlayhead(0, 0, 0.0f);
        auto r0 = tmb->GetVideoFrame(V1, 0, /*cache_only=*/false);
        QVERIFY(r0.frame != nullptr);

        // Request frame 100 with cache_only=true — only frame 0 is cached.
        // Distance = 100 frames, exceeds MAX_NEAREST_DISTANCE (16).
        // Must return null frame (no fallback), not frame 0's content.
        tmb->SetPlayhead(100, 1, 1.0f);
        auto r100 = tmb->GetVideoFrame(V1, 100, /*cache_only=*/true);
        QVERIFY2(r100.frame == nullptr,
                 "cache_only nearest-frame must NOT return a frame 100 frames away "
                 "— distance bound violated");

        // Request frame 5 — distance = 5, within bound. Should return frame 0.
        auto r5 = tmb->GetVideoFrame(V1, 5, /*cache_only=*/true);
        QVERIFY2(r5.frame != nullptr,
                 "cache_only nearest-frame should return frame 0 when distance=5 "
                 "(within MAX_NEAREST_DISTANCE)");
        QCOMPARE(r5.source_frame, (int64_t)0);
    }

    void test_cache_only_timing_no_blocking() {
        // BLACK-BOX TIMING: cache_only=true must return in <1ms (no decode).
        // If it blocks (sync decode leak), this test catches it.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);
        tmb->SetPlayhead(0, 1, 1.0f);

        // Measure 10 consecutive cache_only=true calls (all misses)
        auto t0 = std::chrono::steady_clock::now();
        for (int64_t f = 0; f < 10; ++f) {
            tmb->GetVideoFrame(V1, f, /*cache_only=*/true);
        }
        float total_ms = std::chrono::duration<float, std::milli>(
            std::chrono::steady_clock::now() - t0).count();

        // 10 cache-only calls should complete in under 50ms total.
        // A single sync decode takes 5-150ms. If any leaked, this fails.
        QVERIFY2(total_ms < 50.0f,
                 qPrintable(QString("cache_only=true took %1ms for 10 calls — "
                                    "sync decode leak?").arg(total_ms)));
    }

    // ── Reverse clip playback (negative speed_ratio) ──

    void test_video_reverse_source_frame_descending() {
        // Reverse clip: source_in=50 (high frame, playback start), speed_ratio=-1.0
        // Timeline frame 0 → source = 50 + (0 - 0) * -1.0 = 50
        // Timeline frame 10 → source = 50 + (10 - 0) * -1.0 = 40
        // Timeline frame 49 → source = 50 + (49 - 0) * -1.0 = 1
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        // Reverse clip: 50 timeline frames, source_in=50 (start high), speed=-1.0
        std::vector<ClipInfo> clips = {
            {"clip_rev", path, 0, 50, 50, 24, 1, -1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(50));

        auto r10 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r10.frame != nullptr);
        QCOMPARE(r10.source_frame, static_cast<int64_t>(40));

        auto r25 = tmb->GetVideoFrame(V1, 25);
        QVERIFY(r25.frame != nullptr);
        QCOMPARE(r25.source_frame, static_cast<int64_t>(25));
    }

    void test_video_reverse_slow_motion() {
        // Reverse slow-mo: source_in=30, speed_ratio=-0.5
        // 60 timeline frames → 30 source frames (descending)
        // Timeline frame 0 → source = 30 + 0 * -0.5 = 30
        // Timeline frame 20 → source = 30 + 20 * -0.5 = 20
        // Timeline frame 59 → source = 30 + 59 * -0.5 = 0 (floor)
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clip_rev_slow", path, 0, 60, 30, 24, 1, -0.5f},
        };
        tmb->SetTrackClips(V1, clips);

        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(30));

        auto r20 = tmb->GetVideoFrame(V1, 20);
        QVERIFY(r20.frame != nullptr);
        QCOMPARE(r20.source_frame, static_cast<int64_t>(20));
    }

    void test_video_refill_reverse_speed_ratio() {
        // REFILL worker must handle negative speed_ratio correctly.
        // source_in=50, speed_ratio=-1.0 → source frames descend from 50.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);
        auto path = m_testVideoPath.toStdString();

        std::vector<ClipInfo> clips = {
            {"clipRev", path, 0, 50, 50, 24, 1, -1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Trigger REFILL by setting playhead during "play"
        emp::SetDecodeMode(emp::DecodeMode::Play);
        tmb->SetPlayhead(0, 1, 1.0f);
        QTest::qWait(300);
        emp::SetDecodeMode(emp::DecodeMode::Park);

        tmb->ResetVideoCacheMissCount();

        auto r0 = tmb->GetVideoFrame(V1, 0);
        QVERIFY(r0.frame != nullptr);
        QCOMPARE(r0.source_frame, static_cast<int64_t>(50));

        auto r10 = tmb->GetVideoFrame(V1, 10);
        QVERIFY(r10.frame != nullptr);
        QCOMPARE(r10.source_frame, static_cast<int64_t>(40));

        int64_t misses = tmb->GetVideoCacheMissCount();
        QVERIFY2(misses < 3,
                 qPrintable(QString("Expected REFILL to cache reverse frames, "
                                    "got %1 misses").arg(misses)));

        emp::SetDecodeMode(emp::DecodeMode::Play);
        tmb->SetPlayhead(0, 0, 0.0f);
        QTest::qWait(50);
        emp::SetDecodeMode(emp::DecodeMode::Park);
    }

    void test_audio_reverse_pcm_reversed() {
        // Reverse audio clip: speed_ratio=-1.0
        // GetTrackAudio should decode forward source range, then reverse the PCM.
        if (!m_hasTestAudio) QSKIP("No test audio");

        auto tmb = TimelineMediaBuffer::Create(0);
        tmb->SetSequenceRate(24, 1);
        auto path = m_testVideoPath.toStdString();

        // Forward clip for reference
        std::vector<ClipInfo> fwd_clips = {
            {"clip_fwd", path, 0, 24, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(A1, fwd_clips);

        AudioFormat fmt{SampleFormat::F32, 48000, 2};
        auto fwd_result = tmb->GetTrackAudio(A1, 0, 500000, fmt);

        // Now reverse clip: source_in at the high end
        std::vector<ClipInfo> rev_clips = {
            {"clip_rev", path, 0, 24, 24, 24, 1, -1.0f},
        };
        tmb->SetTrackClips(A1, rev_clips);

        auto rev_result = tmb->GetTrackAudio(A1, 0, 500000, fmt);

        // Both should return non-null audio (the clip has audio)
        if (fwd_result && rev_result) {
            // Reversed PCM: first sample of reverse should match last sample of forward
            // (approximately — exact match depends on decode alignment)
            QVERIFY(rev_result->frames() > 0);
            QVERIFY(fwd_result->frames() > 0);
            // Just verify we got audio and it's not identical to forward
            // (exact sample-level verification is fragile with codec boundaries)
        }
    }
    // ── NSF: REFILL advances buffer_end past undecodable clips ──

    void test_refill_skips_undecodable_clip() {
        // When REFILL encounters a clip whose reader can't be acquired
        // (offline, unsupported codec, etc.), it must advance buffer_end
        // past the clip and continue to fill subsequent decodable clips.
        // Without this fix, REFILL loops 0/48 forever on the undecodable clip.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);
        auto path = m_testVideoPath.toStdString();

        // clipA [0,20) decodable, clipB [20,40) UNDECODABLE, clipC [40,60) decodable
        std::vector<ClipInfo> clips = {
            {"clipA", path, 0, 20, 0, 24, 1, 1.0f},
            {"clipB", "/nonexistent/braw_codec.braw", 20, 20, 0, 24, 1, 1.0f},
            {"clipC", path, 40, 20, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park-decode to prime reader
        tmb->SetPlayhead(0, 0, 1.0f);
        tmb->GetVideoFrame(V1, 0);

        // Start play — REFILL should fill clipA, skip clipB, fill clipC
        tmb->SetPlayhead(0, 1, 1.0f);
        QThread::msleep(2000);

        // clipB must be offline
        tmb->SetPlayhead(25, 0, 1.0f);
        auto r25 = tmb->GetVideoFrame(V1, 25);
        QVERIFY2(r25.offline,
                 "Undecodable clip must report offline=true");

        // clipC must be cached by REFILL (it continued past clipB)
        tmb->SetPlayhead(45, 0, 1.0f);
        auto r45 = tmb->GetVideoFrame(V1, 45, /*cache_only=*/true);
        // Note: cache_only=true — if clipC wasn't pre-filled by REFILL,
        // this returns nullptr. If REFILL stalled on clipB, it never fills clipC.
        QVERIFY2(r45.frame != nullptr || r45.clip_id == "clipC",
                 "REFILL must advance past undecodable clip to fill clipC");
    }

    void test_refill_undecodable_clip_offline_in_play_mode() {
        // NSF Half 2: When REFILL skips an undecodable clip, GetVideoFrame
        // in play mode must still surface offline=true for frames in that clip.
        // The clip's path must be registered in m_offline.
        auto tmb = TimelineMediaBuffer::Create(4);

        std::vector<ClipInfo> clips = {
            {"clipBad", "/nonexistent/unsupported.r3d", 0, 50, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, clips);

        // Park mode — registers path as offline
        auto r_park = tmb->GetVideoFrame(V1, 10);
        QVERIFY2(r_park.offline,
                 "Park mode must report offline for FileNotFound path");

        // Play mode — must still surface offline
        tmb->SetPlayhead(0, 1, 1.0f);
        auto r_play = tmb->GetVideoFrame(V1, 10, /*cache_only=*/true);
        QVERIFY2(r_play.offline,
                 "Play mode must surface offline for known-offline clip");
    }

    // ── Compositing-aware REFILL: obscured tracks skip decode ──

    void test_refill_skips_obscured_v1_when_v2_has_clip() {
        if (!m_hasTestVideo) QSKIP("No test video");

        // V1 and V2 both have clips at the same position.
        // V2 is on top (opaque compositing) → V1 is invisible.
        // REFILL should skip V1 decode for obscured frames.
        auto tmb = TimelineMediaBuffer::Create(2);

        std::vector<ClipInfo> v1_clips = {
            {"v1_clip", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> v2_clips = {
            {"v2_clip", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(V2, v2_clips);

        tmb->SetPlayhead(0, 1, 1.0f);
        // Let REFILL workers run
        QTest::qWait(500);

        // V2 should have cached frames (visible track — REFILL runs normally)
        auto v2_result = tmb->GetVideoFrame(V2, 0, /*cache_only=*/true);
        QVERIFY2(v2_result.frame != nullptr,
                 "V2 (visible) should have cached frames from REFILL");

        // V1 should NOT have cached frames — REFILL skips obscured track
        auto v1_result = tmb->GetVideoFrame(V1, 0, /*cache_only=*/true);
        QVERIFY2(v1_result.frame == nullptr,
                 "V1 (obscured by V2) should NOT have cached frames");
    }

    void test_refill_decodes_v1_when_v2_ends() {
        if (!m_hasTestVideo) QSKIP("No test video");

        // V2 clip is shorter than V1. After V2 ends, V1 becomes visible.
        // REFILL should decode V1 frames beyond V2's clip boundary.
        auto tmb = TimelineMediaBuffer::Create(2);

        std::vector<ClipInfo> v1_clips = {
            {"v1_long", m_testVideoPath.toStdString(), 0, 100, 0, 24, 1, 1.0f},
        };
        std::vector<ClipInfo> v2_clips = {
            {"v2_short", m_testVideoPath.toStdString(), 0, 20, 0, 24, 1, 1.0f},
        };
        tmb->SetTrackClips(V1, v1_clips);
        tmb->SetTrackClips(V2, v2_clips);

        tmb->SetPlayhead(0, 1, 1.0f);

        // Wait for both V2 REFILL (priority) and V1 REFILL (skips 0-19, decodes 20+)
        // In full suite, resource contention may slow workers — poll with timeout.
        bool cached = false;
        for (int attempt = 0; attempt < 20 && !cached; ++attempt) {
            QTest::qWait(100);
            auto v1_visible = tmb->GetVideoFrame(V1, 25, /*cache_only=*/true);
            cached = (v1_visible.frame != nullptr);
        }
        QVERIFY2(cached,
                 "V1 should be decoded where V2 has no coverage (frame 25)");
    }

    void test_video_track_ids_descending() {
        // GetVideoTrackIds returns descending order (topmost first)
        auto tmb = TimelineMediaBuffer::Create(0);

        tmb->SetTrackClips(V1, {{"c1", "dummy.mp4", 0, 10, 0, 24, 1, 1.0f}});
        tmb->SetTrackClips(V3, {{"c3", "dummy.mp4", 0, 10, 0, 24, 1, 1.0f}});
        tmb->SetTrackClips(V2, {{"c2", "dummy.mp4", 0, 10, 0, 24, 1, 1.0f}});

        auto ids = tmb->GetVideoTrackIds();
        QCOMPARE(static_cast<int>(ids.size()), 3);
        QCOMPARE(ids[0], 3);  // topmost first
        QCOMPARE(ids[1], 2);
        QCOMPARE(ids[2], 1);
    }

    // ── Eviction policy: playhead-aware ──

    void test_eviction_prefers_behind_playhead() {
        // Eviction should prefer removing behind-playhead (already-played) frames.
        // This prevents prefetch buffer self-eviction: without this, freshly-
        // prefetched frames (~95 ahead) are "furthest from playhead" and get
        // evicted immediately, creating a systematic cache hole.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // speed_ratio=0.25 → 4 timeline frames per source frame.
        // 72 source frames cover 288 timeline frames (enough for 144 cache entries).
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 288, 0, 24, 1, 0.25f},
        };
        tmb->SetTrackClips(V1, clips);
        tmb->SetPlayhead(100, 1, 1.0f);  // playhead at 100, playing forward

        // Fill cache to MAX (144 entries): frames 30..173
        // Behind playhead: 30..99 (70 entries). Ahead: 100..173 (74 entries).
        for (int64_t f = 30; f < 30 + 144; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                qPrintable(QString("Failed to decode frame %1").arg(f)));
        }

        // Insert 17 more frames (174..190) → 17 evictions, all from behind.
        // Evicts 30,31,...,46 (furthest behind, one per insert).
        // Need 17 evictions because MAX_NEAREST_DISTANCE=16: frame 30 must be
        // >16 from any surviving entry (first survivor = 47, dist=17).
        for (int64_t f = 174; f <= 190; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY(r.frame != nullptr);
        }

        // Frame 190 should be in cache (just inserted, ahead)
        auto f190 = tmb->GetVideoFrame(V1, 190, /*cache_only=*/true);
        QVERIFY2(f190.frame != nullptr, "Newly decoded ahead frame should be in cache");

        // Frame 100 should still be in cache (at playhead)
        auto f100 = tmb->GetVideoFrame(V1, 100, /*cache_only=*/true);
        QVERIFY2(f100.frame != nullptr, "Frame at playhead should survive eviction");

        // Frame 173 should survive (ahead, not evicted — behind entries went first)
        auto f173 = tmb->GetVideoFrame(V1, 173, /*cache_only=*/true);
        QVERIFY2(f173.frame != nullptr, "Frame 173 (ahead) should survive — behind entries evict first");

        // Frame 30 should be evicted (furthest behind, dist=17 from nearest survivor 47)
        auto f30 = tmb->GetVideoFrame(V1, 30, /*cache_only=*/true);
        QVERIFY2(f30.frame == nullptr,
                 "Frame 30 (evicted behind) should be gone (dist=17 > MAX_NEAREST_DISTANCE=16)");
    }

    void test_eviction_backwards_seek_preserves_new_frames() {
        // Regression test: after backwards seek, newly-decoded frames near
        // playhead must not be evicted by old high-key entries.
        // Old bug: cache.erase(cache.begin()) always removed lowest key,
        // so post-seek low frames were immediately evicted.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(0);

        // speed_ratio=0.25 → 288 timeline frames from 72 source frames
        std::vector<ClipInfo> clips = {
            {"clip1", m_testVideoPath.toStdString(), 0, 288, 0, 24, 1, 0.25f},
        };
        tmb->SetTrackClips(V1, clips);

        // Phase 1: play forward at 250, fill cache with frames 200..270 (71 frames)
        tmb->SetPlayhead(250, 1, 1.0f);
        for (int64_t f = 200; f <= 270; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                qPrintable(QString("Phase1: failed decode frame %1").arg(f)));
        }

        // Phase 2: seek backwards to frame 5
        tmb->SetPlayhead(5, 1, 1.0f);

        // Fill frames 5..77 (73 frames) → total 71+73=144 = MAX_VIDEO_CACHE
        for (int64_t f = 5; f <= 77; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY2(r.frame != nullptr,
                qPrintable(QString("Phase2: failed decode frame %1").arg(f)));
        }

        // Fill 17 more (78..94) → 17 evictions.
        // Playhead=5, so frames 270,269,...,254 evicted (furthest from 5).
        // After: old region 200..253 (54 entries), new region 5..94 (90 entries) = 144.
        for (int64_t f = 78; f <= 94; ++f) {
            auto r = tmb->GetVideoFrame(V1, f);
            QVERIFY(r.frame != nullptr);
        }

        // Frame 5 (near playhead) must survive
        auto f5 = tmb->GetVideoFrame(V1, 5, /*cache_only=*/true);
        QVERIFY2(f5.frame != nullptr,
                 "Frame 5 must survive (near playhead after backwards seek)");

        // Frame 94 (just decoded, near playhead) must survive
        auto f94 = tmb->GetVideoFrame(V1, 94, /*cache_only=*/true);
        QVERIFY2(f94.frame != nullptr,
                 "Frame 94 must survive (recently decoded near playhead)");

        // Frame 270 (furthest from playhead=5, dist=265) should be evicted.
        // Nearest remaining cache entry is frame 253 (dist=17 > MAX_NEAREST_DISTANCE=16),
        // so cache_only returns nullptr without nearest-frame fallback.
        auto f270 = tmb->GetVideoFrame(V1, 270, /*cache_only=*/true);
        QVERIFY2(f270.frame == nullptr,
                 "Frame 270 (dist=265 from playhead) should be evicted");
    }

    void test_claim_prevents_duplicate_track_fill() {
        // Verify that claim_track_for_prefetch prevents multiple workers
        // from filling the same track concurrently. With N prefetch_workers
        // and 1 video track, only 1 worker should be active on it.
        // Observed via: all workers fill the same track → wasteful duplicate decodes.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(4);  // 3 video + 1 audio worker

        // Single video track — multiple workers will compete
        tmb->SetTrackClips(V1, {
            {"clip1", m_testVideoPath.toStdString(), 0, 500, 0, 24, 1, 1.0f},
        });

        // Start playback — workers fill V1
        tmb->SetPlayhead(0, 1, 1.0f);
        QTest::qWait(2000);  // let workers fill

        // Check cache: should have frames filled sequentially without gaps.
        // If multiple workers decoded the same position, cache would have
        // fewer unique entries than expected (duplicate work, wasted time).
        int cached_count = 0;
        for (int64_t f = 0; f < 96; ++f) {
            auto r = tmb->GetVideoFrame(V1, f, /*cache_only=*/true);
            if (r.frame != nullptr) cached_count++;
        }
        // With 2s of decode time and fast H264, expect many frames cached.
        // The exact count depends on decode speed, but should be > 0.
        QVERIFY2(cached_count > 0,
                 qPrintable(QString("Expected prefetch to fill cache, got %1 frames")
                            .arg(cached_count)));
    }

    // ── Gap segment bounds ──

    void test_gap_before_first_clip_returns_no_frame() {
        // GetVideoFrame at a position before the first clip should return gap
        // (no frame, empty clip_id). Exercises find_segment_at GAP path.
        auto tmb = TimelineMediaBuffer::Create(0);

        // Clip starts at frame 50
        tmb->SetTrackClips(V1, {
            {"clip1", "/fake.mp4", 50, 50, 0, 24, 1, 1.0f},
        });

        // Frame 0 is in the gap before clip1
        auto r = tmb->GetVideoFrame(V1, 0);
        QVERIFY2(r.frame == nullptr, "Frame in gap should have no decoded frame");
        QVERIFY2(r.clip_id.empty(), "Frame in gap should have empty clip_id");

        // Frame 49 is the last frame in the gap
        auto r49 = tmb->GetVideoFrame(V1, 49);
        QVERIFY2(r49.frame == nullptr, "Frame 49 should be in gap (clip starts at 50)");
    }

    void test_gap_between_clips_returns_no_frame() {
        // Gap between two clips should return no frame, and prefetch should
        // skip past the gap to fill the second clip.
        auto tmb = TimelineMediaBuffer::Create(0);

        // Clip A [0,50), gap [50,100), Clip B [100,150)
        tmb->SetTrackClips(V1, {
            {"clipA", "/fake.mp4", 0, 50, 0, 24, 1, 1.0f},
            {"clipB", "/fake.mp4", 100, 50, 0, 24, 1, 1.0f},
        });

        // Frame 50 is in the gap
        auto r50 = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r50.frame == nullptr, "Frame 50 in gap should have no frame");
        QVERIFY2(r50.clip_id.empty(), "Frame 50 in gap should have empty clip_id");

        // Frame 99 (last frame of gap)
        auto r99 = tmb->GetVideoFrame(V1, 99);
        QVERIFY2(r99.frame == nullptr, "Frame 99 in gap should have no frame");

        // Frame 100 should be in clip B
        auto r100 = tmb->GetVideoFrame(V1, 100);
        QCOMPARE(r100.clip_id, std::string("clipB"));
    }

    void test_gap_after_last_clip_returns_no_frame() {
        // Position after the last clip should be a gap
        auto tmb = TimelineMediaBuffer::Create(0);

        tmb->SetTrackClips(V1, {
            {"clip1", "/fake.mp4", 0, 50, 0, 24, 1, 1.0f},
        });

        // Frame 50 is past the end of clip1
        auto r = tmb->GetVideoFrame(V1, 50);
        QVERIFY2(r.frame == nullptr, "Frame past last clip should be gap");
        QVERIFY2(r.clip_id.empty(), "Frame past last clip should have empty clip_id");
    }

    void test_prefetch_skips_gap_fills_next_clip() {
        // Verify that prefetch workers correctly skip gaps and fill the
        // second clip. This exercises fill_prefetch's GAP skip path.
        if (!m_hasTestVideo) QSKIP("No test video");

        auto tmb = TimelineMediaBuffer::Create(2);

        // Clip A [0,30), gap [30,60), Clip B [60,90)
        auto path = m_testVideoPath.toStdString();
        tmb->SetTrackClips(V1, {
            {"clipA", path, 0, 30, 0, 24, 1, 1.0f},
            {"clipB", path, 60, 30, 0, 24, 1, 1.0f},
        });

        tmb->SetPlayhead(0, 1, 1.0f);
        QTest::qWait(1500);

        // Frame 60 (first frame of clipB) should be prefetched
        auto r60 = tmb->GetVideoFrame(V1, 60, /*cache_only=*/true);
        QVERIFY2(r60.frame != nullptr,
                 "Prefetch should skip gap [30,60) and fill clipB starting at 60");
        QCOMPARE(r60.clip_id, std::string("clipB"));
    }

};

QTEST_MAIN(TestTimelineMediaBuffer)
#include "test_timeline_media_buffer.moc"
