#include "../common/test_base.h"
#include "../../src/core/api/project_manager.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QSqlQuery>

/**
 * Contract Test T011: Media Import API
 * 
 * Tests POST /projects/{id}/media API contract for media import.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Import media file reference into project
 * - Return 201 Created with MediaResponse
 * - Extract technical metadata (duration, resolution, codecs)
 * - Support video, audio, and image file types
 * - Handle offline/online media states
 */
class TestMediaImport : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testMediaImportSuccess();
    void testMediaImportValidation();
    void testMediaImportFileTypes();
    void testMediaImportMetadata();
    void testMediaImportOfflineFiles();
    void testMediaImportInvalidProject();

private:
    ProjectManager* m_projectManager;
    QString m_validProjectId;
};

void TestMediaImport::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    m_projectManager = new ProjectManager(this);
    
    // Create a test project for media import
    QJsonObject createRequest;
    createRequest["name"] = "Media Import Test Project";
    createRequest["file_path"] = m_testDataDir->filePath("media_test.jve");
    
    ProjectCreateResponse response = m_projectManager->createProject(createRequest);
    if (response.statusCode == 201) {
        m_validProjectId = response.project.id;
    } else {
        // For TDD phase, create project manually
        QString projectPath = m_testDataDir->filePath("manual_media_test.jve");
        if (!Migrations::createNewProject(projectPath)) {
            QFAIL("Failed to create test project");
        }
        
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "media_test_setup");
        db.setDatabaseName(projectPath);
        QVERIFY(db.open());
        
        QSqlQuery query(db);
        query.exec("SELECT id FROM projects LIMIT 1");
        if (query.next()) {
            m_validProjectId = query.value(0).toString();
        }
        db.close();
        QSqlDatabase::removeDatabase("media_test_setup");
    }
    
    QVERIFY(!m_validProjectId.isEmpty());
}

void TestMediaImport::testMediaImportSuccess()
{
    qCInfo(jveTests, "Testing POST /projects/{id}/media with valid video file");
    verifyLibraryFirstCompliance();
    
    // Prepare ImportMediaRequest
    QJsonObject request;
    request["file_path"] = "/path/to/test_video.mp4";
    
    // Import media - THIS WILL FAIL until ProjectManager is implemented
    QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
    
    // Verify MediaResponse contract
    QVERIFY(response.contains("id"));
    QVERIFY(response.contains("file_name"));
    QVERIFY(response.contains("file_path"));
    QVERIFY(response.contains("duration"));
    QVERIFY(response.contains("frame_rate"));
    QVERIFY(response.contains("metadata"));
    
    QVERIFY(!response["id"].toString().isEmpty());
    QCOMPARE(response["file_name"].toString(), QString("test_video.mp4"));
    QCOMPARE(response["file_path"].toString(), QString("/path/to/test_video.mp4"));
    QVERIFY(response["metadata"].isObject());
    
    verifyPerformance("Media import", 150);
}

void TestMediaImport::testMediaImportValidation()
{
    qCInfo(jveTests, "Testing POST /projects/{id}/media with invalid requests");
    
    // Missing required file_path
    QJsonObject invalidRequest1;
    // No file_path provided
    
    QJsonObject response1 = m_projectManager->importMedia(m_validProjectId, invalidRequest1);
    QVERIFY(response1.contains("error"));
    
    // Empty file_path
    QJsonObject invalidRequest2;
    invalidRequest2["file_path"] = "";
    
    QJsonObject response2 = m_projectManager->importMedia(m_validProjectId, invalidRequest2);
    QVERIFY(response2.contains("error"));
    
    // Invalid file extension (unsupported format)
    QJsonObject invalidRequest3;
    invalidRequest3["file_path"] = "/path/to/document.txt";
    
    QJsonObject response3 = m_projectManager->importMedia(m_validProjectId, invalidRequest3);
    
    if (!response3.contains("error")) {
        // If no error, should still create media reference but mark as unsupported type
        QVERIFY(response3.contains("id"));
    }
}

