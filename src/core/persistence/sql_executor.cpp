#include "sql_executor.h"
#include "schema_constants.h"
#include "../common/uuid_generator.h"

#include <QFile>
#include <QTextStream>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QUuid>

Q_LOGGING_CATEGORY(jveSqlExecutor, "jve.sql.executor")

bool SqlExecutor::executeSqlScript(QSqlDatabase& database, const QString& scriptPath)
{
    qCDebug(jveSqlExecutor, "Executing SQL script: %s", qPrintable(scriptPath));
    
    // Algorithm: Load file → Parse statements → Execute batch → Verify results
    QString script = loadScriptFromFile(scriptPath);
    if (script.isEmpty()) {
        return false;
    }
    
    QStringList statements = parseStatementsFromScript(script);
    if (statements.isEmpty()) {
        qCWarning(jveSqlExecutor, "No executable statements found in script");
        return false;
    }
    
    bool success = executeStatementBatch(database, statements);
    
    if (success) {
        qCDebug(jveSqlExecutor, "SQL script executed successfully: %s", qPrintable(scriptPath));
    }
    
    return success;
}

bool SqlExecutor::applyMigrationVersion(QSqlDatabase& database, int version)
{
    qCDebug(jveSqlExecutor, "Applying migration version: %d", version);
    
    // Algorithm: Resolve path → Load script → Execute → Log result
    QString scriptPath = resolveMigrationPath(version);
    
    if (scriptPath.isEmpty()) {
        qCCritical(jveSqlExecutor, "Migration file not found for version %d", version);
        return false;
    }
    
    bool success = executeSqlScript(database, scriptPath);
    
    if (success) {
        qCInfo(jveSqlExecutor, "Migration version %d applied successfully", version);
    } else {
        qCCritical(jveSqlExecutor, "Failed to apply migration version %d", version);
    }
    
    return success;
}

QSqlDatabase SqlExecutor::createMigrationConnection(const QString& projectPath)
{
    // Algorithm: Generate name → Configure → Open → Verify
    QString connectionName = generateConnectionName(projectPath);
    
    QSqlDatabase database = QSqlDatabase::addDatabase("QSQLITE", connectionName);
    database.setDatabaseName(projectPath);
    
    if (!database.open()) {
        qCCritical(jveSqlExecutor, "Failed to create database connection: %s", qPrintable(database.lastError().text()));
        QSqlDatabase::removeDatabase(connectionName);
        return QSqlDatabase(); // Return invalid database
    }
    
    // Enable foreign keys immediately after connection is opened
    QSqlQuery query(database);
    if (!query.exec("PRAGMA foreign_keys = ON;")) {
        qCCritical(jveSqlExecutor, "Failed to enable foreign keys: %s", qPrintable(query.lastError().text()));
        QSqlDatabase::removeDatabase(connectionName);
        return QSqlDatabase();
    }
    
    qCDebug(jveSqlExecutor, "Migration connection created: %s", qPrintable(connectionName));
    return database;
}

QString SqlExecutor::loadScriptFromFile(const QString& scriptPath)
{
    QFile file(scriptPath);
    
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCCritical(jveSqlExecutor, "Failed to open SQL script: %s", qPrintable(scriptPath));
        return QString();
    }
    
    QTextStream stream(&file);
    QString script = stream.readAll();
    
    if (script.isEmpty()) {
        qCWarning(jveSqlExecutor, "Empty SQL script: %s", qPrintable(scriptPath));
    }
    
    return script;
}

