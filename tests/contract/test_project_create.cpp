#include "../common/test_base.h"
#include "../../src/core/api/project_manager.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

/**
 * Contract Test T008: Project Creation API
 * 
 * Tests POST /projects API contract for project creation.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Accept CreateProjectRequest with name and file_path
 * - Return 201 Created with ProjectResponse
 * - Initialize .jve project file with default structure
 * - Include sequences and media arrays in response
 */
class TestProjectCreate : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testProjectCreateSuccess();
    void testProjectCreateValidation();
    void testProjectCreateFileSystem();
    void testProjectCreateResponse();

private:
    ProjectManager* m_projectManager;
};

void TestProjectCreate::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    // This will fail until ProjectManager is implemented (TDD requirement)
    m_projectManager = new ProjectManager(this);
}

void TestProjectCreate::testProjectCreateSuccess()
{
    qCInfo(jveTests, "Testing POST /projects with valid request");
    verifyLibraryFirstCompliance();
    
    // Prepare CreateProjectRequest
    QJsonObject request;
    request["name"] = "Test Project";
    request["file_path"] = m_testDataDir->filePath("test_project.jve");
    
    // Execute project creation - THIS WILL FAIL until ProjectManager is implemented
    ProjectCreateResponse response = m_projectManager->createProject(request);
    
    // Verify ProjectResponse contract
    QCOMPARE(response.statusCode, 201);
    QVERIFY(!response.project.id.isEmpty());
    QCOMPARE(response.project.name, QString("Test Project"));
    QVERIFY(response.project.createdAt.isValid());
    QVERIFY(response.project.sequences.isEmpty()); // New project starts empty
    QVERIFY(response.project.media.isEmpty()); // New project starts empty
    
    verifyPerformance("Project creation", 100);
}

void TestProjectCreate::testProjectCreateValidation()
{
    qCInfo(jveTests, "Testing POST /projects with invalid requests");
    
    // Missing name
    QJsonObject invalidRequest1;
    invalidRequest1["file_path"] = m_testDataDir->filePath("invalid1.jve");
    
    ProjectCreateResponse response1 = m_projectManager->createProject(invalidRequest1);
    QCOMPARE(response1.statusCode, 400);
    QVERIFY(!response1.error.message.isEmpty());
    QCOMPARE(response1.error.audience, QString("user"));
    
    // Missing file_path
    QJsonObject invalidRequest2;
    invalidRequest2["name"] = "Test Project";
    
    ProjectCreateResponse response2 = m_projectManager->createProject(invalidRequest2);
    QCOMPARE(response2.statusCode, 400);
    QVERIFY(!response2.error.message.isEmpty());
    
    // Empty name
    QJsonObject invalidRequest3;
    invalidRequest3["name"] = "";
    invalidRequest3["file_path"] = m_testDataDir->filePath("invalid3.jve");
    
    ProjectCreateResponse response3 = m_projectManager->createProject(invalidRequest3);
    QCOMPARE(response3.statusCode, 400);
}

void TestProjectCreate::testProjectCreateFileSystem()
{
    qCInfo(jveTests, "Testing .jve file creation and structure");
    
    QString projectPath = m_testDataDir->filePath("filesystem_test.jve");
    
    QJsonObject request;
    request["name"] = "FileSystem Test Project";
    request["file_path"] = projectPath;
    
    ProjectCreateResponse response = m_projectManager->createProject(request);
    QVERIFY(response.statusCode == 201);
    
    // Verify .jve file was created
    QVERIFY(QFile::exists(projectPath));
    
    // Verify file is valid SQLite database
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "verify_filesystem");
    db.setDatabaseName(projectPath);
    QVERIFY(db.open());
    
    // Verify required tables exist
    QStringList tables = db.tables();
    QVERIFY(tables.contains("projects"));
    QVERIFY(tables.contains("sequences"));
    QVERIFY(tables.contains("tracks"));
    QVERIFY(tables.contains("clips"));
    QVERIFY(tables.contains("media"));
    
    db.close();
    QSqlDatabase::removeDatabase("verify_filesystem");
}

void TestProjectCreate::testProjectCreateResponse()
{
    qCInfo(jveTests, "Testing ProjectResponse schema compliance");
    
    QJsonObject request;
    request["name"] = "Response Schema Test";
    request["file_path"] = m_testDataDir->filePath("response_test.jve");
    
    ProjectCreateResponse response = m_projectManager->createProject(request);
    QVERIFY(response.statusCode == 201);
    
    // Convert to JSON for schema validation
    QJsonObject projectJson = response.project.toJson();
    
    // Verify required fields present
    QVERIFY(projectJson.contains("id"));
    QVERIFY(projectJson.contains("name"));
    QVERIFY(projectJson.contains("created_at"));
    QVERIFY(projectJson.contains("sequences"));
    QVERIFY(projectJson.contains("media"));
    
    // Verify field types
    QVERIFY(projectJson["id"].isString());
    QVERIFY(projectJson["name"].isString());
    QVERIFY(projectJson["created_at"].isString());
    QVERIFY(projectJson["sequences"].isArray());
    QVERIFY(projectJson["media"].isArray());
    
    // Verify UUID format for id
    QString projectId = projectJson["id"].toString();
    QVERIFY(projectId.contains("-"));
    QCOMPARE(projectId.length(), 36); // Standard UUID length
    
    // Verify ISO 8601 date format
    QString createdAt = projectJson["created_at"].toString();
    QDateTime parsedDate = QDateTime::fromString(createdAt, Qt::ISODate);
    QVERIFY(parsedDate.isValid());
}

QTEST_MAIN(TestProjectCreate)
#include "test_project_create.moc"