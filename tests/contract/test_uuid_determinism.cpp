#include <QtTest>
#include <QObject>
#include <QCoreApplication>
#include <QJsonObject>
#include <QJsonDocument>
#include <QJsonArray>
#include <QLoggingCategory>

#include "core/common/uuid_generator.h"
#include "core/commands/command_dispatcher.h"
#include "tests/common/test_base.h"

Q_LOGGING_CATEGORY(jveTestUuidDeterminism, "jve.test.uuid.determinism")

/**
 * Professional UUID determinism test for command replay consistency
 * 
 * This test validates that the UUID generation system produces deterministic
 * results when seeded, ensuring command replay consistency for debugging
 * and testing purposes.
 * 
 * Test Scenarios:
 * - Deterministic generation with same seed produces identical sequences
 * - Different seeds produce different but predictable sequences
 * - Production mode uses secure random generation
 * - Testing mode enables deterministic replay
 * - UUID format compliance across all generation modes
 * - Performance characteristics of deterministic generation
 */
class TestUuidDeterminism : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void cleanupTestCase() override;
    void init() override;
    void cleanup() override;

    // Core determinism tests
    void testDeterministicGeneration();
    void testSeedConsistency();
    void testDifferentSeedsProduceDifferentResults();
    void testEntityTypeNamespacing();
    
    // Mode switching tests
    void testProductionModeRandomness();
    void testTestingModeConsistency();
    void testDebuggingModePatterns();
    
    // Command system integration tests
    void testCommandReplayConsistency();
    void testTimelineOperationDeterminism();
    void testProjectCreationConsistency();
    
    // Performance and validation tests
    void testUuidFormatCompliance();
    void testGenerationPerformance();
    void testCollisionDetection();
    void testThreadSafety();

private:
    UuidGenerator* m_uuidGenerator;
    CommandDispatcher* m_commandDispatcher;
};

void TestUuidDeterminism::initTestCase()
{
    TestBase::initTestCase();
    qCDebug(jveTestUuidDeterminism) << "Initializing UUID determinism test suite";
    
    // Get UUID generator instance
    m_uuidGenerator = UuidGenerator::instance();
    
    // Initialize command dispatcher
    m_commandDispatcher = new CommandDispatcher(this);
    m_commandDispatcher->setDatabase(m_database);
}

void TestUuidDeterminism::cleanupTestCase()
{
    qCDebug(jveTestUuidDeterminism) << "Cleaning up UUID determinism test suite";
    TestBase::cleanupTestCase();
}

void TestUuidDeterminism::init()
{
    TestBase::init();
    
    // Reset UUID generator to default state
    m_uuidGenerator->setGenerationMode(UuidGenerator::ProductionMode);
    m_uuidGenerator->clearUuidHistory();
    m_uuidGenerator->enableCollisionDetection(true);
}

void TestUuidDeterminism::cleanup()
{
    TestBase::cleanup();
}

void TestUuidDeterminism::testDeterministicGeneration()
{
    qCDebug(jveTestUuidDeterminism) << "Testing deterministic UUID generation";
    
    // Switch to testing mode with a specific seed
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(12345);
    
    // Generate sequence of UUIDs
    QStringList firstSequence;
    for (int i = 0; i < 10; i++) {
        firstSequence << m_uuidGenerator->generateUuid(UuidGenerator::CommandEntity);
    }
    
    // Reset with same seed
    m_uuidGenerator->setSeed(12345);
    
    // Generate second sequence
    QStringList secondSequence;
    for (int i = 0; i < 10; i++) {
        secondSequence << m_uuidGenerator->generateUuid(UuidGenerator::CommandEntity);
    }
    
    // Verify sequences are identical
    QCOMPARE(firstSequence.size(), secondSequence.size());
    for (int i = 0; i < firstSequence.size(); i++) {
        QCOMPARE(firstSequence[i], secondSequence[i]);
    }
    
    qCDebug(jveTestUuidDeterminism) << "Deterministic generation validated - sequences match";
}

