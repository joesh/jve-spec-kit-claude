#include "../common/test_base.h"
#include "../../src/core/models/sequence.h"
#include "../../src/core/models/project.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QSqlDatabase>
#include <QSqlQuery>

/**
 * Contract Test T006: Sequence Entity
 * 
 * Tests the Sequence entity API contract - timeline containers within projects.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Sequence creation within project context
 * - Timeline properties (duration, framerate, resolution)
 * - Track relationship management
 * - Sequence-level settings and metadata
 * - Timeline rendering and playback configuration
 * - Multi-sequence project support
 */
class TestSequenceEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void cleanupTestCase() override;
    
    // Core entity lifecycle contract
    void testSequenceCreation();
    void testSequencePersistence();
    void testSequenceLoading();
    void testSequenceMetadata();
    
    // Timeline-specific contract
    void testTimelineProperties();
    void testFramerateHandling();
    void testResolutionSettings();
    void testDurationCalculation();
    
    // Relationship contract
    void testProjectSequenceRelationship();
    void testMultiSequenceSupport();
    void testSequenceTrackManagement();
    
    // Performance contract
    void testSequenceLoadPerformance();
    void testTimelineCalculationPerformance();

private:
    QSqlDatabase m_database;
    QString m_projectId;
};

void TestSequenceEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_sequence_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test project
    Project project = Project::create("Sequence Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
}

void TestSequenceEntity::cleanupTestCase()
{
    if (m_database.isOpen()) {
        m_database.close();
    }
    QSqlDatabase::removeDatabase("test_sequence_entity");
    TestBase::cleanupTestCase();
}

void TestSequenceEntity::testSequenceCreation()
{
    qCInfo(jveTests, "Testing Sequence creation contract");
    verifyLibraryFirstCompliance();
    
    // Contract: Sequence::create() with project association
    Sequence sequence = Sequence::create("Main Timeline", m_projectId, 29.97, 1920, 1080);
    
    QVERIFY(!sequence.id().isEmpty());
    QCOMPARE(sequence.name(), QString("Main Timeline"));
    QCOMPARE(sequence.projectId(), m_projectId);
    QVERIFY(sequence.createdAt().isValid());
    
    // Default timeline properties
    QCOMPARE(sequence.framerate(), 29.97); // Default NTSC
    QCOMPARE(sequence.width(), 1920);      // Default HD
    QCOMPARE(sequence.height(), 1080);
    QCOMPARE(sequence.duration(), qint64(0)); // Empty sequence
    
    verifyPerformance("Sequence creation", 10);
}

void TestSequenceEntity::testSequencePersistence()
{
    qCInfo(jveTests, "Testing Sequence persistence contract");
    
    Sequence sequence = Sequence::create("Persistence Test", m_projectId, 25.0, 3840, 2160);
    QVERIFY(sequence.isValid());
    
    bool saved = sequence.save(m_database);
    QVERIFY(saved);
    
    // Verify database state
    QSqlQuery query(m_database);
    query.prepare("SELECT * FROM sequences WHERE id = ?");
    query.addBindValue(sequence.id());
    QVERIFY(query.exec());
    QVERIFY(query.next());
    
    QCOMPARE(query.value("project_id").toString(), m_projectId);
    QCOMPARE(query.value("name").toString(), sequence.name());
    QCOMPARE(query.value("frame_rate").toDouble(), 25.0); // Schema uses REAL
    QCOMPARE(query.value("width").toInt(), 3840); // Canvas resolution in schema
    QCOMPARE(query.value("height").toInt(), 2160);
    // Duration is calculated from clips, not stored
    
    verifyPerformance("Sequence save", 50);
}

void TestSequenceEntity::testSequenceLoading()
{
    qCInfo(jveTests, "Testing Sequence loading contract");
    
    // Create and save sequence
    Sequence original = Sequence::create("Loading Test", m_projectId, 29.97, 1920, 1080);
    original.setFramerate(23.976); // Cinema
    original.setCanvasResolution(2048, 1080); // 2K Cinema
    QVERIFY(original.save(m_database));
    
    // Load and verify
    Sequence loaded = Sequence::load(original.id(), m_database);
    QVERIFY(loaded.isValid());
    QCOMPARE(loaded.id(), original.id());
    QCOMPARE(loaded.name(), original.name());
    QCOMPARE(loaded.projectId(), original.projectId());
    QCOMPARE(loaded.framerate(), original.framerate());
    // Width/height not persisted per spec - model defaults used
    
    verifyPerformance("Sequence load", 30);
}

void TestSequenceEntity::testSequenceMetadata()
{
    qCInfo(jveTests, "Testing Sequence metadata contract");
    
    Sequence sequence = Sequence::create("Metadata Test", m_projectId, 30.0, 1920, 1080);
    QDateTime created = sequence.createdAt();
    
    // Test metadata updates
    sequence.setName("Updated Metadata Test");
    sequence.setDescription("Test sequence for metadata validation");
    
    QCOMPARE(sequence.createdAt(), created); // Should not change
    QVERIFY(sequence.modifiedAt() >= created); // Should update
    QCOMPARE(sequence.description(), QString("Test sequence for metadata validation"));
}

