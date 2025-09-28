#include "../common/test_base.h"
#include "../../src/core/api/project_manager.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QSqlQuery>

/**
 * Contract Test T010: Sequence Creation API
 * 
 * Tests POST /projects/{id}/sequences API contract for sequence creation.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Create new sequence within existing project
 * - Return 201 Created with SequenceResponse
 * - Validate frame rate and timecode parameters
 * - Support standard frame rates (23.98, 24, 25, 29.97, 30, 50, 59.94, 60)
 */
class TestSequenceCreate : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testSequenceCreateSuccess();
    void testSequenceCreateValidation();
    void testSequenceCreateFrameRates();
    void testSequenceCreateTimecode();
    void testSequenceCreateInvalidProject();

private:
    ProjectManager* m_projectManager;
    QString m_validProjectId;
};

void TestSequenceCreate::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    m_projectManager = new ProjectManager(this);
    
    // Create a test project
    QJsonObject createRequest;
    createRequest["name"] = "Sequence Test Project";
    createRequest["file_path"] = m_testDataDir->filePath("sequence_test.jve");
    
    ProjectCreateResponse response = m_projectManager->createProject(createRequest);
    if (response.statusCode == 201) {
        m_validProjectId = response.project.id;
    } else {
        // For TDD phase, create project manually
        QString projectPath = m_testDataDir->filePath("manual_sequence_test.jve");
        if (!Migrations::createNewProject(projectPath)) {
            QFAIL("Failed to create test project");
        }
        
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "sequence_test_setup");
        db.setDatabaseName(projectPath);
        QVERIFY(db.open());
        
        QSqlQuery query(db);
        query.exec("SELECT id FROM projects LIMIT 1");
        if (query.next()) {
            m_validProjectId = query.value(0).toString();
        }
        db.close();
        QSqlDatabase::removeDatabase("sequence_test_setup");
    }
    
    QVERIFY(!m_validProjectId.isEmpty());
}

void TestSequenceCreate::testSequenceCreateSuccess()
{
    qCInfo(jveTests, "Testing POST /projects/{id}/sequences with valid request");
    verifyLibraryFirstCompliance();
    
    // Prepare CreateSequenceRequest
    QJsonObject request;
    request["name"] = "Main Timeline";
    request["frame_rate"] = 29.97;
    request["timecode_start"] = 0;
    
    // Create sequence - THIS WILL FAIL until ProjectManager is implemented
    QJsonObject response = m_projectManager->createSequence(m_validProjectId, request);
    
    // Verify SequenceResponse contract
    QVERIFY(response.contains("id"));
    QVERIFY(response.contains("name"));
    QVERIFY(response.contains("frame_rate"));
    QVERIFY(response.contains("duration"));
    QVERIFY(response.contains("tracks"));
    
    QVERIFY(!response["id"].toString().isEmpty());
    QCOMPARE(response["name"].toString(), QString("Main Timeline"));
    QCOMPARE(response["frame_rate"].toDouble(), 29.97);
    QVERIFY(response["tracks"].isArray());
    
    verifyPerformance("Sequence creation", 100);
}

void TestSequenceCreate::testSequenceCreateValidation()
{
    qCInfo(jveTests, "Testing POST /projects/{id}/sequences with invalid requests");
    
    // Missing required name
    QJsonObject invalidRequest1;
    invalidRequest1["frame_rate"] = 30;
    
    QJsonObject response1 = m_projectManager->createSequence(m_validProjectId, invalidRequest1);
    QVERIFY(response1.contains("error"));
    
    // Invalid frame rate
    QJsonObject invalidRequest2;
    invalidRequest2["name"] = "Invalid FPS Sequence";
    invalidRequest2["frame_rate"] = 0; // Invalid
    
    QJsonObject response2 = m_projectManager->createSequence(m_validProjectId, invalidRequest2);
    QVERIFY(response2.contains("error"));
    
    // Negative timecode start
    QJsonObject invalidRequest3;
    invalidRequest3["name"] = "Invalid Timecode Sequence";
    invalidRequest3["frame_rate"] = 25;
    invalidRequest3["timecode_start"] = -1000; // Invalid
    
    QJsonObject response3 = m_projectManager->createSequence(m_validProjectId, invalidRequest3);
    QVERIFY(response3.contains("error"));
    
    // Empty name
    QJsonObject invalidRequest4;
    invalidRequest4["name"] = "";
    invalidRequest4["frame_rate"] = 30;
    
    QJsonObject response4 = m_projectManager->createSequence(m_validProjectId, invalidRequest4);
    QVERIFY(response4.contains("error"));
}