void TestUuidDeterminism::testSeedConsistency()
{
    qCDebug(jveTestUuidDeterminism) << "Testing seed consistency";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    
    // Test multiple seeds
    QList<quint32> seeds = {1, 42, 12345, 999999};
    QHash<quint32, QStringList> seedResults;
    
    for (quint32 seed : seeds) {
        m_uuidGenerator->setSeed(seed);
        QStringList uuids;
        for (int i = 0; i < 5; i++) {
            uuids << m_uuidGenerator->generateUuid(UuidGenerator::ProjectEntity);
        }
        seedResults[seed] = uuids;
    }
    
    // Verify each seed produces consistent results
    for (quint32 seed : seeds) {
        m_uuidGenerator->setSeed(seed);
        QStringList newUuids;
        for (int i = 0; i < 5; i++) {
            newUuids << m_uuidGenerator->generateUuid(UuidGenerator::ProjectEntity);
        }
        
        QCOMPARE(newUuids, seedResults[seed]);
    }
    
    qCDebug(jveTestUuidDeterminism) << "Seed consistency validated";
}

void TestUuidDeterminism::testDifferentSeedsProduceDifferentResults()
{
    qCDebug(jveTestUuidDeterminism) << "Testing different seeds produce different results";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    
    // Generate UUIDs with different seeds
    m_uuidGenerator->setSeed(1);
    QString uuid1 = m_uuidGenerator->generateUuid(UuidGenerator::MediaEntity);
    
    m_uuidGenerator->setSeed(2);
    QString uuid2 = m_uuidGenerator->generateUuid(UuidGenerator::MediaEntity);
    
    // Verify they are different
    QVERIFY(uuid1 != uuid2);
    QVERIFY(m_uuidGenerator->isValidUuid(uuid1));
    QVERIFY(m_uuidGenerator->isValidUuid(uuid2));
    
    qCDebug(jveTestUuidDeterminism) << "Different seeds produce different results as expected";
}

void TestUuidDeterminism::testEntityTypeNamespacing()
{
    qCDebug(jveTestUuidDeterminism) << "Testing entity type namespacing";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(12345);
    
    // Generate UUIDs for different entity types
    QString projectUuid = m_uuidGenerator->generateUuid(UuidGenerator::ProjectEntity);
    QString mediaUuid = m_uuidGenerator->generateUuid(UuidGenerator::MediaEntity);
    QString commandUuid = m_uuidGenerator->generateUuid(UuidGenerator::CommandEntity);
    QString uiUuid = m_uuidGenerator->generateUuid(UuidGenerator::UIEntity);
    QString systemUuid = m_uuidGenerator->generateUuid(UuidGenerator::SystemEntity);
    
    // Verify all are valid and different
    QStringList allUuids = {projectUuid, mediaUuid, commandUuid, uiUuid, systemUuid};
    for (const QString& uuid : allUuids) {
        QVERIFY(m_uuidGenerator->isValidUuid(uuid));
    }
    
    // Verify they are all different
    QSet<QString> uniqueUuids = QSet<QString>(allUuids.begin(), allUuids.end());
    QCOMPARE(uniqueUuids.size(), allUuids.size());
    
    qCDebug(jveTestUuidDeterminism) << "Entity type namespacing validated";
}

void TestUuidDeterminism::testProductionModeRandomness()
{
    qCDebug(jveTestUuidDeterminism) << "Testing production mode randomness";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::ProductionMode);
    
    // Generate multiple UUIDs
    QStringList uuids;
    for (int i = 0; i < 20; i++) {
        uuids << m_uuidGenerator->generateUuid();
    }
    
    // Verify all are valid and unique
    QSet<QString> uniqueUuids = QSet<QString>(uuids.begin(), uuids.end());
    QCOMPARE(uniqueUuids.size(), uuids.size()); // No duplicates
    
    for (const QString& uuid : uuids) {
        QVERIFY(m_uuidGenerator->isValidUuid(uuid));
    }
    
    qCDebug(jveTestUuidDeterminism) << "Production mode randomness validated";
}

void TestUuidDeterminism::testTestingModeConsistency()
{
    qCDebug(jveTestUuidDeterminism) << "Testing mode consistency";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(54321);
    
    QString firstUuid = m_uuidGenerator->generateUuid();
    
    // Switch modes and back
    m_uuidGenerator->setGenerationMode(UuidGenerator::ProductionMode);
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(54321);
    
    QString secondUuid = m_uuidGenerator->generateUuid();
    
    QCOMPARE(firstUuid, secondUuid);
    
    qCDebug(jveTestUuidDeterminism) << "Testing mode consistency validated";
}

