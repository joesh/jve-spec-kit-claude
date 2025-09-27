#include "../common/test_base.h"
#include "../../src/core/timeline/timeline_manager.h"
#include "../../src/core/models/sequence.h"
#include "../../src/core/models/project.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T013: Timeline Operations
 * 
 * Tests the Timeline operations API contract - professional editing operations.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Playback control (play, pause, stop, seek)
 * - Timeline navigation with J/K/L keys
 * - Frame-accurate positioning and trimming
 * - Ripple editing and gap management
 * - Snap-to behavior and magnetic timeline
 * - Performance requirements for 60fps preview
 */
class TestTimelineOperations : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testPlaybackControl();
    void testTimelineNavigation();
    void testFrameAccuracy();
    void testRippleEditing();
    void testSnapBehavior();
    void testTimelinePerformance();

private:
    QSqlDatabase m_database;
    TimelineManager* m_timelineManager;
    QString m_sequenceId;
};

void TestTimelineOperations::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_timeline_operations");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test sequence
    Project project = Project::create("Timeline Test Project");
    QVERIFY(project.save(m_database));
    
    Sequence sequence = Sequence::create("Test Timeline", project.id(), 29.97, 1920, 1080);
    // Duration is now calculated from clips, not set directly
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    m_timelineManager = new TimelineManager(this);
    m_timelineManager->loadSequence(m_sequenceId, m_database);
}

void TestTimelineOperations::testPlaybackControl()
{
    qCInfo(jveTests) << "Testing playback control contract";
    verifyLibraryFirstCompliance();
    
    // Initial state
    QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Stopped);
    QCOMPARE(m_timelineManager->currentTime(), qint64(0));
    QVERIFY(!m_timelineManager->isPlaying());
    
    // Play
    m_timelineManager->play();
    QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Playing);
    QVERIFY(m_timelineManager->isPlaying());
    
    // Pause
    m_timelineManager->pause();
    QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Paused);
    QVERIFY(!m_timelineManager->isPlaying());
    
    // Resume
    m_timelineManager->play();
    QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Playing);
    
    // Stop
    m_timelineManager->stop();
    QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Stopped);
    QCOMPARE(m_timelineManager->currentTime(), qint64(0)); // Should return to start
    
    // Seek
    m_timelineManager->seek(30000); // 30 seconds
    QCOMPARE(m_timelineManager->currentTime(), qint64(30000));
    
    verifyPerformance("Playback control operations", 10);
}

void TestTimelineOperations::testTimelineNavigation()
{
    qCInfo(jveTests) << "Testing timeline navigation contract";
    
    // J/K/L key behavior tests
    m_timelineManager->seek(60000); // Start at 1 minute
    qint64 startTime = m_timelineManager->currentTime();
    
    // K key - pause/play toggle
    m_timelineManager->handleKeyPress('K');
    if (m_timelineManager->isPlaying()) {
        QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Playing);
    } else {
        QCOMPARE(m_timelineManager->playbackState(), PlaybackState::Paused);
    }
    
    // J key - reverse play/shuttle
    m_timelineManager->handleKeyPress('J');
    // Should either start reverse playback or step backward
    QVERIFY(m_timelineManager->currentTime() <= startTime ||
            m_timelineManager->playbackDirection() == PlaybackDirection::Reverse);
    
    // L key - forward play/shuttle
    m_timelineManager->stop();
    m_timelineManager->seek(startTime);
    m_timelineManager->handleKeyPress('L');
    // Should either start forward playback or step forward
    QVERIFY(m_timelineManager->currentTime() >= startTime ||
            m_timelineManager->playbackDirection() == PlaybackDirection::Forward);
    
    // Frame stepping
    m_timelineManager->stop();
    m_timelineManager->seek(30000);
    qint64 beforeStep = m_timelineManager->currentTime();
    
    m_timelineManager->stepForward();
    qint64 afterStep = m_timelineManager->currentTime();
    qint64 frameDuration = m_timelineManager->getFrameDuration();
    QCOMPARE(afterStep - beforeStep, frameDuration);
    
    m_timelineManager->stepBackward();
    QCOMPARE(m_timelineManager->currentTime(), beforeStep);
    
    // Home/End navigation
    m_timelineManager->goToStart();
    QCOMPARE(m_timelineManager->currentTime(), qint64(0));
    
    m_timelineManager->goToEnd();
    qint64 sequenceDuration = m_timelineManager->getSequenceDuration();
    QCOMPARE(m_timelineManager->currentTime(), sequenceDuration);
}

