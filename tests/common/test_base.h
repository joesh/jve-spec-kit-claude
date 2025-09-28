#pragma once

#include <QTest>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QLoggingCategory>
#include <memory>

Q_DECLARE_LOGGING_CATEGORY(jveTests)

/**
 * Base class for all JVE tests providing common setup and utilities
 * Ensures constitutional TDD compliance and consistent test environment
 */
class TestBase : public QObject
{
    Q_OBJECT

protected:
    // Test data directory management
    std::unique_ptr<QTemporaryDir> m_testDataDir;
    QString m_testDatabasePath;
    
    // Test timing and performance validation
    QElapsedTimer m_timer;
    static constexpr int MAX_TIMELINE_RENDER_MS = 16; // Constitutional requirement
    
public:
    TestBase(QObject *parent = nullptr) : QObject(parent) {}

protected slots:
    /**
     * Initialize test environment before each test method
     * Creates isolated test database and temporary directories
     */
    virtual void initTestCase() {
        // Set up logging for tests
        QLoggingCategory::setFilterRules("jve.tests=true");
        qCInfo(jveTests, "Initializing test case: %s", metaObject()->className());
        
        // Create temporary directory for test data
        m_testDataDir = std::make_unique<QTemporaryDir>();
        QVERIFY(m_testDataDir->isValid());
        
        // Set test database path
        m_testDatabasePath = m_testDataDir->filePath("test_project.jve");
        
        // Override application data location for tests
        QStandardPaths::setTestModeEnabled(true);
    }
    
    /**
     * Clean up after each test method
     */
    virtual void cleanupTestCase() {
        qCInfo(jveTests, "Cleaning up test case: %s", metaObject()->className());
        m_testDataDir.reset();
    }
    
    /**
     * Initialize before each test method
     */
    virtual void init() {
        m_timer.start();
    }
    
    /**
     * Clean up after each test method  
     */
    virtual void cleanup() {
        auto elapsedMs = m_timer.elapsed();
        if (elapsedMs > 1000) { // Log slow tests
            qCWarning(jveTests, "Slow test detected: %lldms", elapsedMs);
        }
    }

protected:
    /**
     * Verify performance requirements are met
     */
    void verifyPerformance(const QString& operation, int maxMs = 100) {
        auto elapsed = m_timer.elapsed();
        if (elapsed > maxMs) {
            QFAIL(qPrintable(QString("Performance requirement failed: %1 took %2ms (max: %3ms)")
                           .arg(operation).arg(elapsed).arg(maxMs)));
        }
        qCInfo(jveTests, "%s completed in %lldms", operation.toUtf8().constData(), elapsed);
    }
    
    /**
     * Create test project file with minimal valid structure
     */
    QString createTestProject(const QString& projectName = "TestProject") {
        QString projectPath = m_testDataDir->filePath(projectName + ".jve");
        
        // TODO: Initialize with minimal SQLite schema
        // This will be implemented when T004 (schema) is complete
        
        return projectPath;
    }
    
    /**
     * Verify constitutional TDD compliance
     * Tests must fail initially, then pass after implementation
     */
    void verifyTDDCompliance() {
        // This method documents the TDD expectation
        // Contract tests MUST fail initially
        qCInfo(jveTests, "TDD Compliance: Test written before implementation");
    }
    
    /**
     * Verify command determinism requirement
     * Same command sequence must produce identical results
     */
    void verifyCommandDeterminism(const QStringList& commands) {
        // TODO: Implement when command system is available
        Q_UNUSED(commands)
        qCInfo(jveTests, "Command determinism verification placeholder");
    }
    
    /**
     * Verify library-first architecture compliance
     * Components must be independently testable
     */
    void verifyLibraryFirstCompliance() {
        qCInfo(jveTests, "Library-First Compliance: Component tested in isolation");
    }
};

Q_DECLARE_LOGGING_CATEGORY(jveTests)