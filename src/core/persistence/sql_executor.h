#pragma once

#include <QString>
#include <QSqlDatabase>

/**
 * SQL script execution utilities  
 * Handles file loading and statement execution
 * Rule 2.27: Single responsibility - SQL execution only
 */
class SqlExecutor
{
public:
    /**
     * Execute SQL script from file path
     * Algorithm: Load file → Parse statements → Execute batch → Verify results
     */
    static bool executeSqlScript(QSqlDatabase& database, const QString& scriptPath);
    
    /**
     * Apply specific migration version
     * Algorithm: Resolve path → Load script → Execute → Log result
     */
    static bool applyMigrationVersion(QSqlDatabase& database, int version);
    
    /**
     * Create database connection for migration
     * Algorithm: Generate name → Configure → Open → Verify
     */
    static QSqlDatabase createMigrationConnection(const QString& projectPath);

private:
    // Helper functions for algorithmic breakdown (Rule 2.26)
    static QString loadScriptFromFile(const QString& scriptPath);
    static QStringList parseStatementsFromScript(const QString& script);
    static bool executeStatementBatch(QSqlDatabase& database, const QStringList& statements);
    static QString resolveMigrationPath(int version);
    static QString generateConnectionName(const QString& projectPath);
};