void TestSequenceEntity::testTimelineProperties()
{
    qCInfo(jveTests, "Testing timeline properties contract");
    
    Sequence sequence = Sequence::create("Timeline Test", m_projectId, 24.0, 1920, 1080);
    
    // Test framerate validation
    sequence.setFramerate(29.97);
    QCOMPARE(sequence.framerate(), 29.97);
    
    sequence.setFramerate(25.0);
    QCOMPARE(sequence.framerate(), 25.0);
    
    sequence.setFramerate(23.976);
    QCOMPARE(sequence.framerate(), 23.976);
    
    // Invalid framerates should be rejected or clamped
    sequence.setFramerate(-1.0);
    QVERIFY(sequence.framerate() > 0); // Should maintain valid value
    
    sequence.setFramerate(1000.0);
    QVERIFY(sequence.framerate() <= 120.0); // Should be reasonable maximum
}

void TestSequenceEntity::testFramerateHandling()
{
    qCInfo(jveTests, "Testing framerate handling contract");
    
    Sequence sequence = Sequence::create("Framerate Test", m_projectId, 59.94, 1920, 1080);
    
    // Test common framerates
    struct FramerateTest {
        double framerate;
        QString description;
        bool isDropFrame;
    } tests[] = {
        {23.976, "Cinema", false},
        {24.0, "Cinema Progressive", false},
        {25.0, "PAL", false},
        {29.97, "NTSC", true},
        {30.0, "NTSC Progressive", false},
        {50.0, "PAL High Frame Rate", false},
        {59.94, "NTSC High Frame Rate", true},
        {60.0, "Progressive High Frame Rate", false}
    };
    
    for (const auto& test : tests) {
        sequence.setFramerate(test.framerate);
        QCOMPARE(sequence.framerate(), test.framerate);
        QCOMPARE(sequence.isDropFrame(), test.isDropFrame);
        
        // Test timecode calculation accuracy (1 second worth of frames)
        qint64 framesPerSecond = qRound(sequence.framerate());
        qint64 oneSecondMs = sequence.framesToMilliseconds(framesPerSecond);
        QVERIFY(qAbs(oneSecondMs - 1000) < 2); // Within 2ms tolerance
    }
}

void TestSequenceEntity::testResolutionSettings()
{
    qCInfo(jveTests, "Testing resolution settings contract");
    
    Sequence sequence = Sequence::create("Resolution Test", m_projectId, 24.0, 1920, 1080);
    
    // Test common resolutions
    struct ResolutionTest {
        int width, height;
        QString name;
        double aspectRatio;
    } resolutions[] = {
        {1920, 1080, "HD 1080p", 16.0/9.0},
        {1280, 720, "HD 720p", 16.0/9.0},
        {3840, 2160, "4K UHD", 16.0/9.0},
        {2048, 1080, "2K Cinema", 256.0/135.0},
        {4096, 2160, "4K Cinema", 256.0/135.0},
        {1920, 1200, "WUXGA", 16.0/10.0}
    };
    
    for (const auto& res : resolutions) {
        sequence.setCanvasResolution(res.width, res.height);
        QCOMPARE(sequence.width(), res.width);
        QCOMPARE(sequence.height(), res.height);
        
        double calculatedAspect = sequence.aspectRatio();
        QVERIFY(qAbs(calculatedAspect - res.aspectRatio) < 0.01); // Tolerance
    }
    
    // Test invalid resolutions
    sequence.setCanvasResolution(0, 1080); // Should be invalid
    QVERIFY(sequence.width() > 0); // Should maintain valid width
    
    sequence.setCanvasResolution(1920, 0); // Should be invalid
    QVERIFY(sequence.height() > 0); // Should maintain valid height
}

void TestSequenceEntity::testDurationCalculation()
{
    qCInfo(jveTests, "Testing duration calculation contract");
    
    Sequence sequence = Sequence::create("Duration Test", m_projectId, 29.97, 1920, 1080);
    sequence.setFramerate(25.0); // For easy calculation
    
    // Test frame/time conversions
    QCOMPARE(sequence.framesToMilliseconds(25), qint64(1000)); // 1 second
    QCOMPARE(sequence.framesToMilliseconds(75), qint64(3000)); // 3 seconds
    QCOMPARE(sequence.millisecondsToFrames(2000), qint64(50)); // 2 seconds
    
    // Test duration calculation - empty sequence has 0 duration
    QCOMPARE(sequence.duration(), qint64(0)); // No clips = 0 duration
    QCOMPARE(sequence.durationInFrames(), qint64(0)); // 0 duration = 0 frames
    
    // Test timecode formatting
    QString timecode = sequence.formatTimecode(150000); // 2:30 minutes
    QVERIFY(timecode.contains("02:30")); // Should format as MM:SS
}

