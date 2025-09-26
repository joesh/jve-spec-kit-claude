#pragma once

#include <QString>
#include <QSqlDatabase>

/**
 * Schema validation utilities
 * Handles database integrity checks and constitutional compliance
 * Rule 2.27: Single responsibility - validation only
 */
class SchemaValidator
{
public:
    /**
     * Validate database schema completeness
     * Algorithm: Check tables → Check views → Verify constraints
     */
    static bool validateSchema(const QSqlDatabase& database);
    
    /**
     * Verify constitutional compliance requirements
     * Algorithm: Check single-file → Check determinism → Check constraints
     */
    static bool verifyConstitutionalCompliance(const QSqlDatabase& database);
    
    /**
     * Get current schema version from database
     * Algorithm: Check table exists → Query max version → Return result
     */
    static int getCurrentSchemaVersion(const QSqlDatabase& database);

private:
    // Helper functions for algorithmic breakdown (Rule 2.26)
    static bool checkRequiredTablesExist(const QSqlDatabase& database);
    static bool checkRequiredViewsAccessible(const QSqlDatabase& database);
    static bool verifyForeignKeyConstraints(const QSqlDatabase& database);
    static bool checkCommandSequenceIntegrity(const QSqlDatabase& database);
    static bool validateJournalModeCompliance(const QSqlDatabase& database);
};