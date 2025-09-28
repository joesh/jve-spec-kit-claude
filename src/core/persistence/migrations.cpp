#include "migrations.h"
#include "schema_constants.h"
#include "schema_validator.h"
#include "sql_executor.h"

#include <QSqlDatabase>
#include <QSqlError>
#include <QFileInfo>
#include <QDir>
#include <QFile>

Q_LOGGING_CATEGORY(jveMigrations, "jve.migrations")

void Migrations::initialize()
{
    qCInfo(jveMigrations, "Initializing JVE Editor migration system v%d", schema::CURRENT_SCHEMA_VERSION);
    
    // Algorithm: Verify schema files → Log readiness status
    if (!verifySchemaFilesExist()) {
        qCCritical(jveMigrations, "Schema file not found - database operations will fail");
        return;
    }
    
    qCInfo(jveMigrations, "Migration system ready - latest schema version: %d", schema::CURRENT_SCHEMA_VERSION);
}

bool Migrations::applyMigrations(QSqlDatabase& database, const QString& projectPath)
{
    qCInfo(jveMigrations, "Applying migrations to project: %s", qPrintable(projectPath));
    
    // Algorithm: Validate database → Check versions → Apply updates → Verify results
    if (!validateDatabaseConnection(database)) {
        return false;
    }
    
    VersionInfo versions = determineVersionUpgrade(database);
    if (!versions.upgradeNeeded) {
        return SchemaValidator::verifyConstitutionalCompliance(database);
    }
    
    if (versions.isDowngrade) {
        qCCritical(jveMigrations, "Database version %d is newer than supported version %d", versions.current, versions.target);
        return false;
    }
    
    return executeVersionUpgrade(database, versions);
}

bool Migrations::createNewProject(const QString& projectPath)
{
    qCInfo(jveMigrations, "Creating new project: %s", qPrintable(projectPath));
    
    // Algorithm: Prepare file → Create connection → Apply schema → Cleanup
    if (!prepareProjectFile(projectPath)) {
        return false;
    }
    
    QSqlDatabase db = SqlExecutor::createMigrationConnection(projectPath);
    if (!db.isValid()) {
        return false;
    }
    
    bool success = applyMigrations(db, projectPath);
    
    cleanupMigrationConnection(db);
    
    if (success) {
        qCInfo(jveMigrations, "New project created successfully");
    }
    
    return success;
}

bool Migrations::verifySchemaFilesExist()
{
    if (QFile::exists(schema::RESOURCE_SCHEMA_PATH)) {
        return true;
    }
    
    if (QFile::exists(schema::DEV_SCHEMA_PATH)) {
        return true;
    }
    
    return false;
}

bool Migrations::validateDatabaseConnection(const QSqlDatabase& database)
{
    if (!database.isOpen()) {
        qCCritical(jveMigrations, "Database not open for migrations");
        return false;
    }
    
    return true;
}

Migrations::VersionInfo Migrations::determineVersionUpgrade(const QSqlDatabase& database)
{
    VersionInfo info;
    info.current = SchemaValidator::getCurrentSchemaVersion(database);
    info.target = schema::CURRENT_SCHEMA_VERSION;
    
    qCInfo(jveMigrations, "Schema version: %d → %d", info.current, info.target);
    
    if (info.current == info.target) {
        info.upgradeNeeded = false;
        qCInfo(jveMigrations, "Database already at latest schema version");
    } else if (info.current > info.target) {
        info.isDowngrade = true;
    } else {
        info.upgradeNeeded = true;
    }
    
    return info;
}

bool Migrations::executeVersionUpgrade(QSqlDatabase& database, const VersionInfo& versions)
{
    database.transaction();
    
    bool success = applyMigrationsInSequence(database, versions.current, versions.target);
    
    if (!success) {
        database.rollback();
        return false;
    }
    
    if (!database.commit()) {
        qCCritical(jveMigrations, "Failed to commit migrations: %s", qPrintable(database.lastError().text()));
        return false;
    }
    
    return validateFinalMigrationState(database);
}

bool Migrations::applyMigrationsInSequence(QSqlDatabase& database, int fromVersion, int toVersion)
{
    for (int version = fromVersion + 1; version <= toVersion; version++) {
        qCInfo(jveMigrations, "Applying migration to version %d", version);
        
        if (!SqlExecutor::applyMigrationVersion(database, version)) {
            qCCritical(jveMigrations, "Migration to version %d failed", version);
            return false;
        }
    }
    
    return true;
}

bool Migrations::validateFinalMigrationState(const QSqlDatabase& database)
{
    bool valid = SchemaValidator::validateSchema(database) && 
                SchemaValidator::verifyConstitutionalCompliance(database);
    
    if (valid) {
        qCInfo(jveMigrations, "All migrations applied successfully");
    } else {
        qCCritical(jveMigrations, "Migration validation failed");
    }
    
    return valid;
}

bool Migrations::prepareProjectFile(const QString& projectPath)
{
    QFileInfo fileInfo(projectPath);
    QDir().mkpath(fileInfo.absolutePath());
    
    if (QFile::exists(projectPath)) {
        if (!QFile::remove(projectPath)) {
            qCCritical(jveMigrations, "Failed to remove existing project file");
            return false;
        }
    }
    
    return true;
}

void Migrations::cleanupMigrationConnection(QSqlDatabase& database)
{
    QString connectionName = database.connectionName();
    database.close();
    QSqlDatabase::removeDatabase(connectionName);
}







