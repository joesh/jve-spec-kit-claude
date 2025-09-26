#pragma once

#include <QString>
#include <QSqlDatabase>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(jveMigrations)

/**
 * Database migration system for JVE Editor
 * Ensures constitutional single-file project requirement with schema evolution
 * Rule 2.27: Single responsibility - migration orchestration only
 */
class Migrations
{
public:
    /**
     * Initialize migration system
     * Algorithm: Verify schema files → Log readiness status
     */
    static void initialize();
    
    /**
     * Apply all pending migrations to database
     * Algorithm: Validate database → Check versions → Apply updates → Verify results
     */
    static bool applyMigrations(QSqlDatabase& database, const QString& projectPath);
    
    /**
     * Create new empty project database with latest schema
     * Algorithm: Prepare file → Create connection → Apply schema → Cleanup
     */
    static bool createNewProject(const QString& projectPath);
    
    // Version information for migration planning
    struct VersionInfo {
        int current = 0;
        int target = 0;
        bool upgradeNeeded = false;
        bool isDowngrade = false;
    };

private:
    // Helper functions for algorithmic breakdown (Rule 2.26)
    static bool verifySchemaFilesExist();
    static bool validateDatabaseConnection(const QSqlDatabase& database);
    static VersionInfo determineVersionUpgrade(const QSqlDatabase& database);
    static bool executeVersionUpgrade(QSqlDatabase& database, const VersionInfo& versions);
    static bool applyMigrationsInSequence(QSqlDatabase& database, int fromVersion, int toVersion);
    static bool validateFinalMigrationState(const QSqlDatabase& database);
    static bool prepareProjectFile(const QString& projectPath);
    static void cleanupMigrationConnection(QSqlDatabase& database);
};