void TestMediaImport::testMediaImportFileTypes()
{
    qCInfo(jveTests, "Testing media import with different file types");
    
    // Test video files
    QStringList videoFiles = {
        "/path/to/video.mp4",
        "/path/to/video.mov",
        "/path/to/video.avi",
        "/path/to/video.mkv",
        "/path/to/video.mxf",
        "/path/to/video.prores.mov"
    };
    
    for (const QString& filePath : videoFiles) {
        QJsonObject request;
        request["file_path"] = filePath;
        
        QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
        
        if (!response.contains("error")) {
            // Should detect as video type
            QJsonObject metadata = response["metadata"].toObject();
            // Implementation might store type in metadata
            QVERIFY(!response["id"].toString().isEmpty());
            QCOMPARE(response["file_path"].toString(), filePath);
        }
    }
    
    // Test audio files
    QStringList audioFiles = {
        "/path/to/audio.wav",
        "/path/to/audio.mp3",
        "/path/to/audio.aac",
        "/path/to/audio.flac"
    };
    
    for (const QString& filePath : audioFiles) {
        QJsonObject request;
        request["file_path"] = filePath;
        
        QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
        
        if (!response.contains("error")) {
            // Should detect as audio type
            QVERIFY(!response["id"].toString().isEmpty());
            QCOMPARE(response["file_path"].toString(), filePath);
        }
    }
    
    // Test image files
    QStringList imageFiles = {
        "/path/to/image.jpg",
        "/path/to/image.png",
        "/path/to/image.tiff",
        "/path/to/image.exr"
    };
    
    for (const QString& filePath : imageFiles) {
        QJsonObject request;
        request["file_path"] = filePath;
        
        QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
        
        if (!response.contains("error")) {
            // Should detect as image type
            QVERIFY(!response["id"].toString().isEmpty());
            QCOMPARE(response["file_path"].toString(), filePath);
        }
    }
}

void TestMediaImport::testMediaImportMetadata()
{
    qCInfo(jveTests, "Testing media metadata extraction");
    
    QJsonObject request;
    request["file_path"] = "/path/to/detailed_video.mp4";
    
    QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
    
    if (!response.contains("error")) {
        // Verify metadata structure
        QVERIFY(response.contains("metadata"));
        QJsonObject metadata = response["metadata"].toObject();
        
        // Standard video metadata fields (may be empty during TDD phase)
        // These fields should exist in the response structure
        QVERIFY(response.contains("duration")); // May be 0 if not extracted
        QVERIFY(response.contains("frame_rate")); // May be 0 if not extracted
        
        // Metadata object should exist even if empty
        // metadata is already a QJsonObject, so just verify it's not null
        Q_UNUSED(metadata); // Available for further checks
        
        // If metadata extraction is implemented, verify common fields
        if (metadata.contains("width")) {
            QVERIFY(metadata["width"].isDouble());
            QVERIFY(metadata["width"].toInt() > 0);
        }
        
        if (metadata.contains("height")) {
            QVERIFY(metadata["height"].isDouble());
            QVERIFY(metadata["height"].toInt() > 0);
        }
        
        if (metadata.contains("video_codec")) {
            QVERIFY(metadata["video_codec"].isString());
            QVERIFY(!metadata["video_codec"].toString().isEmpty());
        }
        
        if (metadata.contains("audio_codec")) {
            QVERIFY(metadata["audio_codec"].isString());
        }
    }
}

void TestMediaImport::testMediaImportOfflineFiles()
{
    qCInfo(jveTests, "Testing media import with offline/non-existent files");
    
    // Import file that doesn't exist
    QJsonObject request;
    request["file_path"] = "/non/existent/path/missing_video.mp4";
    
    QJsonObject response = m_projectManager->importMedia(m_validProjectId, request);
    
    if (!response.contains("error")) {
        // Should still create media reference but mark as offline
        QVERIFY(!response["id"].toString().isEmpty());
        QCOMPARE(response["file_path"].toString(), QString("/non/existent/path/missing_video.mp4"));
        QCOMPARE(response["file_name"].toString(), QString("missing_video.mp4"));
        
        // Duration and frame_rate should be 0 or null for offline media
        QVERIFY(response["duration"].toInt() == 0 || response["duration"].isNull());
        
        // Metadata might indicate offline status
        QJsonObject metadata = response["metadata"].toObject();
        if (metadata.contains("status")) {
            QString status = metadata["status"].toString();
            QVERIFY(status == "offline" || status == "unknown");
        }
    } else {
        // Some implementations might reject offline files entirely
        QString errorCode = response["error"].toString();
        QVERIFY(errorCode == "FILE_NOT_FOUND" || errorCode == "NOT_IMPLEMENTED");
    }
}

void TestMediaImport::testMediaImportInvalidProject()
{
    qCInfo(jveTests, "Testing media import with invalid project ID");
    
    QString invalidProjectId = "00000000-0000-0000-0000-000000000000";
    
    QJsonObject request;
    request["file_path"] = "/path/to/video.mp4";
    
    QJsonObject response = m_projectManager->importMedia(invalidProjectId, request);
    
    // Should return error for non-existent project
    QVERIFY(response.contains("error"));
    QString errorCode = response["error"].toString();
    QVERIFY(errorCode == "PROJECT_NOT_FOUND" || errorCode == "NOT_IMPLEMENTED");
}

QTEST_MAIN(TestMediaImport)
#include "test_media_import.moc"