void TestTimelineOperations::testFrameAccuracy()
{
    qCInfo(jveTests) << "Testing frame accuracy contract";
    
    // Test frame-based positioning
    double framerate = 29.97;
    qint64 frameDuration = qRound(1000.0 / framerate); // ~33.367ms per frame
    
    // Seek to specific frame numbers
    m_timelineManager->seekToFrame(100); // Frame 100
    qint64 expectedTime = 100 * frameDuration;
    qint64 actualTime = m_timelineManager->currentTime();
    QVERIFY(qAbs(actualTime - expectedTime) <= 1); // Within 1ms tolerance
    
    // Verify frame number calculation
    int frameNumber = m_timelineManager->getCurrentFrame();
    QCOMPARE(frameNumber, 100);
    
    // Test frame boundary alignment
    m_timelineManager->seek(3370); // Arbitrary time
    m_timelineManager->snapToFrame();
    int snappedFrame = m_timelineManager->getCurrentFrame();
    qint64 snappedTime = snappedFrame * frameDuration;
    QCOMPARE(m_timelineManager->currentTime(), snappedTime);
    
    // Test frame rate conversion accuracy
    TimelineManager ntscTimeline(this);
    // Load sequence first, then override framerate for testing
    ntscTimeline.loadSequence(m_sequenceId, m_database);
    ntscTimeline.setFramerate(29.97);
    
    TimelineManager palTimeline(this);
    // Load sequence first, then override framerate for testing  
    palTimeline.loadSequence(m_sequenceId, m_database);
    palTimeline.setFramerate(25.0);
    
    // Same frame number should have different times
    ntscTimeline.seekToFrame(100);
    palTimeline.seekToFrame(100);
    
    qint64 ntscTime = ntscTimeline.currentTime();
    qint64 palTime = palTimeline.currentTime();
    QVERIFY(ntscTime != palTime); // Different frame rates = different times
    QCOMPARE(palTime, qint64(4000)); // 100 frames at 25fps = 4 seconds
}

void TestTimelineOperations::testRippleEditing()
{
    qCInfo(jveTests) << "Testing ripple editing contract";
    
    // Set up timeline with clips
    m_timelineManager->seek(0);
    
    // Create test clips at different positions
    ClipInfo clip1 = {.id = "clip1", .start = 0, .end = 5000, .trackId = "track1"};
    ClipInfo clip2 = {.id = "clip2", .start = 5000, .end = 10000, .trackId = "track1"};
    ClipInfo clip3 = {.id = "clip3", .start = 10000, .end = 15000, .trackId = "track1"};
    
    m_timelineManager->addClip(clip1);
    m_timelineManager->addClip(clip2);
    m_timelineManager->addClip(clip3);
    
    // Test ripple delete - removing clip2 should shift clip3 left
    RippleOperation deleteOp;
    deleteOp.type = RippleType::Delete;
    deleteOp.clipId = "clip2";
    deleteOp.affectTracks = {"track1"};
    
    RippleResult result = m_timelineManager->performRipple(deleteOp);
    QVERIFY(result.success);
    QCOMPARE(result.affectedClips.size(), 1); // clip3 should be affected
    
    // Verify clip3 moved to where clip2 was
    ClipInfo updatedClip3 = m_timelineManager->getClip("clip3");
    QCOMPARE(updatedClip3.start, qint64(5000));
    QCOMPARE(updatedClip3.end, qint64(10000));
    
    // Test ripple insert
    ClipInfo insertClip = {.id = "insert_clip", .start = 2000, .end = 4000, .trackId = "track1"};
    
    RippleOperation insertOp;
    insertOp.type = RippleType::Insert;
    insertOp.clip = insertClip;
    insertOp.insertPosition = 2000;
    insertOp.affectTracks = {"track1"};
    
    RippleResult insertResult = m_timelineManager->performRipple(insertOp);
    QVERIFY(insertResult.success);
    QVERIFY(insertResult.affectedClips.size() >= 2); // Other clips should shift
    
    // Test gap removal
    m_timelineManager->removeGaps({"track1"});
    
    // Verify no gaps remain
    QList<TimelineGap> gaps = m_timelineManager->findGaps({"track1"});
    QVERIFY(gaps.isEmpty() || gaps.first().duration < 100); // No significant gaps
}