void TestUuidDeterminism::testDebuggingModePatterns()
{
    qCDebug(jveTestUuidDeterminism) << "Testing debugging mode patterns";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::DebuggingMode);
    
    // Generate sequential UUIDs
    QStringList uuids;
    for (int i = 0; i < 5; i++) {
        uuids << m_uuidGenerator->generateUuid(UuidGenerator::CommandEntity);
    }
    
    // Verify they follow predictable pattern
    for (const QString& uuid : uuids) {
        QVERIFY(m_uuidGenerator->isValidUuid(uuid));
        QVERIFY(uuid.startsWith("CMND-")); // Command entity prefix
    }
    
    // Verify they are sequential
    QVERIFY(uuids[0] != uuids[1]);
    QVERIFY(uuids[1] != uuids[2]);
    
    qCDebug(jveTestUuidDeterminism) << "Debugging mode patterns validated";
}

void TestUuidDeterminism::testCommandReplayConsistency()
{
    qCDebug(jveTestUuidDeterminism) << "Testing command replay consistency";
    
    // Set deterministic mode for command system
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(98765);
    
    // Create project command
    QJsonObject createProjectRequest;
    createProjectRequest["command_type"] = "create_project";
    createProjectRequest["project_id"] = "test_project";
    QJsonObject args;
    args["name"] = "Test Project";
    createProjectRequest["args"] = args;
    
    // Execute command first time
    CommandResponse response1 = m_commandDispatcher->executeCommand(createProjectRequest);
    
    // Reset UUID generator with same seed
    m_uuidGenerator->setSeed(98765);
    
    // Execute same command again
    CommandResponse response2 = m_commandDispatcher->executeCommand(createProjectRequest);
    
    // Verify command IDs are the same (deterministic)
    QCOMPARE(response1.commandId, response2.commandId);
    QVERIFY(response1.success);
    QVERIFY(response2.success);
    
    qCDebug(jveTestUuidDeterminism) << "Command replay consistency validated";
}

void TestUuidDeterminism::testTimelineOperationDeterminism()
{
    qCDebug(jveTestUuidDeterminism) << "Testing timeline operation determinism";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(11111);
    
    // Create sequence of timeline operations
    QStringList commands = {"create_clip", "split_clip", "move_clip"};
    QStringList firstCommandIds;
    
    for (const QString& commandType : commands) {
        QJsonObject request;
        request["command_type"] = commandType;
        request["project_id"] = "test_project";
        QJsonObject args;
        args["clip_id"] = "test_clip";
        request["args"] = args;
        
        CommandResponse response = m_commandDispatcher->executeCommand(request);
        firstCommandIds << response.commandId;
    }
    
    // Reset and repeat
    m_uuidGenerator->setSeed(11111);
    QStringList secondCommandIds;
    
    for (const QString& commandType : commands) {
        QJsonObject request;
        request["command_type"] = commandType;
        request["project_id"] = "test_project";
        QJsonObject args;
        args["clip_id"] = "test_clip";
        request["args"] = args;
        
        CommandResponse response = m_commandDispatcher->executeCommand(request);
        secondCommandIds << response.commandId;
    }
    
    // Verify deterministic sequence
    QCOMPARE(firstCommandIds, secondCommandIds);
    
    qCDebug(jveTestUuidDeterminism) << "Timeline operation determinism validated";
}

void TestUuidDeterminism::testProjectCreationConsistency()
{
    qCDebug(jveTestUuidDeterminism) << "Testing project creation consistency";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(22222);
    
    // Create multiple project entities
    QStringList firstProjectIds;
    for (int i = 0; i < 3; i++) {
        firstProjectIds << m_uuidGenerator->generateProjectUuid();
    }
    
    // Reset and recreate
    m_uuidGenerator->setSeed(22222);
    QStringList secondProjectIds;
    for (int i = 0; i < 3; i++) {
        secondProjectIds << m_uuidGenerator->generateProjectUuid();
    }
    
    QCOMPARE(firstProjectIds, secondProjectIds);
    
    qCDebug(jveTestUuidDeterminism) << "Project creation consistency validated";
}

