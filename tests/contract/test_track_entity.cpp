#include "../common/test_base.h"
#include "../../src/core/models/track.h"
#include "../../src/core/models/clip.h"
#include "../../src/core/models/sequence.h"
#include "../../src/core/models/project.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QSqlDatabase>
#include <QSqlQuery>

/**
 * Contract Test T007: Track Entity
 * 
 * Tests the Track entity API contract - video/audio track containers within sequences.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Track creation with sequence association
 * - Video vs Audio track type management
 * - Track ordering and layer management
 * - Track-level effects and properties
 * - Clip container functionality
 * - Track muting/soloing/locking states
 */
class TestTrackEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void cleanupTestCase() override;
    
    // Core entity lifecycle contract
    void testTrackCreation();
    void testTrackPersistence();
    void testTrackLoading();
    void testTrackMetadata();
    
    // Track type contract
    void testVideoTrackProperties();
    void testAudioTrackProperties();
    void testTrackTypeValidation();
    
    // Track management contract
    void testTrackOrdering();
    void testTrackLayerManagement();
    void testTrackStateManagement();
    
    // Clip relationship contract
    void testTrackClipContainer();
    void testClipPositioning();
    void testTrackDurationCalculation();
    
    // Performance contract
    void testTrackLoadPerformance();
    void testTrackRenderingPerformance();

private:
    QSqlDatabase m_database;
    QString m_projectId;
    QString m_sequenceId;
};

void TestTrackEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_track_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test project and sequence
    Project project = Project::create("Track Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Track Test Sequence", m_projectId, 24.0, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
}

void TestTrackEntity::cleanupTestCase()
{
    if (m_database.isOpen()) {
        m_database.close();
    }
    QSqlDatabase::removeDatabase("test_track_entity");
    TestBase::cleanupTestCase();
}

void TestTrackEntity::testTrackCreation()
{
    qCInfo(jveTests) << "Testing Track creation contract";
    verifyLibraryFirstCompliance();
    
    // Contract: Track::createVideo() and Track::createAudio()
    Track videoTrack = Track::createVideo("Video 1", m_sequenceId);
    Track audioTrack = Track::createAudio("Audio 1", m_sequenceId);
    
    // Video track validation
    QVERIFY(!videoTrack.id().isEmpty());
    QCOMPARE(videoTrack.name(), QString("Video 1"));
    QCOMPARE(videoTrack.sequenceId(), m_sequenceId);
    QCOMPARE(videoTrack.type(), Track::Video);
    QVERIFY(videoTrack.createdAt().isValid());
    
    // Audio track validation
    QVERIFY(!audioTrack.id().isEmpty());
    QCOMPARE(audioTrack.name(), QString("Audio 1"));
    QCOMPARE(audioTrack.sequenceId(), m_sequenceId);
    QCOMPARE(audioTrack.type(), Track::Audio);
    QVERIFY(audioTrack.createdAt().isValid());
    
    // Default states
    QVERIFY(videoTrack.isEnabled());
    QVERIFY(!videoTrack.isMuted());
    QVERIFY(!videoTrack.isSoloed());
    QVERIFY(!videoTrack.isLocked());
    QCOMPARE(videoTrack.layerIndex(), 0);
    
    verifyPerformance("Track creation", 10);
}

void TestTrackEntity::testTrackPersistence()
{
    qCInfo(jveTests) << "Testing Track persistence contract";
    
    Track track = Track::createVideo("Persistence Test", m_sequenceId);
    track.setLayerIndex(5);
    track.setMuted(true);
    track.setLocked(true);
    track.setOpacity(0.75);
    
    bool saved = track.save(m_database);
    QVERIFY(saved);
    
    // Verify database state
    QSqlQuery query(m_database);
    query.prepare("SELECT * FROM tracks WHERE id = ?");
    query.addBindValue(track.id());
    QVERIFY(query.exec());
    QVERIFY(query.next());
    
    QCOMPARE(query.value("sequence_id").toString(), m_sequenceId);
    QCOMPARE(query.value("name").toString(), track.name());
    QCOMPARE(query.value("type").toString(), QString("video"));
    QCOMPARE(query.value("layer_index").toInt(), 5);
    QCOMPARE(query.value("is_muted").toBool(), true);
    QCOMPARE(query.value("is_locked").toBool(), true);
    QCOMPARE(query.value("opacity").toDouble(), 0.75);
    
    verifyPerformance("Track save", 50);
}

