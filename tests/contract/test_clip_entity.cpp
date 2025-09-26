#include "../common/test_base.h"
#include "../../src/core/models/clip.h"
#include "../../src/core/models/media.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T008: Clip Entity
 * 
 * Tests the Clip entity API contract - media references within tracks.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Clip creation with media association
 * - Timeline positioning (in/out points, duration)
 * - Media source referencing and validation
 * - Clip-level transformations and effects
 * - Property instance management
 * - Clip trimming and positioning operations
 */
class TestClipEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testClipCreation();
    void testClipTimelinePositioning();
    void testClipMediaReference();
    void testClipTransformations();
    void testClipTrimming();
    void testClipPropertyManagement();
    void testClipPerformance();

private:
    QSqlDatabase m_database;
    QString m_mediaId;
};

void TestClipEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_clip_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test media
    Media media = Media::create("test_video.mp4", "/path/to/test_video.mp4");
    QVERIFY(media.save(m_database));
    m_mediaId = media.id();
}

void TestClipEntity::testClipCreation()
{
    qCInfo(jveTests) << "Testing Clip creation contract";
    verifyLibraryFirstCompliance();
    
    Clip clip = Clip::create("Test Clip", m_mediaId);
    
    QVERIFY(!clip.id().isEmpty());
    QCOMPARE(clip.name(), QString("Test Clip"));
    QCOMPARE(clip.mediaId(), m_mediaId);
    QVERIFY(clip.createdAt().isValid());
    
    // Default timeline positioning
    QCOMPARE(clip.timelineStart(), qint64(0));
    QCOMPARE(clip.timelineEnd(), qint64(0));
    QCOMPARE(clip.duration(), qint64(0));
    
    verifyPerformance("Clip creation", 10);
}

void TestClipEntity::testClipTimelinePositioning()
{
    qCInfo(jveTests) << "Testing clip timeline positioning contract";
    
    Clip clip = Clip::create("Position Test", m_mediaId);
    
    // Set timeline position
    clip.setTimelinePosition(5000, 15000); // 5s to 15s (10s duration)
    QCOMPARE(clip.timelineStart(), qint64(5000));
    QCOMPARE(clip.timelineEnd(), qint64(15000));
    QCOMPARE(clip.duration(), qint64(10000));
    
    // Test source timing
    clip.setSourceRange(2000, 12000); // Use 2s-12s from source media
    QCOMPARE(clip.sourceStart(), qint64(2000));
    QCOMPARE(clip.sourceEnd(), qint64(12000));
    QCOMPARE(clip.sourceDuration(), qint64(10000));
}

void TestClipEntity::testClipMediaReference()
{
    qCInfo(jveTests) << "Testing clip media reference contract";
    
    Clip clip = Clip::create("Media Reference Test", m_mediaId);
    
    // Verify media relationship
    QCOMPARE(clip.mediaId(), m_mediaId);
    
    Media referencedMedia = clip.getMedia(m_database);
    QVERIFY(referencedMedia.isValid());
    QCOMPARE(referencedMedia.id(), m_mediaId);
    
    // Test invalid media reference
    Clip invalidClip = Clip::create("Invalid", "non-existent-media-id");
    Media invalidMedia = invalidClip.getMedia(m_database);
    QVERIFY(!invalidMedia.isValid());
}

void TestClipEntity::testClipTransformations()
{
    qCInfo(jveTests) << "Testing clip transformations contract";
    
    Clip clip = Clip::create("Transform Test", m_mediaId);
    
    // Position transformations
    clip.setPosition(100.0, 200.0);
    QCOMPARE(clip.x(), 100.0);
    QCOMPARE(clip.y(), 200.0);
    
    // Scale transformations
    clip.setScale(1.5, 0.8);
    QCOMPARE(clip.scaleX(), 1.5);
    QCOMPARE(clip.scaleY(), 0.8);
    
    // Rotation
    clip.setRotation(45.0);
    QCOMPARE(clip.rotation(), 45.0);
    
    // Opacity
    clip.setOpacity(0.75);
    QCOMPARE(clip.opacity(), 0.75);
}

void TestClipEntity::testClipTrimming()
{
    qCInfo(jveTests) << "Testing clip trimming contract";
    
    Clip clip = Clip::create("Trim Test", m_mediaId);
    clip.setTimelinePosition(5000, 15000);
    clip.setSourceRange(0, 10000);
    
    // Trim from start
    clip.trimStart(2000); // Move start by 2 seconds
    QCOMPARE(clip.timelineStart(), qint64(7000));
    QCOMPARE(clip.sourceStart(), qint64(2000));
    QCOMPARE(clip.duration(), qint64(8000));
    
    // Trim from end
    clip.trimEnd(-1000); // Trim 1 second from end
    QCOMPARE(clip.timelineEnd(), qint64(14000));
    QCOMPARE(clip.sourceEnd(), qint64(9000));
    QCOMPARE(clip.duration(), qint64(7000));
}

void TestClipEntity::testClipPropertyManagement()
{
    qCInfo(jveTests) << "Testing clip property management contract";
    
    Clip clip = Clip::create("Property Test", m_mediaId);
    QVERIFY(clip.save(m_database));
    
    // Add properties
    clip.setProperty("brightness", 120.0);
    clip.setProperty("contrast", 1.2);
    clip.setProperty("saturation", 1.1);
    
    QCOMPARE(clip.getProperty("brightness").toDouble(), 120.0);
    QCOMPARE(clip.getProperty("contrast").toDouble(), 1.2);
    QCOMPARE(clip.getProperty("saturation").toDouble(), 1.1);
    
    // Property persistence
    QVERIFY(clip.save(m_database));
    Clip loaded = Clip::load(clip.id(), m_database);
    QCOMPARE(loaded.getProperty("brightness").toDouble(), 120.0);
}

void TestClipEntity::testClipPerformance()
{
    qCInfo(jveTests) << "Testing clip performance contract";
    
    m_timer.restart();
    Clip clip = Clip::create("Performance Test", m_mediaId);
    clip.setTimelinePosition(1000, 5000);
    QVERIFY(clip.save(m_database));
    
    verifyPerformance("Clip creation and save", 50);
}

QTEST_MAIN(TestClipEntity)
#include "test_clip_entity.moc"