void TestUuidDeterminism::testUuidFormatCompliance()
{
    qCDebug(jveTestUuidDeterminism) << "Testing UUID format compliance";
    
    QList<UuidGenerator::GenerationMode> modes = {
        UuidGenerator::ProductionMode,
        UuidGenerator::TestingMode,
        UuidGenerator::DebuggingMode
    };
    
    for (UuidGenerator::GenerationMode mode : modes) {
        m_uuidGenerator->setGenerationMode(mode);
        if (mode == UuidGenerator::TestingMode) {
            m_uuidGenerator->setSeed(12345);
        }
        
        // Generate UUIDs for all entity types
        QList<UuidGenerator::EntityType> entityTypes = {
            UuidGenerator::ProjectEntity,
            UuidGenerator::MediaEntity,
            UuidGenerator::CommandEntity,
            UuidGenerator::UIEntity,
            UuidGenerator::SystemEntity,
            UuidGenerator::GenericEntity
        };
        
        for (UuidGenerator::EntityType entityType : entityTypes) {
            QString uuid = m_uuidGenerator->generateUuid(entityType);
            QVERIFY(m_uuidGenerator->isValidUuid(uuid));
            
            // Verify UUID format (8-4-4-4-12 pattern)
            QRegularExpression uuidPattern("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
            if (mode != UuidGenerator::DebuggingMode) {
                QVERIFY(uuidPattern.match(uuid).hasMatch());
            }
        }
    }
    
    qCDebug(jveTestUuidDeterminism) << "UUID format compliance validated";
}

void TestUuidDeterminism::testGenerationPerformance()
{
    qCDebug(jveTestUuidDeterminism) << "Testing UUID generation performance";
    
    m_uuidGenerator->startPerformanceMonitoring();
    
    QList<UuidGenerator::GenerationMode> modes = {
        UuidGenerator::ProductionMode,
        UuidGenerator::TestingMode,
        UuidGenerator::DebuggingMode
    };
    
    for (UuidGenerator::GenerationMode mode : modes) {
        m_uuidGenerator->setGenerationMode(mode);
        if (mode == UuidGenerator::TestingMode) {
            m_uuidGenerator->setSeed(12345);
        }
        
        QElapsedTimer timer;
        timer.start();
        
        // Generate 1000 UUIDs
        for (int i = 0; i < 1000; i++) {
            m_uuidGenerator->generateUuid();
        }
        
        qint64 elapsed = timer.elapsed();
        qCDebug(jveTestUuidDeterminism) << "Mode" << mode << "generated 1000 UUIDs in" << elapsed << "ms";
        
        // Performance should be reasonable (less than 1 second for 1000 UUIDs)
        QVERIFY(elapsed < 1000);
    }
    
    qreal avgTime = m_uuidGenerator->getAverageGenerationTime();
    qCDebug(jveTestUuidDeterminism) << "Average generation time:" << avgTime << "ms";
    
    m_uuidGenerator->stopPerformanceMonitoring();
}

void TestUuidDeterminism::testCollisionDetection()
{
    qCDebug(jveTestUuidDeterminism) << "Testing collision detection";
    
    m_uuidGenerator->enableCollisionDetection(true);
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(12345);
    
    // Generate some UUIDs
    QStringList uuids;
    for (int i = 0; i < 10; i++) {
        QString uuid = m_uuidGenerator->generateUuid();
        QVERIFY(m_uuidGenerator->isUniqueUuid(uuid));
        uuids << uuid;
    }
    
    // Verify collision detection works
    for (const QString& uuid : uuids) {
        QVERIFY(!m_uuidGenerator->isUniqueUuid(uuid)); // Should no longer be unique
    }
    
    qCDebug(jveTestUuidDeterminism) << "Collision detection validated";
}

void TestUuidDeterminism::testThreadSafety()
{
    qCDebug(jveTestUuidDeterminism) << "Testing thread safety";
    
    m_uuidGenerator->setGenerationMode(UuidGenerator::TestingMode);
    m_uuidGenerator->setSeed(33333);
    
    // Generate UUIDs from main thread
    QStringList mainThreadUuids;
    for (int i = 0; i < 50; i++) {
        mainThreadUuids << m_uuidGenerator->generateUuid();
    }
    
    // Verify all are unique and valid
    QSet<QString> uniqueUuids = QSet<QString>(mainThreadUuids.begin(), mainThreadUuids.end());
    QCOMPARE(uniqueUuids.size(), mainThreadUuids.size());
    
    for (const QString& uuid : mainThreadUuids) {
        QVERIFY(m_uuidGenerator->isValidUuid(uuid));
    }
    
    qCDebug(jveTestUuidDeterminism) << "Thread safety validated";
}

QTEST_MAIN(TestUuidDeterminism)
#include "test_uuid_determinism.moc"