void TestTrackEntity::testTrackLoading()
{
    qCInfo(jveTests) << "Testing Track loading contract";
    
    // Create and save track
    Track original = Track::createAudio("Loading Test", m_sequenceId);
    original.setLayerIndex(3);
    original.setSoloed(true);
    original.setVolume(0.8);
    QVERIFY(original.save(m_database));
    
    // Load and verify
    Track loaded = Track::load(original.id(), m_database);
    QVERIFY(loaded.isValid());
    QCOMPARE(loaded.id(), original.id());
    QCOMPARE(loaded.name(), original.name());
    QCOMPARE(loaded.sequenceId(), original.sequenceId());
    QCOMPARE(loaded.type(), Track::Audio);
    QCOMPARE(loaded.layerIndex(), 3);
    QCOMPARE(loaded.isSoloed(), true);
    QCOMPARE(loaded.volume(), 0.8);
    
    verifyPerformance("Track load", 30);
}

void TestTrackEntity::testTrackMetadata()
{
    qCInfo(jveTests) << "Testing Track metadata contract";
    
    Track track = Track::createVideo("Metadata Test", m_sequenceId);
    QDateTime created = track.createdAt();
    
    // Test metadata updates
    track.setName("Updated Metadata Test");
    track.setDescription("Test track for metadata validation");
    
    QCOMPARE(track.createdAt(), created); // Should not change
    QVERIFY(track.modifiedAt() >= created); // Should update
    QCOMPARE(track.description(), QString("Test track for metadata validation"));
}

void TestTrackEntity::testVideoTrackProperties()
{
    qCInfo(jveTests) << "Testing video track properties contract";
    
    Track videoTrack = Track::createVideo("Video Properties Test", m_sequenceId);
    
    // Video-specific properties
    QCOMPARE(videoTrack.type(), Track::Video);
    QCOMPARE(videoTrack.opacity(), 1.0); // Default full opacity
    
    // Test opacity range validation
    videoTrack.setOpacity(0.5);
    QCOMPARE(videoTrack.opacity(), 0.5);
    
    videoTrack.setOpacity(-0.1); // Invalid
    QVERIFY(videoTrack.opacity() >= 0.0); // Should clamp to valid range
    
    videoTrack.setOpacity(1.5); // Invalid
    QVERIFY(videoTrack.opacity() <= 1.0); // Should clamp to valid range
    
    // Test blend modes
    videoTrack.setBlendMode(Track::Normal);
    QCOMPARE(videoTrack.blendMode(), Track::Normal);
    
    videoTrack.setBlendMode(Track::Multiply);
    QCOMPARE(videoTrack.blendMode(), Track::Multiply);
    
    // Video tracks should not have audio properties
    QVERIFY(qIsNaN(videoTrack.volume())); // Should be undefined
    QVERIFY(qIsNaN(videoTrack.pan()));    // Should be undefined
}

void TestTrackEntity::testAudioTrackProperties()
{
    qCInfo(jveTests) << "Testing audio track properties contract";
    
    Track audioTrack = Track::createAudio("Audio Properties Test", m_sequenceId);
    
    // Audio-specific properties
    QCOMPARE(audioTrack.type(), Track::Audio);
    QCOMPARE(audioTrack.volume(), 1.0); // Default unity gain
    QCOMPARE(audioTrack.pan(), 0.0);    // Default center pan
    
    // Test volume range validation
    audioTrack.setVolume(0.5);
    QCOMPARE(audioTrack.volume(), 0.5);
    
    audioTrack.setVolume(-0.1); // Invalid
    QVERIFY(audioTrack.volume() >= 0.0); // Should clamp to valid range
    
    audioTrack.setVolume(2.0); // Valid boost
    QCOMPARE(audioTrack.volume(), 2.0);
    
    // Test pan range validation  
    audioTrack.setPan(-1.0); // Full left
    QCOMPARE(audioTrack.pan(), -1.0);
    
    audioTrack.setPan(1.0); // Full right
    QCOMPARE(audioTrack.pan(), 1.0);
    
    audioTrack.setPan(-1.5); // Invalid
    QVERIFY(audioTrack.pan() >= -1.0); // Should clamp
    
    audioTrack.setPan(1.5); // Invalid
    QVERIFY(audioTrack.pan() <= 1.0); // Should clamp
    
    // Audio tracks should not have video properties
    QVERIFY(qIsNaN(audioTrack.opacity())); // Should be undefined
    QCOMPARE(audioTrack.blendMode(), Track::None); // No blend mode
}