QStringList SqlExecutor::parseStatementsFromScript(const QString& script)
{
    qCDebug(jveSqlExecutor, "Parsing SQL script with %lld characters", static_cast<long long>(script.length()));
    
    // Parse SQL statements while preserving execution order and handling blocks
    QStringList cleanStatements;
    QString currentStatement;
    QStringList lines = script.split('\n');
    int triggerDepth = 0;  // Track only trigger/procedure blocks
    bool inTrigger = false;
    
    for (const QString& line : lines) {
        QString trimmedLine = line.trimmed();
        
        // Skip empty lines and full-line comments
        if (trimmedLine.isEmpty() || trimmedLine.startsWith("--")) {
            continue;
        }
        
        // Remove inline comments (-- comment)
        int commentPos = trimmedLine.indexOf("--");
        if (commentPos >= 0) {
            trimmedLine = trimmedLine.left(commentPos).trimmed();
            if (trimmedLine.isEmpty()) {
                continue;
            }
        }
        
        // Skip PRAGMA statements that can't be executed inside transactions
        // Foreign keys are now handled at connection level
        if (trimmedLine.toUpper().startsWith("PRAGMA JOURNAL_MODE") ||
            trimmedLine.toUpper().startsWith("PRAGMA SYNCHRONOUS") ||
            trimmedLine.toUpper().startsWith("PRAGMA FOREIGN_KEYS")) {
            qCDebug(jveSqlExecutor, "Skipping pragma in transaction: %s", qPrintable(trimmedLine));
            continue;
        }
        
        // Accumulate lines until we hit a semicolon
        if (currentStatement.isEmpty()) {
            currentStatement = trimmedLine;
        } else {
            currentStatement += " " + trimmedLine;
        }
        
        // Track trigger/procedure boundaries specifically - only check once per statement
        if (!inTrigger && currentStatement.toUpper().startsWith("CREATE TRIGGER")) {
            inTrigger = true;
            qCDebug(jveSqlExecutor, "Starting trigger definition");
        }
        
        // Track BEGIN/END depth only for triggers/procedures
        if (inTrigger && trimmedLine.toUpper() == "BEGIN") {
            triggerDepth++;
            qCDebug(jveSqlExecutor, "Trigger BEGIN found, triggerDepth now: %d", triggerDepth);
        }
        
        // Track END statements - but need to handle CASE END vs trigger END
        if (inTrigger && (trimmedLine.toUpper() == "END" || trimmedLine.toUpper() == "END;")) {
            // If the trigger contains SELECT CASE, we need TWO END statements
            if (currentStatement.toUpper().contains("SELECT CASE")) {
                // First END is for CASE, second END is for trigger
                static int caseEndCount = 0;
                caseEndCount++;
                if (caseEndCount == 2) {
                    triggerDepth--;
                    qCDebug(jveSqlExecutor, "Trigger END found (after CASE END), triggerDepth now: %d", triggerDepth);
                    caseEndCount = 0; // Reset for next trigger
                } else {
                    qCDebug(jveSqlExecutor, "CASE END found, waiting for trigger END");
                }
            } else {
                // Regular trigger without CASE
                triggerDepth--;
                qCDebug(jveSqlExecutor, "Trigger END found, triggerDepth now: %d", triggerDepth);
            }
        }
        
        // Check if statement is complete 
        // Statement ends with semicolon AND we're not inside a trigger block
        if (trimmedLine.endsWith(';') && (!inTrigger || triggerDepth == 0)) {
            QString completeStatement = currentStatement.trimmed();
            if (!completeStatement.isEmpty()) {
                if (completeStatement.toUpper().contains("PREVENT_CLIP_OVERLAP")) {
                    qCDebug(jveSqlExecutor, "FULL TRIGGER STATEMENT: %s", qPrintable(completeStatement));
                }
                qCDebug(jveSqlExecutor, "Adding statement: %s", qPrintable(completeStatement.left(50) + "..."));
                cleanStatements.append(completeStatement);
            }
            currentStatement.clear();
            // Reset trigger state after each statement completion
            inTrigger = false;
            triggerDepth = 0;
        }
    }
    
    // Handle any remaining statement without semicolon
    if (!currentStatement.trimmed().isEmpty()) {
        qCDebug(jveSqlExecutor, "Adding final statement: %s", qPrintable(currentStatement.trimmed().left(50) + "..."));
        cleanStatements.append(currentStatement.trimmed());
    }
    
    qCDebug(jveSqlExecutor, "Parsed %lld SQL statements", static_cast<long long>(cleanStatements.size()));
    return cleanStatements;
}

bool SqlExecutor::executeStatementBatch(QSqlDatabase& database, const QStringList& statements)
{
    QSqlQuery query(database);
    
    qCDebug(jveSqlExecutor, "Executing %lld statements", static_cast<long long>(statements.size()));
    
    for (int i = 0; i < statements.size(); ++i) {
        const QString& statement = statements[i];
        qCDebug(jveSqlExecutor, "Statement %d: %s", (i+1), qPrintable(statement.left(50) + "..."));
        
        if (!query.exec(statement)) {
            qCCritical(jveSqlExecutor, "SQL execution failed: %s Full Statement: %s", 
                                       qPrintable(query.lastError().text()), qPrintable(statement));
            return false;
        }
    }
    
    return true;
}

QString SqlExecutor::resolveMigrationPath(int version)
{
    if (version == schema::INITIAL_SCHEMA_VERSION) {
        // Check resource path first, then development path
        if (QFile::exists(schema::RESOURCE_SCHEMA_PATH)) {
            return schema::RESOURCE_SCHEMA_PATH;
        }
        if (QFile::exists(schema::DEV_SCHEMA_PATH)) {
            return schema::DEV_SCHEMA_PATH;
        }
        return QString();
    }
    
    // Check for version-specific migration files
    QString resourcePath = QString(schema::MIGRATION_RESOURCE_PATTERN).arg(version);
    if (QFile::exists(resourcePath)) {
        return resourcePath;
    }
    
    QString devPath = QString(schema::MIGRATION_DEV_PATTERN).arg(version);
    if (QFile::exists(devPath)) {
        return devPath;
    }
    
    return QString();
}

QString SqlExecutor::generateConnectionName(const QString& projectPath)
{
    Q_UNUSED(projectPath)
    // Generate unique connection name to avoid conflicts
    QString baseName = QString(schema::MIGRATION_CONNECTION_PREFIX) + 
                      UuidGenerator::instance()->generateSystemUuid();
    return baseName;
}