void TestTimelineOperations::testSnapBehavior()
{
    qCInfo(jveTests) << "Testing snap behavior contract";
    
    // Enable snapping
    m_timelineManager->setSnapEnabled(true);
    QVERIFY(m_timelineManager->isSnapEnabled());
    
    // Set snap tolerance
    m_timelineManager->setSnapTolerance(100); // 100ms tolerance
    QCOMPARE(m_timelineManager->snapTolerance(), 100);
    
    // Create snap points
    QList<qint64> snapPoints = {0, 5000, 10000, 15000, 30000};
    m_timelineManager->setSnapPoints(snapPoints);
    
    // Test snap during seek
    m_timelineManager->seek(4950); // Close to 5000 snap point
    qint64 snappedTime = m_timelineManager->getSnappedTime(4950);
    QCOMPARE(snappedTime, qint64(5000)); // Should snap to nearest point
    
    m_timelineManager->seek(5150); // Outside tolerance from 5000
    snappedTime = m_timelineManager->getSnappedTime(5150);
    QCOMPARE(snappedTime, qint64(5150)); // Should NOT snap (150ms > 100ms tolerance)
    
    // Test no snap when outside tolerance
    snappedTime = m_timelineManager->getSnappedTime(4800); // 200ms away
    QCOMPARE(snappedTime, qint64(4800)); // Should not snap
    
    // Test magnetic timeline behavior
    m_timelineManager->setMagneticTimelineEnabled(true);
    
    ClipInfo dragClip = {.id = "drag_clip", .start = 7000, .end = 9000, .trackId = "track1"};
    
    // Drag clip near snap point
    ClipDragResult dragResult = m_timelineManager->dragClip(dragClip, 4900); // Near 5000
    QVERIFY(dragResult.snapped);
    QCOMPARE(dragResult.newStart, qint64(5000)); // Should snap start to point
    QCOMPARE(dragResult.newEnd, qint64(7000));   // Duration preserved
    
    // Test snap to other clips
    ClipInfo existingClip = {.id = "existing", .start = 12000, .end = 16000, .trackId = "track1"};
    m_timelineManager->addClip(existingClip);
    
    ClipDragResult clipSnapResult = m_timelineManager->dragClip(dragClip, 11950); // Near existing clip
    QVERIFY(clipSnapResult.snapped);
    QCOMPARE(clipSnapResult.newStart, qint64(12000)); // Should snap to existing clip start
}

void TestTimelineOperations::testTimelinePerformance()
{
    qCInfo(jveTests) << "Testing timeline performance contract";
    
    // Test 60fps preview requirement (16.67ms per frame)
    m_timer.restart();
    
    // Simulate rapid seeking (60fps preview)
    qint64 frameDuration = m_timelineManager->getFrameDuration();
    for (int i = 0; i < 60; i++) {
        m_timelineManager->seek(i * frameDuration);
        
        // Simulate render time check
        if (m_timer.elapsed() > MAX_TIMELINE_RENDER_MS) {
            // Each frame must render within constitutional limit
            QFAIL(qPrintable(QString("Timeline rendering too slow: %1ms > %2ms limit")
                           .arg(m_timer.elapsed()).arg(MAX_TIMELINE_RENDER_MS)));
        }
        m_timer.restart();
    }
    
    // Test playback performance
    m_timer.restart();
    m_timelineManager->play();
    
    // Let it play for a bit
    QThread::msleep(100);
    
    m_timelineManager->pause();
    qint64 playbackTime = m_timer.elapsed();
    
    // Playback should maintain real-time performance
    QVERIFY(playbackTime < 120); // Should not take more than 120ms for 100ms of playback
    
    // Test scrubbing performance
    m_timer.restart();
    
    for (int i = 0; i < 100; i++) {
        m_timelineManager->seek(i * 100); // Scrub through timeline
    }
    
    verifyPerformance("100 scrubbing operations", 100);
    
    // Test batch operations performance
    QList<ClipInfo> manyClips;
    for (int i = 0; i < 50; i++) {
        ClipInfo clip;
        clip.id = QString("perf_clip_%1").arg(i);
        clip.start = i * 2000;
        clip.end = (i + 1) * 2000;
        clip.trackId = "perf_track";
        manyClips.append(clip);
    }
    
    m_timer.restart();
    for (const auto& clip : manyClips) {
        m_timelineManager->addClip(clip);
    }
    verifyPerformance("Add 50 clips to timeline", 200);
    
    // Test complex timeline calculation performance
    m_timer.restart();
    
    TimelineMetrics metrics = m_timelineManager->calculateMetrics();
    QVERIFY(metrics.totalDuration > 0);
    QVERIFY(metrics.clipCount >= 50);
    
    verifyPerformance("Complex timeline metrics calculation", 50);
}

QTEST_MAIN(TestTimelineOperations)
#include "test_timeline_operations.moc"