void TestTrackEntity::testTrackTypeValidation()
{
    qCInfo(jveTests) << "Testing track type validation contract";
    
    Track videoTrack = Track::createVideo("Video Type Test", m_sequenceId);
    Track audioTrack = Track::createAudio("Audio Type Test", m_sequenceId);
    
    // Type should be immutable after creation
    QCOMPARE(videoTrack.type(), Track::Video);
    QCOMPARE(audioTrack.type(), Track::Audio);
    
    // Verify type-specific method availability
    QVERIFY(videoTrack.supportsOpacity());
    QVERIFY(!videoTrack.supportsVolume());
    
    QVERIFY(!audioTrack.supportsOpacity());
    QVERIFY(audioTrack.supportsVolume());
    
    // Test type-based clip acceptance
    // Note: This will fail until Clip entity is implemented
    QVERIFY(videoTrack.acceptsVideoClips());
    QVERIFY(!videoTrack.acceptsAudioClips());
    
    QVERIFY(!audioTrack.acceptsVideoClips());
    QVERIFY(audioTrack.acceptsAudioClips());
}

void TestTrackEntity::testTrackOrdering()
{
    qCInfo(jveTests) << "Testing track ordering contract";
    
    // Create tracks with different layer indices
    Track track1 = Track::createVideo("Video 1", m_sequenceId);
    Track track2 = Track::createVideo("Video 2", m_sequenceId);
    Track track3 = Track::createVideo("Video 3", m_sequenceId);
    
    track1.setLayerIndex(0); // Bottom layer
    track2.setLayerIndex(1); // Middle layer  
    track3.setLayerIndex(2); // Top layer
    
    QVERIFY(track1.save(m_database));
    QVERIFY(track2.save(m_database));
    QVERIFY(track3.save(m_database));
    
    // Load tracks in order
    QList<Track> tracks = Track::loadBySequence(m_sequenceId, m_database);
    QVERIFY(tracks.size() >= 3);
    
    // Verify ordering (higher indices should render on top)
    Track bottom = tracks.first();
    Track top = tracks.last();
    QVERIFY(bottom.layerIndex() <= top.layerIndex());
}

void TestTrackEntity::testTrackLayerManagement()
{
    qCInfo(jveTests) << "Testing track layer management contract";
    
    Track track = Track::createVideo("Layer Test", m_sequenceId);
    
    // Test layer movement
    track.setLayerIndex(5);
    QCOMPARE(track.layerIndex(), 5);
    
    track.moveToLayer(10);
    QCOMPARE(track.layerIndex(), 10);
    
    // Test relative movement
    track.moveUp();
    QCOMPARE(track.layerIndex(), 11);
    
    track.moveDown();
    QCOMPARE(track.layerIndex(), 10);
    
    // Test boundary conditions
    track.setLayerIndex(0);
    track.moveDown();
    QVERIFY(track.layerIndex() >= 0); // Should not go below 0
    
    // Test layer conflicts (implementation-dependent behavior)
    Track conflictTrack = Track::createVideo("Conflict Test", m_sequenceId);
    conflictTrack.setLayerIndex(10); // Same as existing track
    
    // System should handle conflicts gracefully
    QVERIFY(conflictTrack.save(m_database));
}

void TestTrackEntity::testTrackStateManagement()
{
    qCInfo(jveTests) << "Testing track state management contract";
    
    Track track = Track::createVideo("State Test", m_sequenceId);
    
    // Test mute/solo/lock states
    QVERIFY(!track.isMuted());
    track.setMuted(true);
    QVERIFY(track.isMuted());
    
    QVERIFY(!track.isSoloed());
    track.setSoloed(true);
    QVERIFY(track.isSoloed());
    
    QVERIFY(!track.isLocked());
    track.setLocked(true);
    QVERIFY(track.isLocked());
    
    // Test enabled state
    QVERIFY(track.isEnabled());
    track.setEnabled(false);
    QVERIFY(!track.isEnabled());
    
    // Test state interactions
    track.setMuted(true);
    track.setSoloed(true);
    // Mute should override solo in most implementations
    QVERIFY(track.isEffectivelyMuted());
    
    track.setLocked(true);
    QVERIFY(!track.acceptsEditing()); // Locked tracks reject edits
}