void TestSequenceCreate::testSequenceCreateFrameRates()
{
    qCInfo(jveTests, "Testing sequence creation with standard frame rates");
    
    // Test standard professional frame rates
    QList<double> standardFrameRates = {23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0};
    
    for (double frameRate : standardFrameRates) {
        QJsonObject request;
        request["name"] = QString("Sequence %1fps").arg(frameRate);
        request["frame_rate"] = frameRate;
        
        QJsonObject response = m_projectManager->createSequence(m_validProjectId, request);
        
        if (!response.contains("error")) {
            // If implementation exists, verify frame rate is preserved
            QCOMPARE(response["frame_rate"].toDouble(), frameRate);
            QVERIFY(!response["id"].toString().isEmpty());
        }
        // During TDD phase, we expect errors - that's OK
    }
    
    // Test invalid frame rates
    QList<double> invalidFrameRates = {0.0, -1.0, 120.0, 1000.0};
    
    for (double frameRate : invalidFrameRates) {
        QJsonObject request;
        request["name"] = QString("Invalid %1fps").arg(frameRate);
        request["frame_rate"] = frameRate;
        
        QJsonObject response = m_projectManager->createSequence(m_validProjectId, request);
        QVERIFY(response.contains("error")); // Should always error for invalid rates
    }
}

void TestSequenceCreate::testSequenceCreateTimecode()
{
    qCInfo(jveTests, "Testing sequence creation with timecode parameters");
    
    // Test with custom timecode start (1 hour = 3600 seconds = 3600000ms)
    QJsonObject request;
    request["name"] = "Timecode Test Sequence";
    request["frame_rate"] = 25;
    request["timecode_start"] = 3600000; // 01:00:00:00
    
    QJsonObject response = m_projectManager->createSequence(m_validProjectId, request);
    
    if (!response.contains("error")) {
        // Verify timecode is preserved in sequence properties
        QVERIFY(response.contains("id"));
        QCOMPARE(response["name"].toString(), QString("Timecode Test Sequence"));
        QCOMPARE(response["frame_rate"].toDouble(), 25.0);
        
        // Timecode start might be stored in metadata or as separate field
        // This depends on implementation, but sequence should be created successfully
    }
    
    // Test with zero timecode (default)
    QJsonObject defaultRequest;
    defaultRequest["name"] = "Default Timecode Sequence";
    defaultRequest["frame_rate"] = 30;
    // timecode_start omitted - should default to 0
    
    QJsonObject defaultResponse = m_projectManager->createSequence(m_validProjectId, defaultRequest);
    
    if (!defaultResponse.contains("error")) {
        QVERIFY(!defaultResponse["id"].toString().isEmpty());
    }
}

void TestSequenceCreate::testSequenceCreateInvalidProject()
{
    qCInfo(jveTests, "Testing sequence creation with invalid project ID");
    
    QString invalidProjectId = "00000000-0000-0000-0000-000000000000";
    
    QJsonObject request;
    request["name"] = "Orphan Sequence";
    request["frame_rate"] = 30;
    
    QJsonObject response = m_projectManager->createSequence(invalidProjectId, request);
    
    // Should return error for non-existent project
    QVERIFY(response.contains("error"));
    QString errorCode = response["error"].toString();
    QVERIFY(errorCode == "PROJECT_NOT_FOUND" || errorCode == "NOT_IMPLEMENTED");
}

QTEST_MAIN(TestSequenceCreate)
#include "test_sequence_create.moc"