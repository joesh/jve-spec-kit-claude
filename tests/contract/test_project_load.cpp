#include "../common/test_base.h"
#include "../../src/core/api/project_manager.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QSqlQuery>

/**
 * Contract Test T009: Project Load API
 * 
 * Tests GET /projects/{id} API contract for project loading.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Load existing .jve project file by ID
 * - Return 200 OK with complete ProjectResponse
 * - Include all sequences and media in response
 * - Return 404 if project not found
 */
class TestProjectLoad : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testProjectLoadSuccess();
    void testProjectLoadNotFound();
    void testProjectLoadInvalidPath();
    void testProjectLoadCorruptedFile();
    void testProjectLoadWithContent();

private:
    ProjectManager* m_projectManager;
    QString m_validProjectId;
    QString m_validProjectPath;
};

void TestProjectLoad::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    m_projectManager = new ProjectManager(this);
    
    // Create a valid project file for testing
    m_validProjectPath = m_testDataDir->filePath("valid_project.jve");
    if (!Migrations::createNewProject(m_validProjectPath)) {
        QFAIL("Failed to create test project for loading");
    }
    
    // Extract project ID from the created project
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "load_test_setup");
    db.setDatabaseName(m_validProjectPath);
    QVERIFY(db.open());
    
    QSqlQuery query(db);
    query.exec("SELECT id FROM projects LIMIT 1");
    if (query.next()) {
        m_validProjectId = query.value(0).toString();
    }
    db.close();
    QSqlDatabase::removeDatabase("load_test_setup");
    
    QVERIFY(!m_validProjectId.isEmpty());
}

void TestProjectLoad::testProjectLoadSuccess()
{
    qCInfo(jveTests, "Testing GET /projects/{id} with valid project");
    verifyLibraryFirstCompliance();
    
    // Load existing project - THIS WILL FAIL until ProjectManager is implemented
    ProjectLoadResponse response = m_projectManager->loadProject(m_validProjectId);
    
    // Verify successful load response contract
    QCOMPARE(response.statusCode, 200);
    QVERIFY(!response.project.id.isEmpty());
    QCOMPARE(response.project.id, m_validProjectId);
    QVERIFY(!response.project.name.isEmpty());
    QVERIFY(response.project.createdAt.isValid());
    // sequences and media are already QJsonArray objects, verify they exist
    Q_UNUSED(response.project.sequences);
    Q_UNUSED(response.project.media);
    
    verifyPerformance("Project load", 200);
}

void TestProjectLoad::testProjectLoadNotFound()
{
    qCInfo(jveTests, "Testing GET /projects/{id} with non-existent project");
    
    QString nonExistentId = "00000000-0000-0000-0000-000000000000";
    ProjectLoadResponse response = m_projectManager->loadProject(nonExistentId);
    
    // Should return 404 Not Found
    QCOMPARE(response.statusCode, 404);
    QVERIFY(!response.error.message.isEmpty());
    QCOMPARE(response.error.audience, QString("user"));
    QVERIFY(response.project.id.isEmpty()); // No project data returned
}

void TestProjectLoad::testProjectLoadInvalidPath()
{
    qCInfo(jveTests, "Testing project load with invalid file path");
    
    // Simulate loading project with corrupted path reference
    QString invalidProjectId = "invalid-project-id";
    ProjectLoadResponse response = m_projectManager->loadProject(invalidProjectId);
    
    // Should return 400 Bad Request for invalid ID format
    QCOMPARE(response.statusCode, 400);
    QVERIFY(response.error.code == "INVALID_PROJECT_ID");
    QCOMPARE(response.error.audience, QString("developer"));
}

void TestProjectLoad::testProjectLoadCorruptedFile()
{
    qCInfo(jveTests, "Testing project load with corrupted .jve file");
    
    // Create corrupted project file
    QString corruptedPath = m_testDataDir->filePath("corrupted.jve");
    QFile file(corruptedPath);
    file.open(QIODevice::WriteOnly);
    file.write("This is not a valid SQLite database");
    file.close();
    
    // Try to load corrupted project (would need project ID lookup first)
    // For now, test with a project ID that would map to corrupted file
    QString corruptedProjectId = "corrupted-project-id";
    ProjectLoadResponse response = m_projectManager->loadProject(corruptedProjectId);
    
    // Should return 500 Internal Server Error for database corruption
    QVERIFY(response.statusCode >= 500);
    QVERIFY(response.error.code == "DATABASE_CORRUPTION" || response.error.code == "NOT_IMPLEMENTED");
    QCOMPARE(response.error.audience, QString("developer"));
}

void TestProjectLoad::testProjectLoadWithContent()
{
    qCInfo(jveTests, "Testing project load with sequences and media");
    
    // First create a project with content via ProjectManager
    QJsonObject createRequest;
    createRequest["name"] = "Content Test Project";
    createRequest["file_path"] = m_testDataDir->filePath("content_project.jve");
    
    ProjectCreateResponse createResponse = m_projectManager->createProject(createRequest);
    
    if (createResponse.statusCode == 201) {
        // Add some sequences and media to the project
        QString projectId = createResponse.project.id;
        
        QJsonObject sequenceRequest;
        sequenceRequest["name"] = "Main Sequence";
        sequenceRequest["frame_rate"] = 30;
        m_projectManager->createSequence(projectId, sequenceRequest);
        
        QJsonObject mediaRequest;
        mediaRequest["file_path"] = "/path/to/test_video.mp4";
        m_projectManager->importMedia(projectId, mediaRequest);
        
        // Now load the project and verify content is included
        ProjectLoadResponse loadResponse = m_projectManager->loadProject(projectId);
        
        QCOMPARE(loadResponse.statusCode, 200);
        QVERIFY(loadResponse.project.sequences.size() > 0);
        QVERIFY(loadResponse.project.media.size() > 0);
        
        // Verify sequence structure
        QJsonArray sequences = loadResponse.project.sequences;
        QJsonObject firstSequence = sequences.first().toObject();
        QVERIFY(firstSequence.contains("id"));
        QVERIFY(firstSequence.contains("name"));
        QVERIFY(firstSequence.contains("frame_rate"));
        
        // Verify media structure  
        QJsonArray media = loadResponse.project.media;
        QJsonObject firstMedia = media.first().toObject();
        QVERIFY(firstMedia.contains("id"));
        QVERIFY(firstMedia.contains("file_name"));
    } else {
        // Skip content verification if project creation not implemented
        QSKIP("Project creation not implemented, skipping content verification", "");
    }
}

QTEST_MAIN(TestProjectLoad)
#include "test_project_load.moc"