void TestTrackEntity::testTrackClipContainer()
{
    qCInfo(jveTests) << "Testing track clip container contract";
    
    Track track = Track::createVideo("Clip Container Test", m_sequenceId);
    QVERIFY(track.save(m_database));
    
    // Initial state
    QCOMPARE(track.clipCount(), 0);
    QCOMPARE(track.duration(), qint64(0));
    QVERIFY(track.isEmpty());
    
    // Test clip operations (will fail until Clip entity implemented)
    Clip clip1 = Clip::create("Test Clip 1", "media-id-1");
    clip1.setTimelinePosition(1000, 5000); // 1s-5s
    track.addClip(clip1);
    
    QCOMPARE(track.clipCount(), 1);
    QCOMPARE(track.duration(), qint64(5000)); // Track duration = last clip end
    QVERIFY(!track.isEmpty());
    
    // Test clip positioning
    Clip clip2 = Clip::create("Test Clip 2", "media-id-2"); 
    clip2.setTimelinePosition(6000, 10000); // 6s-10s
    track.addClip(clip2);
    
    QCOMPARE(track.clipCount(), 2);
    QCOMPARE(track.duration(), qint64(10000)); // Extended to second clip
    
    // Test clip overlap detection
    Clip overlapClip = Clip::create("Overlap Clip", "media-id-3");
    overlapClip.setTimelinePosition(3000, 8000); // Overlaps both clips
    
    bool hasOverlap = track.hasOverlappingClips(overlapClip);
    QVERIFY(hasOverlap); // Should detect overlap
}

void TestTrackEntity::testClipPositioning()
{
    qCInfo(jveTests) << "Testing clip positioning contract";
    
    Track track = Track::createVideo("Positioning Test", m_sequenceId);
    
    // Test clip insertion at specific positions
    Clip clip = Clip::create("Position Test", "media-id");
    clip.setTimelinePosition(2000, 4000); // 2s-4s
    
    track.insertClipAt(clip, 2000);
    
    QList<Clip> clipsAtTime = track.getClipsAtTime(3000); // Middle of clip
    QCOMPARE(clipsAtTime.size(), 1);
    QCOMPARE(clipsAtTime.first().id(), clip.id());
    
    // Test empty timeline positions
    QList<Clip> emptyClips = track.getClipsAtTime(1000); // Before clip
    QVERIFY(emptyClips.isEmpty());
    
    emptyClips = track.getClipsAtTime(5000); // After clip
    QVERIFY(emptyClips.isEmpty());
}

void TestTrackEntity::testTrackDurationCalculation()
{
    qCInfo(jveTests) << "Testing track duration calculation contract";
    
    Track track = Track::createAudio("Duration Test", m_sequenceId);
    
    // Empty track
    QCOMPARE(track.duration(), qint64(0));
    
    // Add clips at different positions
    Clip clip1 = Clip::create("Clip 1", "media-1");
    clip1.setTimelinePosition(1000, 3000); // 1s-3s
    track.addClip(clip1);
    QCOMPARE(track.duration(), qint64(3000));
    
    Clip clip2 = Clip::create("Clip 2", "media-2");
    clip2.setTimelinePosition(5000, 8000); // 5s-8s (gap from first clip)
    track.addClip(clip2);
    QCOMPARE(track.duration(), qint64(8000)); // Duration to end of last clip
    
    // Test trimming operations
    track.trimToContent(); // Should leave duration at 8000
    QCOMPARE(track.duration(), qint64(8000));
    
    track.padToLength(10000); // Extend track
    QCOMPARE(track.duration(), qint64(10000));
    
    track.trimToLength(6000); // Trim track (may affect clips)
    QVERIFY(track.duration() <= qint64(6000));
}

void TestTrackEntity::testTrackLoadPerformance()
{
    qCInfo(jveTests) << "Testing track load performance contract";
    
    Track track = Track::createVideo("Performance Test", m_sequenceId);
    QVERIFY(track.save(m_database));
    
    m_timer.restart();
    Track loaded = Track::load(track.id(), m_database);
    QVERIFY(loaded.isValid());
    
    verifyPerformance("Track load", 30);
}

void TestTrackEntity::testTrackRenderingPerformance()
{
    qCInfo(jveTests) << "Testing track rendering performance contract";
    
    Track track = Track::createVideo("Rendering Test", m_sequenceId);
    track.setOpacity(0.8);
    track.setBlendMode(Track::Multiply);
    
    // Test rendering state calculation performance
    m_timer.restart();
    
    for (int i = 0; i < 1000; i++) {
        bool isRenderable = track.isRenderableAtTime(i * 16.67); // ~60fps
        RenderState state = track.getRenderState(i * 16.67);
        Q_UNUSED(isRenderable)
        Q_UNUSED(state)
    }
    
    verifyPerformance("1000 render state calculations", MAX_TIMELINE_RENDER_MS);
}

QTEST_MAIN(TestTrackEntity)
#include "test_track_entity.moc"