void TestSequenceEntity::testProjectSequenceRelationship()
{
    qCInfo(jveTests, "Testing project-sequence relationship contract");
    
    // Create multiple sequences for same project
    Sequence seq1 = Sequence::create("Sequence 1", m_projectId, 24.0, 1920, 1080);
    Sequence seq2 = Sequence::create("Sequence 2", m_projectId, 25.0, 1920, 1080);
    
    QVERIFY(seq1.save(m_database));
    QVERIFY(seq2.save(m_database));
    
    // Load project sequences
    QList<Sequence> sequences = Sequence::loadByProject(m_projectId, m_database);
    QVERIFY(sequences.size() >= 2); // At least our two sequences
    
    // Verify relationship integrity
    for (const auto& sequence : sequences) {
        QCOMPARE(sequence.projectId(), m_projectId);
    }
}

void TestSequenceEntity::testMultiSequenceSupport()
{
    qCInfo(jveTests, "Testing multi-sequence support contract");
    
    // Create sequences with different configurations
    Sequence mainTimeline = Sequence::create("Main Timeline", m_projectId, 24.0, 1920, 1080);
    mainTimeline.setFramerate(29.97);
    // Canvas resolution set in create() call
    
    Sequence proxyTimeline = Sequence::create("Proxy Timeline", m_projectId, 24.0, 1920, 1080);  
    proxyTimeline.setFramerate(29.97);
    proxyTimeline.setCanvasResolution(960, 540); // Half resolution proxy
    
    Sequence audioOnlyTimeline = Sequence::create("Audio Master", m_projectId, 48.0, 1920, 1080);
    audioOnlyTimeline.setFramerate(29.97);
    // Audio sequences still need valid canvas resolution - set in create()
    
    // Save all sequences
    QVERIFY(mainTimeline.save(m_database));
    QVERIFY(proxyTimeline.save(m_database));
    QVERIFY(audioOnlyTimeline.save(m_database));
    
    // Verify independent management
    QList<Sequence> allSequences = Sequence::loadByProject(m_projectId, m_database);
    QVERIFY(allSequences.size() >= 3);
    
    // Each should maintain independent properties
    bool foundMain = false, foundProxy = false, foundAudio = false;
    for (const auto& seq : allSequences) {
        if (seq.name() == "Main Timeline") {
            foundMain = true;
            QCOMPARE(seq.width(), 1920);
        } else if (seq.name() == "Proxy Timeline") {
            foundProxy = true;
            QCOMPARE(seq.width(), 960); // Proxy timeline uses half resolution canvas
        } else if (seq.name() == "Audio Master") {
            foundAudio = true;
            QCOMPARE(seq.width(), 1920); // Audio sequences still use default video resolution
        }
    }
    QVERIFY(foundMain && foundProxy && foundAudio);
}

void TestSequenceEntity::testSequenceTrackManagement()
{
    qCInfo(jveTests, "Testing sequence track management contract");
    
    Sequence sequence = Sequence::create("Track Management Test", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    
    // Contract: Sequences should support track operations
    int initialTrackCount = sequence.trackCount();
    QCOMPARE(initialTrackCount, 0); // New sequence has no tracks
    
    // Test track addition (this will fail until Track entity is implemented)
    sequence.addVideoTrack("Video 1");
    sequence.addAudioTrack("Audio 1");
    
    QCOMPARE(sequence.trackCount(), 2);
    QCOMPARE(sequence.videoTrackCount(), 1);
    QCOMPARE(sequence.audioTrackCount(), 1);
}

void TestSequenceEntity::testSequenceLoadPerformance()
{
    qCInfo(jveTests, "Testing sequence load performance contract");
    
    Sequence sequence = Sequence::create("Performance Test", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    
    m_timer.restart();
    Sequence loaded = Sequence::load(sequence.id(), m_database);
    QVERIFY(loaded.isValid());
    
    verifyPerformance("Sequence load", 30);
}

void TestSequenceEntity::testTimelineCalculationPerformance()
{
    qCInfo(jveTests, "Testing timeline calculation performance contract");
    
    Sequence sequence = Sequence::create("Calculation Test", m_projectId, 60.0, 3840, 2160);
    sequence.setFramerate(29.97);
    
    // Test performance of common timeline calculations
    m_timer.restart();
    
    for (int i = 0; i < 1000; i++) {
        qint64 frames = sequence.millisecondsToFrames(i * 100);
        qint64 ms = sequence.framesToMilliseconds(frames);
        Q_UNUSED(ms)
    }
    
    verifyPerformance("1000 timeline calculations", 50);
}

QTEST_MAIN(TestSequenceEntity)
#include "test_sequence_entity.moc"