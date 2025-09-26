#include "../common/test_base.h"
#include "../../src/core/models/media.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T009: Media Entity
 * 
 * Tests the Media entity API contract - source file references and metadata.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Media file registration and metadata extraction
 * - File path validation and monitoring
 * - Media type detection (video/audio/image)
 * - Technical metadata storage (codec, duration, resolution)
 * - Thumbnail/proxy generation tracking
 * - Media offline/online state management
 */
class TestMediaEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testMediaCreation();
    void testMediaMetadataExtraction();
    void testMediaTypeDetection();
    void testMediaFileMonitoring();
    void testMediaProxyManagement();
    void testMediaPerformance();

private:
    QSqlDatabase m_database;
};

void TestMediaEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_media_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
}

void TestMediaEntity::testMediaCreation()
{
    qCInfo(jveTests) << "Testing Media creation contract";
    verifyLibraryFirstCompliance();
    
    Media media = Media::create("test_video.mp4", "/path/to/test_video.mp4");
    
    QVERIFY(!media.id().isEmpty());
    QCOMPARE(media.filename(), QString("test_video.mp4"));
    QCOMPARE(media.filepath(), QString("/path/to/test_video.mp4"));
    QVERIFY(media.createdAt().isValid());
    
    // Default state
    QCOMPARE(media.status(), Media::Unknown);
    QVERIFY(!media.isOnline());
    QCOMPARE(media.type(), Media::UnknownType);
    
    verifyPerformance("Media creation", 10);
}

void TestMediaEntity::testMediaMetadataExtraction()
{
    qCInfo(jveTests) << "Testing media metadata extraction contract";
    
    Media videoMedia = Media::create("sample.mp4", "/path/to/sample.mp4");
    
    // Simulate metadata extraction
    MediaMetadata metadata;
    metadata.duration = 120000; // 2 minutes
    metadata.width = 1920;
    metadata.height = 1080;
    metadata.framerate = 29.97;
    metadata.videoCodec = "H.264";
    metadata.audioCodec = "AAC";
    metadata.bitrate = 5000000; // 5 Mbps
    
    videoMedia.setMetadata(metadata);
    
    QCOMPARE(videoMedia.duration(), qint64(120000));
    QCOMPARE(videoMedia.width(), 1920);
    QCOMPARE(videoMedia.height(), 1080);
    QCOMPARE(videoMedia.framerate(), 29.97);
    QCOMPARE(videoMedia.videoCodec(), QString("H.264"));
    QCOMPARE(videoMedia.audioCodec(), QString("AAC"));
    QCOMPARE(videoMedia.bitrate(), 5000000);
}

void TestMediaEntity::testMediaTypeDetection()
{
    qCInfo(jveTests) << "Testing media type detection contract";
    
    // Test video file detection
    Media videoFile = Media::create("video.mp4", "/path/video.mp4");
    QCOMPARE(videoFile.detectType(), Media::Video);
    
    Media movFile = Media::create("video.mov", "/path/video.mov");
    QCOMPARE(movFile.detectType(), Media::Video);
    
    // Test audio file detection
    Media audioFile = Media::create("audio.wav", "/path/audio.wav");
    QCOMPARE(audioFile.detectType(), Media::Audio);
    
    Media mp3File = Media::create("audio.mp3", "/path/audio.mp3");
    QCOMPARE(mp3File.detectType(), Media::Audio);
    
    // Test image file detection
    Media imageFile = Media::create("image.jpg", "/path/image.jpg");
    QCOMPARE(imageFile.detectType(), Media::Image);
    
    Media pngFile = Media::create("image.png", "/path/image.png");
    QCOMPARE(pngFile.detectType(), Media::Image);
    
    // Test unknown file
    Media unknownFile = Media::create("data.bin", "/path/data.bin");
    QCOMPARE(unknownFile.detectType(), Media::UnknownType);
}

void TestMediaEntity::testMediaFileMonitoring()
{
    qCInfo(jveTests) << "Testing media file monitoring contract";
    
    Media media = Media::create("monitored.mp4", "/real/path/monitored.mp4");
    
    // Initial state - file doesn't exist
    QCOMPARE(media.status(), Media::Unknown);
    QVERIFY(!media.isOnline());
    
    // Simulate file check
    media.checkFileStatus();
    QCOMPARE(media.status(), Media::Offline); // File doesn't exist
    
    // Simulate file becoming available
    media.setStatus(Media::Online);
    QVERIFY(media.isOnline());
    
    // Test modification tracking
    QDateTime lastModified = QDateTime::currentDateTime();
    media.setFileModifiedTime(lastModified);
    QCOMPARE(media.fileModifiedTime(), lastModified);
    
    // Test file size tracking
    media.setFileSize(1024000); // 1MB
    QCOMPARE(media.fileSize(), qint64(1024000));
}

void TestMediaEntity::testMediaProxyManagement()
{
    qCInfo(jveTests) << "Testing media proxy management contract";
    
    Media media = Media::create("proxy_test.mov", "/path/proxy_test.mov");
    
    // Initial proxy state
    QVERIFY(!media.hasProxy());
    QVERIFY(!media.hasThumbnail());
    QVERIFY(media.proxyPath().isEmpty());
    QVERIFY(media.thumbnailPath().isEmpty());
    
    // Generate proxy
    QString proxyPath = "/cache/proxy_test_proxy.mp4";
    media.setProxyPath(proxyPath);
    QVERIFY(media.hasProxy());
    QCOMPARE(media.proxyPath(), proxyPath);
    
    // Generate thumbnail  
    QString thumbnailPath = "/cache/proxy_test_thumb.jpg";
    media.setThumbnailPath(thumbnailPath);
    QVERIFY(media.hasThumbnail());
    QCOMPARE(media.thumbnailPath(), thumbnailPath);
    
    // Proxy preferences
    media.setUseProxy(true);
    QVERIFY(media.useProxy());
    
    // Effective path resolution
    QCOMPARE(media.getEffectivePath(), proxyPath); // Should prefer proxy
    
    media.setUseProxy(false);
    QCOMPARE(media.getEffectivePath(), media.filepath()); // Should use original
}

void TestMediaEntity::testMediaPerformance()
{
    qCInfo(jveTests) << "Testing media performance contract";
    
    m_timer.restart();
    Media media = Media::create("performance.mp4", "/path/performance.mp4");
    
    MediaMetadata metadata;
    metadata.duration = 60000;
    metadata.width = 1920;
    metadata.height = 1080;
    media.setMetadata(metadata);
    
    QVERIFY(media.save(m_database));
    
    verifyPerformance("Media creation with metadata", 50);
}

QTEST_MAIN(TestMediaEntity)
#include "test_media_entity.moc"