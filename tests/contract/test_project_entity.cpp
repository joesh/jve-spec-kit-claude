#include "../common/test_base.h"
#include "../../src/core/models/project.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QUuid>

/**
 * Contract Test T005: Project Entity
 * 
 * Tests the fundamental Project entity API contract.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Project creation with unique ID generation
 * - Project loading from database with full state restoration  
 * - Project saving with atomic persistence
 * - Project metadata management (name, created/modified timestamps)
 * - Project settings serialization/deserialization
 * - Constitutional single-file .jve format compliance
 */
class TestProjectEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void cleanupTestCase() override;
    
    // Core entity lifecycle contract
    void testProjectCreation();
    void testProjectPersistence(); 
    void testProjectLoading();
    void testProjectMetadata();
    void testProjectSettings();
    
    // Constitutional compliance contract
    void testSingleFileFormat();
    void testAtomicSaveOperations();
    void testDeterministicSerialization();
    
    // Performance contract  
    void testProjectLoadPerformance();
    void testProjectSavePerformance();

private:
    QSqlDatabase m_database;
};

void TestProjectEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance(); // Document TDD expectation
    
    // Create test database
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_project_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
}

void TestProjectEntity::cleanupTestCase() 
{
    if (m_database.isOpen()) {
        m_database.close();
    }
    QSqlDatabase::removeDatabase("test_project_entity");
    TestBase::cleanupTestCase();
}

void TestProjectEntity::testProjectCreation()
{
    qCInfo(jveTests, "Testing Project creation contract");
    verifyLibraryFirstCompliance();
    
    // Contract: Project::create() should generate unique ID and set creation time
    Project project = Project::create("Test Project");
    
    QVERIFY(!project.id().isEmpty());
    QVERIFY(QUuid(project.id()).version() != QUuid::VerUnknown); // Valid UUID format
    QCOMPARE(project.name(), QString("Test Project"));
    QVERIFY(project.createdAt().isValid());
    QVERIFY(project.modifiedAt().isValid());
    QVERIFY(project.createdAt() <= project.modifiedAt()); // Modified >= created
    
    verifyPerformance("Project creation", 10); // Must be fast
}

void TestProjectEntity::testProjectPersistence()
{
    qCInfo(jveTests, "Testing Project persistence contract");
    
    // Contract: Project::save() should atomically persist to database
    Project project = Project::create("Persistence Test");
    project.setSettings(R"({"theme": "dark", "autoSave": true})");
    
    bool saved = project.save(m_database);
    QVERIFY(saved);
    
    // Verify database state
    QSqlQuery query(m_database);
    query.prepare("SELECT id, name, settings FROM projects WHERE id = ?");
    query.addBindValue(project.id());
    QVERIFY(query.exec());
    QVERIFY(query.next());
    
    QCOMPARE(query.value("id").toString(), project.id());
    QCOMPARE(query.value("name").toString(), project.name());
    QCOMPARE(query.value("settings").toString(), project.settings());
    
    verifyPerformance("Project save", 50);
}

void TestProjectEntity::testProjectLoading()
{
    qCInfo(jveTests, "Testing Project loading contract");
    
    // Contract: Project::load() should restore complete state from database
    QString testId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    
    // Insert test data directly
    QSqlQuery insert(m_database);
    insert.prepare(R"(
        INSERT INTO projects (id, name, created_at, modified_at, settings)
        VALUES (?, ?, ?, ?, ?)
    )");
    insert.addBindValue(testId);
    insert.addBindValue("Loading Test Project");
    insert.addBindValue(QDateTime::currentSecsSinceEpoch() - 3600); // 1 hour ago
    insert.addBindValue(QDateTime::currentSecsSinceEpoch());
    insert.addBindValue(R"({"version": 1, "lastOpened": "2025-09-26"})");
    QVERIFY(insert.exec());
    
    // Test loading
    Project project = Project::load(testId, m_database);
    QVERIFY(project.isValid());
    QCOMPARE(project.id(), testId);
    QCOMPARE(project.name(), QString("Loading Test Project"));
    QVERIFY(project.createdAt().isValid());
    QVERIFY(project.modifiedAt().isValid());
    QVERIFY(project.settings().contains("version"));
    
    verifyPerformance("Project load", 20);
}

void TestProjectEntity::testProjectMetadata()
{
    qCInfo(jveTests, "Testing Project metadata contract");
    
    // Contract: Metadata must be properly managed and updated
    Project project = Project::create("Metadata Test");
    QDateTime initialCreated = project.createdAt();
    QDateTime initialModified = project.modifiedAt();
    
    // Simulate some work delay
    QThread::msleep(10);
    
    // Update project
    project.setName("Updated Metadata Test");
    QCOMPARE(project.name(), QString("Updated Metadata Test"));
    QCOMPARE(project.createdAt(), initialCreated); // Should not change
    QVERIFY(project.modifiedAt() >= initialModified); // Should update
}

