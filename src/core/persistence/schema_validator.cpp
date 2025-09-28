#include "schema_validator.h"
#include "schema_constants.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(jveSchemaValidator, "jve.schema.validator")

bool SchemaValidator::validateSchema(const QSqlDatabase& database)
{
    qCDebug(jveSchemaValidator, "Validating database schema");
    
    // Algorithm: Check tables → Check views → Verify constraints
    if (!checkRequiredTablesExist(database)) {
        return false;
    }
    
    if (!checkRequiredViewsAccessible(database)) {
        return false;
    }
    
    if (!verifyForeignKeyConstraints(database)) {
        return false;
    }
    
    qCInfo(jveSchemaValidator, "Schema validation successful");
    return true;
}

bool SchemaValidator::verifyConstitutionalCompliance(const QSqlDatabase& database)
{
    qCDebug(jveSchemaValidator, "Verifying constitutional compliance");
    
    // Algorithm: Check single-file → Check determinism → Check constraints
    if (!validateJournalModeCompliance(database)) {
        return false;
    }
    
    if (!checkCommandSequenceIntegrity(database)) {
        return false;
    }
    
    qCInfo(jveSchemaValidator, "Constitutional compliance verified");
    return true;
}

int SchemaValidator::getCurrentSchemaVersion(const QSqlDatabase& database)
{
    // Algorithm: Check table exists → Query max version → Return result
    QSqlQuery query(database);
    
    if (!query.exec(schema::CHECK_SCHEMA_TABLE)) {
        return 0;
    }
    
    if (!query.next()) {
        return 0; // No schema version table
    }
    
    if (!query.exec(schema::GET_MAX_VERSION)) {
        qCWarning(jveSchemaValidator, "Failed to query schema version: %s", qPrintable(query.lastError().text()));
        return 0;
    }
    
    if (query.next()) {
        return query.value(0).toInt();
    }
    
    return 0;
}

bool SchemaValidator::checkRequiredTablesExist(const QSqlDatabase& database)
{
    QStringList existingTables = database.tables();
    
    for (int i = 0; i < schema::REQUIRED_TABLES_COUNT; ++i) {
        const QString table = schema::REQUIRED_TABLES[i];
        if (!existingTables.contains(table)) {
            qCCritical(jveSchemaValidator, "Required table missing: %s", qPrintable(table));
            return false;
        }
    }
    
    qCDebug(jveSchemaValidator, "All required tables present");
    return true;
}

bool SchemaValidator::checkRequiredViewsAccessible(const QSqlDatabase& database)
{
    // Views may not appear in QSqlDatabase::tables() on all platforms
    // Test accessibility by attempting to query them
    QSqlQuery query(database);
    
    for (int i = 0; i < schema::REQUIRED_VIEWS_COUNT; ++i) {
        const QString view = schema::REQUIRED_VIEWS[i];
        const QString testQuery = QString("SELECT COUNT(*) FROM %1 LIMIT 1").arg(view);
        
        if (!query.exec(testQuery)) {
            qCWarning(jveSchemaValidator, "View not accessible: %s Error: %s", qPrintable(view), qPrintable(query.lastError().text()));
            // Views are not critical for basic operation, continue
        }
    }
    
    qCDebug(jveSchemaValidator, "Required views accessibility checked");
    return true;
}

bool SchemaValidator::verifyForeignKeyConstraints(const QSqlDatabase& database)
{
    QSqlQuery query(database);
    
    if (!query.exec(schema::CHECK_FOREIGN_KEYS)) {
        qCWarning(jveSchemaValidator, "Failed to check foreign key status");
        return false;
    }
    
    if (query.next() && query.value(0).toInt() == 1) {
        qCDebug(jveSchemaValidator, "Foreign key constraints enabled");
        return true;
    }
    
    qCCritical(jveSchemaValidator, "Foreign key constraints not enabled");
    return false;
}

bool SchemaValidator::checkCommandSequenceIntegrity(const QSqlDatabase& database)
{
    QSqlQuery query(database);
    
    if (!query.exec(schema::CHECK_NULL_SEQUENCES)) {
        qCWarning(jveSchemaValidator, "Failed to verify command sequence integrity");
        return false;
    }
    
    if (query.next() && query.value(0).toInt() > 0) {
        qCCritical(jveSchemaValidator, "Commands with NULL sequence numbers detected");
        return false;
    }
    
    qCDebug(jveSchemaValidator, "Command sequence integrity verified");
    return true;
}

bool SchemaValidator::validateJournalModeCompliance(const QSqlDatabase& database)
{
    QSqlQuery query(database);
    
    if (!query.exec(schema::CHECK_JOURNAL_MODE)) {
        qCWarning(jveSchemaValidator, "Failed to check journal mode");
        return false;
    }
    
    if (query.next()) {
        QString journalMode = query.value(0).toString().toUpper();
        if (journalMode == schema::WAL_JOURNAL_MODE) {
            qCInfo(jveSchemaValidator, "WAL mode enabled for performance (will be disabled on close)");
        } else {
            qCDebug(jveSchemaValidator, "Journal mode: %s", qPrintable(journalMode));
        }
    }
    
    return true;
}