#include "sql_executor.h"
#include "schema_constants.h"

#include <QFile>
#include <QTextStream>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QUuid>

Q_LOGGING_CATEGORY(jveSqlExecutor, "jve.sql.executor")

bool SqlExecutor::executeSqlScript(QSqlDatabase& database, const QString& scriptPath)
{
    qCDebug(jveSqlExecutor) << "Executing SQL script:" << scriptPath;
    
    // Algorithm: Load file → Parse statements → Execute batch → Verify results
    QString script = loadScriptFromFile(scriptPath);
    if (script.isEmpty()) {
        return false;
    }
    
    QStringList statements = parseStatementsFromScript(script);
    if (statements.isEmpty()) {
        qCWarning(jveSqlExecutor) << "No executable statements found in script";
        return false;
    }
    
    bool success = executeStatementBatch(database, statements);
    
    if (success) {
        qCDebug(jveSqlExecutor) << "SQL script executed successfully:" << scriptPath;
    }
    
    return success;
}

bool SqlExecutor::applyMigrationVersion(QSqlDatabase& database, int version)
{
    qCDebug(jveSqlExecutor) << "Applying migration version:" << version;
    
    // Algorithm: Resolve path → Load script → Execute → Log result
    QString scriptPath = resolveMigrationPath(version);
    
    if (scriptPath.isEmpty()) {
        qCCritical(jveSqlExecutor) << "Migration file not found for version" << version;
        return false;
    }
    
    bool success = executeSqlScript(database, scriptPath);
    
    if (success) {
        qCInfo(jveSqlExecutor) << "Migration version" << version << "applied successfully";
    } else {
        qCCritical(jveSqlExecutor) << "Failed to apply migration version" << version;
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
        qCCritical(jveSqlExecutor) << "Failed to create database connection:" 
                                   << database.lastError().text();
        QSqlDatabase::removeDatabase(connectionName);
        return QSqlDatabase(); // Return invalid database
    }
    
    qCDebug(jveSqlExecutor) << "Migration connection created:" << connectionName;
    return database;
}

QString SqlExecutor::loadScriptFromFile(const QString& scriptPath)
{
    QFile file(scriptPath);
    
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qCCritical(jveSqlExecutor) << "Failed to open SQL script:" << scriptPath;
        return QString();
    }
    
    QTextStream stream(&file);
    QString script = stream.readAll();
    
    if (script.isEmpty()) {
        qCWarning(jveSqlExecutor) << "Empty SQL script:" << scriptPath;
    }
    
    return script;
}

QStringList SqlExecutor::parseStatementsFromScript(const QString& script)
{
    qCDebug(jveSqlExecutor) << "Parsing SQL script with" << script.length() << "characters";
    
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
        if (trimmedLine.toUpper().startsWith("PRAGMA JOURNAL_MODE") ||
            trimmedLine.toUpper().startsWith("PRAGMA SYNCHRONOUS") ||
            trimmedLine.toUpper().startsWith("PRAGMA FOREIGN_KEYS")) {
            qCDebug(jveSqlExecutor) << "Skipping pragma in transaction:" << trimmedLine;
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
            qCDebug(jveSqlExecutor) << "Starting trigger definition";
        }
        
        // Track BEGIN/END depth only for triggers/procedures
        if (inTrigger && trimmedLine.toUpper() == "BEGIN") {
            triggerDepth++;
            qCDebug(jveSqlExecutor) << "Trigger BEGIN found, triggerDepth now:" << triggerDepth;
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
                    qCDebug(jveSqlExecutor) << "Trigger END found (after CASE END), triggerDepth now:" << triggerDepth;
                    caseEndCount = 0; // Reset for next trigger
                } else {
                    qCDebug(jveSqlExecutor) << "CASE END found, waiting for trigger END";
                }
            } else {
                // Regular trigger without CASE
                triggerDepth--;
                qCDebug(jveSqlExecutor) << "Trigger END found, triggerDepth now:" << triggerDepth;
            }
        }
        
        // Check if statement is complete 
        // Statement ends with semicolon AND we're not inside a trigger block
        if (trimmedLine.endsWith(';') && (!inTrigger || triggerDepth == 0)) {
            QString completeStatement = currentStatement.trimmed();
            if (!completeStatement.isEmpty()) {
                if (completeStatement.toUpper().contains("PREVENT_CLIP_OVERLAP")) {
                    qCDebug(jveSqlExecutor) << "FULL TRIGGER STATEMENT:" << completeStatement;
                }
                qCDebug(jveSqlExecutor) << "Adding statement:" << completeStatement.left(50) + "...";
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
        qCDebug(jveSqlExecutor) << "Adding final statement:" << currentStatement.trimmed().left(50) + "...";
        cleanStatements.append(currentStatement.trimmed());
    }
    
    qCDebug(jveSqlExecutor) << "Parsed" << cleanStatements.size() << "SQL statements";
    return cleanStatements;
}

bool SqlExecutor::executeStatementBatch(QSqlDatabase& database, const QStringList& statements)
{
    QSqlQuery query(database);
    
    qCDebug(jveSqlExecutor) << "Executing" << statements.size() << "statements";
    
    for (int i = 0; i < statements.size(); ++i) {
        const QString& statement = statements[i];
        qCDebug(jveSqlExecutor) << "Statement" << (i+1) << ":" << statement.left(50) + "...";
        
        if (!query.exec(statement)) {
            qCCritical(jveSqlExecutor) << "SQL execution failed:" 
                                       << query.lastError().text()
                                       << "Full Statement:" << statement;
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
    // Generate unique connection name to avoid conflicts
    QString baseName = QString(schema::MIGRATION_CONNECTION_PREFIX) + 
                      QUuid::createUuid().toString(QUuid::WithoutBraces);
    return baseName;
}