void TestProjectEntity::testProjectSettings()
{
    qCInfo(jveTests, "Testing Project settings contract");
    
    // Contract: Settings must serialize/deserialize JSON correctly
    Project project = Project::create("Settings Test");
    
    QString settingsJson = R"({
        "editor": {
            "theme": "dark",
            "fontSize": 12,
            "showLineNumbers": true
        },
        "timeline": {
            "snapToFrames": false,
            "defaultTransition": "dissolve"
        },
        "export": {
            "defaultFormat": "mp4",
            "quality": "high"
        }
    })";
    
    project.setSettings(settingsJson);
    QCOMPARE(project.settings(), settingsJson);
    
    // Test round-trip through database
    QVERIFY(project.save(m_database));
    Project loaded = Project::load(project.id(), m_database);
    QCOMPARE(loaded.settings(), settingsJson);
}

void TestProjectEntity::testSingleFileFormat()
{
    qCInfo(jveTests, "Testing constitutional single-file format contract");
    
    // Contract: All project data must be contained in single .jve file
    QFileInfo projectFile(m_testDatabasePath);
    QVERIFY(projectFile.exists());
    QCOMPARE(projectFile.suffix(), QString("jve"));
    
    // Verify no sidecar files created (WAL, SHM, etc.)
    QDir projectDir = projectFile.dir();
    QStringList sidecarFiles = projectDir.entryList(
        QStringList() << "*.jve-wal" << "*.jve-shm" << "*.jve-journal", 
        QDir::Files
    );
    QVERIFY(sidecarFiles.isEmpty()); // Constitutional requirement
}

void TestProjectEntity::testAtomicSaveOperations()
{
    qCInfo(jveTests, "Testing atomic save operations contract");
    
    // Contract: Save operations must be atomic (all-or-nothing)
    Project project = Project::create("Atomic Test");
    
    // Start transaction to test rollback behavior
    m_database.transaction();
    QVERIFY(project.save(m_database));
    m_database.rollback(); // Simulate failure
    
    // Verify project was not saved
    Project shouldNotExist = Project::load(project.id(), m_database);
    QVERIFY(!shouldNotExist.isValid());
    
    // Now save properly
    QVERIFY(project.save(m_database));
    Project shouldExist = Project::load(project.id(), m_database);
    QVERIFY(shouldExist.isValid());
}

void TestProjectEntity::testDeterministicSerialization()
{
    qCInfo(jveTests, "Testing deterministic serialization contract");
    
    // Contract: Same project state must serialize identically
    Project project1 = Project::createWithId("fixed-id-test", "Deterministic Test");
    Project project2 = Project::createWithId("fixed-id-test", "Deterministic Test");
    
    QString settings = R"({"setting1": "value1", "setting2": "value2"})";
    project1.setSettings(settings);
    project2.setSettings(settings);
    
    // Force same timestamps for deterministic comparison
    QDateTime fixedTime = QDateTime::fromSecsSinceEpoch(1695729600); // Fixed timestamp
    project1.setCreatedAt(fixedTime);
    project1.setModifiedAt(fixedTime);
    project2.setCreatedAt(fixedTime);
    project2.setModifiedAt(fixedTime);
    
    // Serialization should be identical
    QString serialized1 = project1.serialize();
    QString serialized2 = project2.serialize();
    QCOMPARE(serialized1, serialized2); // Constitutional determinism requirement
}

void TestProjectEntity::testProjectLoadPerformance()
{
    qCInfo(jveTests, "Testing Project load performance contract");
    
    // Contract: Project loading must meet performance requirements
    Project project = Project::create("Performance Test");
    QVERIFY(project.save(m_database));
    
    m_timer.restart();
    Project loaded = Project::load(project.id(), m_database);
    QVERIFY(loaded.isValid());
    
    verifyPerformance("Project load", 50); // Constitutional requirement
}

void TestProjectEntity::testProjectSavePerformance()
{
    qCInfo(jveTests, "Testing Project save performance contract");
    
    // Contract: Project saving must meet performance requirements
    Project project = Project::create("Save Performance Test");
    
    // Add substantial settings data to test with realistic load
    QString largeSettings = R"({"profiles": {)";
    for (int i = 0; i < 100; i++) {
        if (i > 0) largeSettings += ",";
        largeSettings += QString(R"("profile%1": {"name": "Profile %1", "settings": {"key": "value"}})").arg(i);
    }
    largeSettings += "}}";
    project.setSettings(largeSettings);
    
    m_timer.restart();
    QVERIFY(project.save(m_database));
    
    verifyPerformance("Project save with large settings", 100);
}

QTEST_MAIN(TestProjectEntity)
#include "test_project_entity.moc"